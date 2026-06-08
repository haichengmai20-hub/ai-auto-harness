#!/bin/bash
# SessionStart hook — 生成 run-id 落盘 + 加载今日上下文摘要到 system prompt addendum
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# run 目录落盘(post-tool-use 会读)。
# 🔴 关键(Fix: 2026-06-02-hook-runid-clobber + 2026-06-08-run-dir-into-workspace):
#   - worker 启动(AI_HARNESS_RUN_DIR 已注入)→ 复用其完整路径,且**绝不写** .current_run_id。
#     env 是权威通道,worker 的 post-tool-use 也读 env;不写文件,交互式 monitor 会话就无从覆盖。
#   - 旧 launcher(只有 AI_HARNESS_RUN_ID)→ 复用全局 runs/$id,向后兼容。
#   - 交互式 session(都没有)→ 自造一个,写全局 .current_run_id 供自己的 post-tool-use fallback;
#     此时若有 worker 在跑,worker 走 env 不读该文件,**不会被打断**。
if [ -n "${AI_HARNESS_RUN_DIR:-}" ]; then
    RUN_DIR="$AI_HARNESS_RUN_DIR"
    RUN_ID="$(basename "$RUN_DIR")"
    mkdir -p "$RUN_DIR"
    # worker-managed:不触碰 .current_run_id
elif [ -n "${AI_HARNESS_RUN_ID:-}" ]; then
    RUN_ID="$AI_HARNESS_RUN_ID"
    RUN_DIR="runs/$RUN_ID"
    mkdir -p "$RUN_DIR"
    echo "$RUN_ID" > "runs/.current_run_id"
else
    RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"                 # 交互式 session,自造一个
    RUN_DIR="runs/$RUN_ID"
    mkdir -p "$RUN_DIR"
    echo "$RUN_ID" > "runs/.current_run_id"
fi

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

echo "### Handoff sentinels / paused resume hints"
python3 - <<'PYEOF' 2>/dev/null || echo "  (handoff scan failed)"
import json, pathlib, time

root = pathlib.Path("/root/ai-auto-harness")
rows = []
for state_path in sorted(root.glob("workspace/*/state.json")):
    try:
        state = json.loads(state_path.read_text())
    except Exception:
        continue
    slug = state.get("slug") or state_path.parent.name
    phase = state.get("phase")
    status = state.get("status")
    paused = bool(state.get("paused_in_progress")) or status == "paused_in_progress"
    if paused or phase not in (None, "done", "archived", "paused_for_human"):
        rows.append({
            "kind": "state",
            "slug": slug,
            "phase": phase,
            "status": status,
            "updated_at": state.get("updated_at"),
            "hint": "dispatch the matching SubAgent via Task() to resume; do not inline Bash",
        })

for sentinel in sorted(root.glob("workspace/*/.cache/handoff/*.json")):
    try:
        data = json.loads(sentinel.read_text())
    except Exception:
        rows.append({"kind": "sentinel", "path": str(sentinel.relative_to(root)), "status": "invalid_json"})
        continue
    status = data.get("status")
    if status in ("done", "failed", "running", "paused_in_progress"):
        rows.append({
            "kind": "sentinel",
            "slug": data.get("slug") or sentinel.parents[2].name,
            "phase": data.get("phase"),
            "status": status,
            "pid": data.get("pid"),
            "completed_at": data.get("completed_at"),
            "path": str(sentinel.relative_to(root)),
        })

if not rows:
    print("  (无)")
else:
    for row in rows[:12]:
        print("  - " + json.dumps(row, ensure_ascii=False, sort_keys=True))
    if len(rows) > 12:
        print(f"  ... {len(rows) - 12} more")
PYEOF
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
echo ""

echo "### Experience library (memory/lessons/)"
if [ -d "memory/lessons" ]; then
    for f in memory/lessons/*.md; do
        if [ -f "$f" ]; then
            TITLE=$(head -1 "$f" | sed 's/^# //')
            echo "  - $TITLE → $f"
        fi
    done
else
    echo "  (无)"
fi
