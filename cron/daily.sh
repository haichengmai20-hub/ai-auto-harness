#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:00 触发)
#
# 支持 HERMES_MODE 环境变量切换引擎:
#   HERMES_MODE=1 → 只跑 0-token 预检(preflight+reconcile+磁盘+bg-check),不启动 CC worker。
#                     Hermes cron job 会在 preflight 完成后自行调度 agent。
#   默认(不设)    → 跑完整 CC 版流程(preflight+reconcile+启动 claude-haha worker+续跑)。
#
# 两种模式共享 flock / 磁盘门槛 / bg-check / reconcile 三件套。
set -e

# ============ flock 防并发 ============
# 若上一次 cron 还没跑完(长任务如 fetch-weights 跨 cron),新 cron 不再启动。
# 锁文件在 /tmp,不污染 workspace/runs。
LOCK_FILE="/tmp/ai-auto-harness-daily.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date -Iseconds)] 上一次 daily.sh 还在跑,flock 锁未释放,本次跳过" >&2
    exit 0
fi

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
CLAUDE_HAHA_BIN="${CLAUDE_HAHA_BIN:-$HARNESS_ROOT/bin/claude-haha}"
CLAUDE_CONFIG_DIR="${CLAUDE_HAHA_CONFIG_DIR:-$HARNESS_ROOT/.claude-haha}"

cd "$HARNESS_ROOT"
[ -f .env ] && set -a && source .env && set +a

# ============ 磁盘门槛(2026-06-12 用户要求) ============
# free < 150GB 不起新 run:权重下载 + venv + wheel 峰值可达几十 GB,
# 且本机还跑训练(RL/SFT 链对磁盘敏感),部署 cron 必须让路,以免峰值挤爆磁盘。
# 覆盖入口:cron 直跑 / 30min 续跑 / 15min 异常重试(三者都走本脚本)。
MIN_FREE_GB="${AI_HARNESS_MIN_FREE_GB:-150}"
FREE_GB=$(df -BG "$HARNESS_ROOT" | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]; then
    echo "[$(date -Iseconds)] DISK_GATE: free=${FREE_GB}GB < ${MIN_FREE_GB}GB,本次 cron 跳过(不起新 run,不影响已在后台的下载)" >&2
    exit 0
fi

# ============ 续跑配额常量(入口 WAIT_GATE 和尾部续跑判断共用) ============
RESUME_COUNTER="$HARNESS_ROOT/state/resume-count-$(date +%Y-%m-%d).txt"
MAX_RESUMES=3
RESUME_DELAY_MIN=30
BG_RECHECK_DELAY_MIN=10
RESUME_LOG="$HARNESS_ROOT/logs/cron-resume-$(date +%Y%m%d).log"
mkdir -p "$HARNESS_ROOT/logs" "$HARNESS_ROOT/state"

# 免配额复查链:纯 bash sleep + 重入 daily.sh,0 token。
# 用 state/bg-recheck.pid 去重,防多条链并发膨胀。
schedule_bg_recheck() {
    local marker="$HARNESS_ROOT/state/bg-recheck.pid" old
    old=$(cat "$marker" 2>/dev/null || true)
    if [ -n "$old" ] && [ -d "/proc/$old" ]; then
        echo "[$(date -Iseconds)] 复查链已在等(PID=$old),不重复调度" >> "$RESUME_LOG"
        return 0
    fi
    # 200>&- 关键:复查链子进程不许继承 flock FD,否则它睡 10min 期间锁死所有 daily.sh 启动
    nohup bash -c "sleep $((BG_RECHECK_DELAY_MIN * 60)) && cd '$HARNESS_ROOT' && AI_HARNESS_BG_RECHECK=1 AI_HARNESS_IS_RESUME=1 bash cron/daily.sh" \
        >> "$RESUME_LOG" 2>&1 200>&- &
    echo $! > "$marker"
    echo "[$(date -Iseconds)] 复查链已调度(PID=$!,${BG_RECHECK_DELAY_MIN}min 后 0-token 复查后台下载)" >> "$RESUME_LOG"
}

