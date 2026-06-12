#!/bin/bash
# check-bg-downloads.sh — 判定 in_progress 项目是"后台进程健康等待中"还是"需要 agent 介入"
# (fix: 2026-06-12-resume-fake-exit-fix / spec 2026-06-11-cron-resume-and-optimization §7)
#
# 消费方:cron/daily.sh(WAIT_GATE + 续跑判断)、hermes/scripts/harness-preflight.sh。
# 只读,不写任何文件,不杀任何进程。
#
# 输出(每个 in_progress 项目一行):
#   WAITING <slug> pid=<pid> sentinel=<file> note=<下载健康,无需 agent>
#   NEEDS_AGENT <slug> reason=<no_running_sentinel|pid_dead|pid_zombie|stalled_30min>
# 无 in_progress 项目 → 无输出。退出码恒 0。
#
# 判定规则(每个项目):
#   1) 找 $WORKSPACE/.cache/handoff/*.json 中 status=="running" 的 sentinel
#      - 一个都没有 → NEEDS_AGENT no_running_sentinel(该推进/重启了)
#   2) 对每个 running sentinel 查 PID:
#      - PID 不存在            → NEEDS_AGENT pid_dead(下载完成或崩溃,该接续了)
#      - /proc/<pid>/stat 是 Z → NEEDS_AGENT pid_zombie(容器 PID 1 不收尸,kill -0 会误判活 — #37 教训)
#      - 活着但 30min 无进度    → NEEDS_AGENT stalled_30min(防"活着但卡死"被无限跳过饿死)
#        进度依据:sentinel.local_dir 内最新文件 mtime,或 sentinel.log_path 的 mtime
#   3) 所有 running sentinel 都健康 → WAITING

set -uo pipefail
HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
STALL_MIN="${AI_HARNESS_STALL_MIN:-30}"

for sf in "$HARNESS_ROOT"/workspace/*/state.json; do
    [ -f "$sf" ] || continue
    SLUG=$(jq -r 'select(.status == "in_progress" or .status == "running" or .status == "paused_in_progress") | .slug // empty' "$sf" 2>/dev/null)
    [ -n "$SLUG" ] || continue
    WS=$(dirname "$sf")

    RUNNING_FOUND=0
    VERDICT=""
    DETAIL=""
    for sentinel in "$WS"/.cache/handoff/*.json; do
        [ -f "$sentinel" ] || continue
        STATUS=$(jq -r '.status // ""' "$sentinel" 2>/dev/null)
        [ "$STATUS" = "running" ] || continue
        RUNNING_FOUND=1
        PID=$(jq -r '.pid // ""' "$sentinel" 2>/dev/null)

        # PID 死活(含僵尸 — kill -0 对 Z 态误判活,必须读 /proc/<pid>/stat 第 3 列)
        if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
            VERDICT="NEEDS_AGENT"; DETAIL="reason=pid_dead sentinel=$(basename "$sentinel")"
            break
        fi
        PSTATE=$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null || echo "?")
        if [ "$PSTATE" = "Z" ]; then
            VERDICT="NEEDS_AGENT"; DETAIL="reason=pid_zombie sentinel=$(basename "$sentinel")"
            break
        fi

        # 停滞检测:local_dir 最新 mtime 或 log_path mtime,二者取其新
        LDIR=$(jq -r '.local_dir // ""' "$sentinel" 2>/dev/null)
        LOGP=$(jq -r '.log_path // ""' "$sentinel" 2>/dev/null)
        FRESH=0
        if [ -n "$LDIR" ] && [ -d "$LDIR" ]; then
            [ -n "$(find "$LDIR" -type f -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ] && FRESH=1
        fi
        if [ "$FRESH" = "0" ] && [ -n "$LOGP" ] && [ -f "$LOGP" ]; then
            [ -n "$(find "$LOGP" -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ] && FRESH=1
        fi
        # 进程刚起(< STALL_MIN)还没产出也算健康:看 sentinel 自身 mtime
        if [ "$FRESH" = "0" ]; then
            [ -n "$(find "$sentinel" -mmin "-$STALL_MIN" -print -quit 2>/dev/null)" ] && FRESH=1
        fi
        if [ "$FRESH" = "0" ]; then
            VERDICT="NEEDS_AGENT"; DETAIL="reason=stalled_${STALL_MIN}min pid=$PID sentinel=$(basename "$sentinel")"
            break
        fi
        DETAIL="pid=$PID sentinel=$(basename "$sentinel")"
    done

    if [ "$RUNNING_FOUND" = "0" ]; then
        echo "NEEDS_AGENT $SLUG reason=no_running_sentinel"
    elif [ "$VERDICT" = "NEEDS_AGENT" ]; then
        echo "NEEDS_AGENT $SLUG $DETAIL"
    else
        echo "WAITING $SLUG $DETAIL note=后台进程健康,无需 agent"
    fi
done
exit 0
