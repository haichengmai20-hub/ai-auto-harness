#!/bin/bash
# SessionStart hook — 生成 run-id 落盘 + 加载今日上下文摘要到 system prompt addendum
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# run-id 落盘(post-tool-use 会读)。
# 🔴 关键:若 launch_worker.sh 已建立 run-id(经 $AI_HARNESS_RUN_ID 注入,或
# .current_run_id 指向一个含 meta.json 的 launch_worker run),则**复用**它,
# **绝不**用新生成的 id 覆盖 — 否则 PostToolUse hook 会把 transcript/计数写进
# session 自造的孤儿 run 目录,launch_worker 建的 run 目录永远 0 计数、无 transcript。
# (Fix: 2026-06-02-hook-runid-clobber-fix)
EXISTING_RUN_ID="$(cat runs/.current_run_id 2>/dev/null || echo "")"
if [ -n "${AI_HARNESS_RUN_ID:-}" ]; then
    RUN_ID="$AI_HARNESS_RUN_ID"                       # launch_worker 经 env 注入,最高优先级
elif [ -n "$EXISTING_RUN_ID" ] && [ -f "runs/$EXISTING_RUN_ID/meta.json" ]; then
    RUN_ID="$EXISTING_RUN_ID"                          # launch_worker 已建(有 meta.json),复用
else
    RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"                 # 交互式 session,自造一个
fi
mkdir -p "runs/$RUN_ID"
echo "$RUN_ID" > "runs/.current_run_id"

echo "## Today's context (loaded by SessionStart hook)"
echo "Run ID: $RUN_ID"
echo ""

echo "### Findings (latest scan, top 5)"
if [ -f "/root/ai-daily-scan/state/findings.jsonl" ]; then
    head -5 /root/ai-daily-scan/state/findings.jsonl | \
      jq -c '{slug, estimated_params_b, next_action, scenario_hits, gated_repos}' 2>/dev/null \
      || head -c 600 /root/ai-daily-scan/state/findings.jsonl
else
    echo "(scan 还没产 findings.jsonl 或文件不存在)"
fi
echo ""

echo "### In-progress projects (workspace state)"
if [ -d "workspace" ]; then
    found=$(find workspace -maxdepth 2 -name state.json 2>/dev/null | head -5)
    if [ -n "$found" ]; then
        for s in $found; do
            jq -c '{slug, phase, phases_done, updated_at}' "$s" 2>/dev/null || echo "  - $s (cannot parse)"
        done
    else
        echo "  (无)"
    fi
else
    echo "  (无 workspace/ 目录)"
fi
echo ""

echo "### Pending human"
if [ -d "pending_human" ]; then
    files=$(ls pending_human/ 2>/dev/null | grep -v "^_" || true)
    if [ -n "$files" ]; then
        echo "$files"
    else
        echo "  (无积压)"
    fi
else
    echo "  (无)"
fi
echo ""

echo "### Resources"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null | head -10 || echo "  nvidia-smi 不可用"
df -h /root 2>/dev/null | tail -1 || true