# ============ WAIT_GATE: 后台下载健康等待中 → 不起 agent ============
# (fix: 2026-06-12-resume-fake-exit;khala 实战 4 次续跑全空转,~80min/300+ API 调用
#  只为"看一眼下载还在不在"。后台 setsid nohup 下载不需要 agent 守。)
# helper 区分:WAITING=健康后台进程(活着/非僵尸/30min 内有进度) vs NEEDS_AGENT(死/僵尸/停滞/无 sentinel)。
BG_CHECK=$(bash "$HARNESS_ROOT/scripts/check-bg-downloads.sh" 2>/dev/null || true)
BG_WAITING=$(echo "$BG_CHECK" | grep "^WAITING" || true)
BG_NEEDS=$(echo "$BG_CHECK" | grep "^NEEDS_AGENT" || true)

if [ -n "$BG_WAITING" ] && [ -z "$BG_NEEDS" ]; then
    {
        echo "[$(date -Iseconds)] WAIT_GATE: 所有 in_progress 均为健康后台下载,无需 agent,本次不启动 worker(0 token):"
        echo "$BG_WAITING"
    } >> "$RESUME_LOG"
    schedule_bg_recheck
    exit 0
fi

# 复查链触发且确有项目需要 agent → 此次启动消耗一个续跑配额
# (防止"下载反复崩 → 复查 → 起 worker"绕过 3 次/天上限无限烧钱;
#  自然 cron(10:00)与人工启动不走此分支,不消耗配额)
if [ -n "${AI_HARNESS_BG_RECHECK:-}" ] && [ -n "$BG_NEEDS" ]; then
    rc_now=$(cat "$RESUME_COUNTER" 2>/dev/null || echo 0)
    case "$rc_now" in ''|*[!0-9]*) rc_now=0 ;; esac
    if [ "$rc_now" -ge "$MAX_RESUMES" ]; then
        echo "[$(date -Iseconds)] 复查发现需 agent [$(echo "$BG_NEEDS" | awk '{print $2}' | tr '\n' ' ')],但今日续跑配额(${MAX_RESUMES})已用完,留给次日 cron" >> "$RESUME_LOG"
        exit 0
    fi
    echo $((rc_now + 1)) > "$RESUME_COUNTER"
    echo "[$(date -Iseconds)] 复查链发现需 agent → 启动 worker(消耗续跑配额 $((rc_now + 1))/${MAX_RESUMES})" >> "$RESUME_LOG"
fi

# 🔴 auto-daily cron 在 launch 时还不知道 slug(由 auto-daily skill 动态 pick),
# 因此 LOG_DIR 保持全局 runs/cron-<ts>,作为唯一合法的"预挑暂存"目录(N=1,无跨项目混杂)。
# slug 已知后 SubAgent 的双写仍走 $AI_HARNESS_RUN_DIR(= 本 cron 目录)。
# (Fix: 2026-06-08-run-dir-into-workspace §已知偏差 1)
LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# ============ run-id 注册 + hook_state 初始化 ============
RUN_ID=$(basename "$LOG_DIR")
echo "$RUN_ID" > "$(dirname "$LOG_DIR")/.current_run_id"
# 导出完整 run 目录路径给 hook(权威),hook 不必自拼 runs/$RUN_ID。
export AI_HARNESS_RUN_ID="$RUN_ID"
export AI_HARNESS_RUN_DIR="$LOG_DIR"
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

# ============ 代理环境 HF 下载优化(避免代理 503 Too many open connections) ============
# Fix: 2026-06-08-proxy-hf-download-503-fix
# 注:本机无直连外网能力,不能 unset proxy 或 no_proxy,只能禁 Xet + 降并发。
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_CONCURRENCY="${HF_HUB_DOWNLOAD_CONCURRENCY:-2}"

# ============ 启动前对账:sentinel / R3 wall-clock / 老 runs ============
# (Fix: 2026-06-10-external-review-sentinel-wallclock-runs-fix)
# 顺序重要:先把死掉的 "running" sentinel 与 stale "running" state 改写为真相,
# 否则本次 worker 的接续判断会基于谎言。三个脚本都保守:不 kill、不碰用户自管目录。
bash "$HARNESS_ROOT/scripts/reconcile-sentinels.sh" "$HARNESS_ROOT" >> "$LOG_DIR/cleanup.log" 2>&1 || true
bash "$HARNESS_ROOT/scripts/reconcile-state.sh" "$HARNESS_ROOT" >> "$LOG_DIR/cleanup.log" 2>&1 || true
bash "$HARNESS_ROOT/scripts/enforce-wallclock.sh" "$HARNESS_ROOT" >> "$LOG_DIR/cleanup.log" 2>&1 || true
bash "$HARNESS_ROOT/scripts/clean-old-runs.sh" --delete "$HARNESS_ROOT" >> "$LOG_DIR/cleanup.log" 2>&1 || true

