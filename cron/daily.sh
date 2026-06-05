#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:30 触发)
#
# 启动姿势完全对齐 launch_worker.sh:
#   IS_SANDBOX=1 + --dangerously-skip-permissions + --output-format stream-json
#   + --append-system-prompt(R1-R9 浓缩版)
#   + PostToolUse hook 做 R1/R4 硬约束检测
#   + worker.pid + trap cleanup 防僵尸进程
#
# 不复用 launch_worker.sh 是因为 daily.sh 自己组装 prompt(auto-daily skill 触发),
# 而 launch_worker.sh 是通用入口。两者维护时保持同步。
set -e

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
CLAUDE_HAHA_BIN="${CLAUDE_HAHA_BIN:-$HARNESS_ROOT/bin/claude-haha}"
CLAUDE_CONFIG_DIR="${CLAUDE_HAHA_CONFIG_DIR:-$HARNESS_ROOT/.claude-haha}"

cd "$HARNESS_ROOT"
[ -f .env ] && set -a && source .env && set +a

LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# ============ run-id 注册 + hook_state 初始化 ============
RUN_ID=$(basename "$LOG_DIR")
echo "$RUN_ID" > "$HARNESS_ROOT/runs/.current_run_id"
# daily.sh 不知道 slug(由 auto-daily skill pick),hook_state.own_slug 留空;
# 跨 workspace 检测在 SubAgent dispatch 后由 SubAgent 自己更新 hook_state
python3 - "$LOG_DIR/.hook_state.json" <<'PYEOF'
import json, sys, time
state_path = sys.argv[1]
with open(state_path, "w") as f:
    json.dump({
        "own_slug": "",
        "own_pids": [],
        "bash_count": 0,
        "poll_count": 0,
        "task_called": 0,
        "sleep_streak": 0,
        "last_cmd": "",
        "trigger": "cron",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }, f)
PYEOF

cat > "$LOG_DIR/meta.json" <<JSON
{"started_at":"$(date -Iseconds)","run_id":"$RUN_ID","trigger":"cron"}
JSON

# ============ 缓存隔离 ============
ISOLATED_CACHE="$LOG_DIR/.cache"
mkdir -p "$ISOLATED_CACHE"/{huggingface,torch,pip,xdg}
export HF_HOME="$ISOLATED_CACHE/huggingface"
export HF_HUB_CACHE="$ISOLATED_CACHE/huggingface"
export TRANSFORMERS_CACHE="$ISOLATED_CACHE/huggingface"
export TORCH_HOME="$ISOLATED_CACHE/torch"
export PIP_CACHE_DIR="$ISOLATED_CACHE/pip"
export XDG_CACHE_HOME="$ISOLATED_CACHE/xdg"
if [ -n "${HF_TOKEN:-}" ]; then
    export HF_TOKEN
fi

# ============ 启动前清理僵尸 worker ============
python3 - <<'PYEOF' 2>>"$LOG_DIR/cleanup.log" || true
import os, pathlib, signal, time
runs = pathlib.Path("/root/ai-auto-harness/runs")
cleaned = []
for wpid_file in runs.glob("*/worker.pid"):
    try:
        pid = int(wpid_file.read_text().strip())
    except Exception:
        continue
    if pid == os.getpid():
        continue
    try:
        os.kill(pid, 0)
        continue
    except OSError:
        pass
    cache_dir = wpid_file.parent / ".cache"
    if cache_dir.exists():
        for pf in cache_dir.glob("*.pid"):
            try:
                cpid = int(pf.read_text().strip())
                os.kill(cpid, 0)
                os.kill(cpid, signal.SIGTERM)
                cleaned.append(f"{wpid_file.parent.name}: SIGTERM {cpid}")
            except Exception:
                pass
if cleaned:
    with open("/root/ai-auto-harness/runs/.last_cleanup.log", "a") as f:
        f.write(f"=== {time.strftime('%Y-%m-%dT%H:%M:%S')} daily.sh ===\n")
        for c in cleaned: f.write(c + "\n")
PYEOF

# ============ trap cleanup ============
WORKER_PID_FILE="$LOG_DIR/worker.pid"
echo "$$" > "$WORKER_PID_FILE"

cleanup() {
    local code=$?
    if [ -n "${HAHA_PID:-}" ]; then
        kill -TERM "$HAHA_PID" 2>/dev/null || true
    fi
    echo "exit=$code" > "$LOG_DIR/cron.status"
    exit $code
}
trap cleanup EXIT INT TERM

# ============ Prompt ============
PROMPT="请使用 auto-daily skill 执行今日 AI 项目部署工作流(读 ai-daily-scan findings → 挑 1 个 → 5 阶段 SubAgent → 写报告)."

APPEND_PROMPT=$(cat <<'PROMPT_EOF'

# 🔴 Harness 硬规则(违反会被 PostToolUse hook 实时 warn)

**R1**:只能动自己 workspace;严禁 kill 不在 $WORKSPACE/.cache/*.pid 里的 PID
**R4**:单次 sleep ≤ 60s;连续 sleep 绝对禁;poll ≤ 8 turn,超过 paused_in_progress return
**R5**:fetch 完全 done 才进 install,不并行抢带宽
**R6**:pip 严禁 --no-cache-dir(PIP_CACHE_DIR 已 env 隔离)
**R9**:主 agent 只 Task() dispatch,**严禁**自己 git clone / hf download / pip install / python -m

完整规则在 .claude/CLAUDE.md R1-R9。
PROMPT_EOF
)

# ============ 启动 worker ============
CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
IS_SANDBOX=1 \
HF_HOME="$HF_HOME" \
HF_HUB_CACHE="$HF_HUB_CACHE" \
TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
TORCH_HOME="$TORCH_HOME" \
PIP_CACHE_DIR="$PIP_CACHE_DIR" \
XDG_CACHE_HOME="$XDG_CACHE_HOME" \
HF_TOKEN="${HF_TOKEN:-}" \
"$CLAUDE_HAHA_BIN" \
    -p "$PROMPT" \
    --append-system-prompt "$APPEND_PROMPT" \
    --output-format stream-json \
    --verbose \
    --dangerously-skip-permissions \
    --setting-sources user,project,local \
    --mcp-config "$HARNESS_ROOT/.mcp.json" \
    --settings "$HARNESS_ROOT/.claude/settings.json" \
    > "$LOG_DIR/harness.stdout.ndjson" \
    2> "$LOG_DIR/harness.stderr.log" &
HAHA_PID=$!
echo "$HAHA_PID" > "$LOG_DIR/haha.pid"

wait "$HAHA_PID"
RET=$?
HAHA_PID=""

# trajectory.json
python3 -c "
import json, pathlib
ndjson_path = pathlib.Path('$LOG_DIR/harness.stdout.ndjson')
out_path = pathlib.Path('$LOG_DIR/trajectory.json')
events = []
for line in ndjson_path.read_text().splitlines() if ndjson_path.exists() else []:
    if not line.strip(): continue
    try: d = json.loads(line)
    except: continue
    if d.get('type') in ('assistant', 'user', 'result'):
        events.append({'type': d.get('type'), 'subtype': d.get('subtype'),
                       'uuid': d.get('uuid'), 'duration_ms': d.get('duration_ms')})
out_path.write_text(json.dumps(events, ensure_ascii=False, indent=2))
print(f'trajectory.json: {len(events)} events')
" 2>>"$LOG_DIR/harness.stderr.log" || true

exit $RET
