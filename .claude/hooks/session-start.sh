#!/bin/bash
# SessionStart hook — 生成 run-id 落盘 + 加载今日上下文摘要到 system prompt addendum
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 生成 run-id 落盘(post-tool-use 会读)
RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"
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