# ============ 启动前清理僵尸 worker ============
python3 - <<'PYEOF' 2>>"$LOG_DIR/cleanup.log" || true
import os, pathlib, signal, time
root = pathlib.Path("/root/ai-auto-harness")
# 扫新(workspace/<slug>/runs/)+ legacy(全局 runs/)两处 worker.pid。
# (Fix: 2026-06-08-run-dir-into-workspace)
worker_pids = list((root / "runs").glob("*/worker.pid")) + list(root.glob("workspace/*/runs/*/worker.pid"))
cleaned = []
for wpid_file in worker_pids:
    try:
        pid = int(wpid_file.read_text().strip())
    except Exception:
        continue
    if pid == os.getpid():
        continue
    # 检测 PID 存活(含僵尸检测 — os.kill(pid,0) 对 Z 态误判活)
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2]
        if stat == "Z":  # 僵尸=死
            pass  # fall through to cleanup
        else:
            continue  # 真活,跳过
    except (FileNotFoundError, IndexError):
        pass  # /proc 不存在=已死
    try:
        os.kill(pid, 0)  # 兜底
        continue
    except OSError:
        pass
    cache_dir = wpid_file.parent / ".cache"
    if cache_dir.exists():
        for pf in cache_dir.glob("*.pid"):
            try:
                cpid = int(pf.read_text().strip())
                # 僵尸检测
                try:
                    cstat = pathlib.Path(f"/proc/{cpid}/stat").read_text().split()[2]
                    if cstat == "Z":
                        continue  # 僵尸不用 SIGTERM,清理父进程即可
                except (FileNotFoundError, IndexError):
                    pass  # 已死
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

# ============ HERMES_MODE 分流 ============
# HERMES_MODE=1 时:只跑 0-token 预检(上面已跑完 reconcile+僵尸清理),不启动 CC worker。
# Hermes cron job 会在 preflight 输出后自行调度 agent,走 hermes/scripts/phase-*.sh。
# 共享逻辑(flock/磁盘/bg-check/reconcile)已在上面跑完,不需要重复。
if [ "${HERMES_MODE:-0}" = "1" ]; then
    echo "[$(date -Iseconds)] HERMES_MODE=1: 0-token 预检完成,跳过 CC worker 启动" >> "$LOG_DIR/cleanup.log"
    # 跑 Hermes 版 preflight.sh(输出状态摘要给后续 Hermes agent)
    bash "$HARNESS_ROOT/hermes/scripts/harness-preflight.sh" >> "$LOG_DIR/hermes-preflight.log" 2>&1 || true
    echo "[$(date -Iseconds)] Hermes preflight 完成,退出" >> "$LOG_DIR/cleanup.log"
    exit 0
fi

# ============ trap cleanup ============
WORKER_PID_FILE="$LOG_DIR/worker.pid"
echo "$$" > "$WORKER_PID_FILE"

cleanup() {
    local code=$?
    if [ -n "${HAHA_PID:-}" ]; then
        kill -TERM "$HAHA_PID" 2>/dev/null || true
    fi
    echo "exit=$code" > "$LOG_DIR/cron.status"

    # P6 fix: 异常退出自动重试（claude-haha 非 0 退出）
    if [ "$code" -ne 0 ] && [ -z "${AI_HARNESS_IS_RESUME:-}" ]; then
        echo "[$(date -Iseconds)] claude-haha 异常退出 (code=$code)，15 分钟后重试" >> "$LOG_DIR/cleanup.log"
        exec 200>&-  # 释放 flock
        # 注:env 前缀必须挂在 daily.sh 上(原写法挂在 cd 上,变量传不进 daily.sh
        # → 重试再失败会无限调度重试;fix: 2026-06-11-p1-p12-implementation-corrections)
        nohup bash -c "sleep 900 && cd '$HARNESS_ROOT' && AI_HARNESS_IS_RESUME=1 bash cron/daily.sh" \
            >> "$HARNESS_ROOT/logs/cron-retry-$(date +%Y%m%d).log" 2>&1 &
    fi

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
AI_HARNESS_RUN_ID="$RUN_ID" \
AI_HARNESS_RUN_DIR="$AI_HARNESS_RUN_DIR" \
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

# ============ 续跑判断 (P0: 2026-06-11-cron-resume-and-optimization;§7 假退出修正 2026-06-12) ============
# claude-haha 退出后,用 check-bg-downloads.sh 区分两类未完成项目:
#   NEEDS_AGENT(进程死/僵尸/停滞/无 running sentinel)→ 30min 续跑,消耗配额(3 次/天)
#   WAITING(后台下载健康)→ 不消耗配额,调度 10min 免费复查链(0 token,下载一结束就能接续)
# 常量已在入口段定义(RESUME_COUNTER/MAX_RESUMES/RESUME_DELAY_MIN/schedule_bg_recheck)。
resume_count=$(cat "$RESUME_COUNTER" 2>/dev/null || echo 0)
case "$resume_count" in ''|*[!0-9]*) resume_count=0 ;; esac

