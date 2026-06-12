#!/bin/bash
# monitor-poll.sh — no_agent 巡检 cron(迁移方案 9.1,替代 LLM 驱动的 monitor-ride-along)
# 用法:hermes cron create "every 5m" --no-agent --script monitor-poll.sh
# 约定:无异常 = 空输出 = 静默不投递;有异常才输出告警行。0 token。
# 保守边界:只读 + 调用既有 reconcile(只写 sentinel/state 文件,绝不杀进程)。
# R-HO-1:GPU 占用是用户训练,不算异常,不报。
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT" 2>/dev/null || exit 0

ALERTS=""

# 只在"有活跃部署"时巡检(心跳 < 120min),否则全静默
HB="state/agent-heartbeat"
ACTIVE=0
if [ -f "$HB" ]; then
    AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$HB") ) / 60 ))
    [ "$AGE_MIN" -lt 120 ] && ACTIVE=1
fi
# running 状态的 state.json 也算活跃(跨 cron 的后台下载)
if [ "$ACTIVE" = "0" ]; then
    grep -ls '"status": *"running"' workspace/*/state.json >/dev/null 2>&1 && ACTIVE=1
fi
[ "$ACTIVE" = "0" ] && exit 0

# 1. 假 running sentinel(进程死/僵尸但 sentinel 还 running)→ reconcile 修正并告警
RS_OUT=$(bash scripts/reconcile-sentinels.sh 2>&1 | grep -iE "dead|zombie|fixed|→" | grep -vE ": 0 [a-z-]+\(s\)" | head -5) || true
[ -n "$RS_OUT" ] && ALERTS="${ALERTS}🟡 sentinel 修正:\n${RS_OUT}\n"

# 2. wall-clock 超限 → enforce 标记并告警
WC_OUT=$(bash scripts/enforce-wallclock.sh 2>&1 | grep -iE "wallclock|paused|exceed|→" | grep -vE ": 0 [a-z-]+\(s\)" | head -5) || true
[ -n "$WC_OUT" ] && ALERTS="${ALERTS}🟡 wall-clock 超限:\n${WC_OUT}\n"

# 3. 磁盘水位
DISK_FREE_GB=$(df -BG /root | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "${DISK_FREE_GB:-999}" -lt 60 ]; then
    ALERTS="${ALERTS}🔴 磁盘 free 仅 ${DISK_FREE_GB}GB(< 60GB),下载/安装可能写满\n"
fi

# 4. 下载进度停滞(running 的 fetch sentinel,对应 .incomplete 30min 无 mtime 更新)
for sj in workspace/*/.cache/handoff/fetch-weights-*.json; do
    [ -f "$sj" ] || continue
    STATUS=$(jq -r '.status // ""' "$sj" 2>/dev/null)
    [ "$STATUS" = "running" ] || continue
    LDIR=$(jq -r '.local_dir // ""' "$sj" 2>/dev/null)
    [ -d "$LDIR" ] || continue
    NEWEST=$(find "$LDIR" -name "*.incomplete" -mmin -30 2>/dev/null | head -1)
    ANY=$(find "$LDIR" -name "*.incomplete" 2>/dev/null | head -1)
    if [ -n "$ANY" ] && [ -z "$NEWEST" ]; then
        ALERTS="${ALERTS}🟡 下载疑似停滞: $sj 状态 running 但 $LDIR 的 .incomplete 30min 无更新\n"
    fi
done

# 5. guard 违规增量(自上次巡检以来的新违规)
GLOG="state/guard-violations.log"
MARK="state/.monitor-guard-offset"
if [ -f "$GLOG" ]; then
    TOTAL=$(wc -l < "$GLOG")
    LAST=$(cat "$MARK" 2>/dev/null || echo 0)
    case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    if [ "$TOTAL" -gt "$LAST" ]; then
        NEW=$(tail -n +"$((LAST + 1))" "$GLOG" | head -5)
        ALERTS="${ALERTS}🟡 R 规则违规 $((TOTAL - LAST)) 条(guard 已拦截):\n${NEW}\n"
        echo "$TOTAL" > "$MARK"
    fi
fi

[ -n "$ALERTS" ] && printf "=== ai-auto-harness monitor $(date -Iseconds) ===\n${ALERTS}"
exit 0
