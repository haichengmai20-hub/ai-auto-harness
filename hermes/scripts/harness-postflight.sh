#!/bin/bash
# harness-postflight.sh — no_agent 事后审计 cron(迁移方案 9.3,替代 CC session-end hook)
# 用法:hermes cron create "30 13 * * *" --no-agent --script harness-postflight.sh
# (排在 10:00 部署 run 的窗口之后;独立于 agent 生命周期,agent crash 也能跑)
# 职责:sentinel 审计 + 老 runs 清理(dry-run)+ guard 违规日汇总 + git commit 报告。
# 有发现才输出(投递);全干净 = 静默。
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT" 2>/dev/null || exit 0

OUT=""

# 1. sentinel 终态审计(保守:只写 sentinel 文件)
RS=$(bash scripts/reconcile-sentinels.sh 2>&1 | grep -iE "dead|zombie|fixed|→" | head -10) || true
[ -n "$RS" ] && OUT="${OUT}🟡 sentinel 审计修正:\n${RS}\n"

# 2. 老 runs 清理(默认 dry-run,只报告;真删需人确认后手动 --delete)
#    EXCLUDES 守 R-HO-2(songgen 两个 run 用户自己处理,绝不删)
CR=$(bash scripts/clean-old-runs.sh 2>&1 | grep -iE "would|delete|skip|GB|MB" | head -10) || true
[ -n "$CR" ] && OUT="${OUT}📦 runs 清理建议(dry-run,未真删):\n${CR}\n"

# 3. guard 违规当日汇总
GLOG="state/guard-violations.log"
if [ -f "$GLOG" ]; then
    TODAY=$(date +%Y-%m-%d)
    CNT=$(grep -c "^$TODAY" "$GLOG" 2>/dev/null || echo 0)
    if [ "${CNT:-0}" -gt 0 ]; then
        OUT="${OUT}⚠️ 今日 R 规则违规 ${CNT} 条(guard 已拦截/纠正,明细 state/guard-violations.log):\n$(grep "^$TODAY" "$GLOG" | awk '{$2=""; $3=""; print}' | sort | uniq -c | sort -rn | head -5)\n"
    fi
fi

# 4. git commit 报告/记忆(与 CC session-end.sh 行为对齐;只 commit 不 push)
if [ -n "$(git status --porcelain reports/ memory/ 2>/dev/null)" ]; then
    git add reports/ memory/ 2>/dev/null || true
    if git commit -m "ai-auto: hermes postflight 自动归档 reports/memory $(date +%Y-%m-%d)" >/dev/null 2>&1; then
        OUT="${OUT}✅ reports/memory 变更已 git commit\n"
    fi
fi

[ -n "$OUT" ] && printf "=== ai-auto-harness postflight $(date -Iseconds) ===\n${OUT}"
exit 0