BG_CHECK_TAIL=$(bash "$HARNESS_ROOT/scripts/check-bg-downloads.sh" 2>/dev/null || true)
NEEDS_AGENT_SLUGS=$(echo "$BG_CHECK_TAIL" | awk '/^NEEDS_AGENT/{print $2}')
WAITING_SLUGS=$(echo "$BG_CHECK_TAIL" | awk '/^WAITING/{print $2}')

if [ -n "$NEEDS_AGENT_SLUGS" ] && [ "$resume_count" -lt "$MAX_RESUMES" ]; then
    resume_count=$((resume_count + 1))
    echo "$resume_count" > "$RESUME_COUNTER"
    echo "[$(date -Iseconds)] 续跑 ${resume_count}/${MAX_RESUMES}: 需 agent 项目 [$(echo $NEEDS_AGENT_SLUGS | tr '\n' ' ')]，${RESUME_DELAY_MIN} 分钟后重跑" >> "$LOG_DIR/cleanup.log"
    # 释放 flock 锁，让续跑能获取
    exec 200>&-
    # 后台 sleep + 重启 daily.sh（nohup 确保不受当前 shell 退出影响）
    nohup bash -c "sleep $((RESUME_DELAY_MIN * 60)) && cd '$HARNESS_ROOT' && bash cron/daily.sh" \
        >> "$HARNESS_ROOT/logs/cron-resume-$(date +%Y%m%d).log" 2>&1 &
    echo "[$(date -Iseconds)] 续跑已调度 (PID=$!)" >> "$LOG_DIR/cleanup.log"
elif [ -n "$NEEDS_AGENT_SLUGS" ]; then
    # 今日续跑配额用完 → 只停止续跑,**不**强标 paused_for_human。
    # (原实现会把仍在合法跨 cron 下载的 paused_in_progress 项目误标为 paused_for_human,
    #  而次日 cron 的接续筛选排除 paused_for_human → 大权重项目被永久搁浅。
    #  paused_in_progress 本来就是"下次 cron 接续"的设计状态,次日 10:00 自然继续;
    #  真正的失败升级由 R3 超时/3 轮修复上限走 request-human-intervention 正规通道。
    #  fix: 2026-06-11-p1-p12-implementation-corrections)
    echo "[$(date -Iseconds)] 今日续跑配额(${MAX_RESUMES})已用完,留给次日 cron 接续: [$(echo $NEEDS_AGENT_SLUGS | tr '\n' ' ')]" >> "$LOG_DIR/cleanup.log"
elif [ -n "$WAITING_SLUGS" ]; then
    # 后台下载健康 → 不续跑、不消耗配额,只挂免费复查链(fix: 2026-06-12-resume-fake-exit)
    echo "[$(date -Iseconds)] [$(echo $WAITING_SLUGS | tr '\n' ' ')] 后台下载健康进行中,不消耗续跑配额,挂 0-token 复查链" >> "$LOG_DIR/cleanup.log"
    exec 200>&-
    schedule_bg_recheck
fi

# 清理 3 天前的续跑计数文件(计数器按日期命名,无需午夜重置 —
# 原"≥23 点删除当日计数"反而会在深夜多放 3 次续跑配额,已移除)
find "$HARNESS_ROOT/state" -name 'resume-count-*.txt' -mtime +3 -delete 2>/dev/null || true

exit $RET
