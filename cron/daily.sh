#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:30 触发)
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 加载 .env 若有
[ -f .env ] && set -a && source .env && set +a

# 启动 claude-haha headless 跑 /auto-daily
LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M)"
mkdir -p "$LOG_DIR"

./bin/claude-haha --print "/auto-daily" \
    > "$LOG_DIR/cron.out" 2> "$LOG_DIR/cron.err"
RET=$?

echo "exit=$RET" > "$LOG_DIR/cron.status"
exit $RET
