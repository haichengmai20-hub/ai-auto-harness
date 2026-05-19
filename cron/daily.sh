#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:30 触发)
#
# 用 --bare 模式启动 claude-haha:
#   - 跳过 OAuth / keychain / 自动 plugin sync 等(规避 Privoxy 拦截造成的启动挂起)
#   - Anthropic auth 严格走 ANTHROPIC_API_KEY(.env 里配)
#   - 通过 --add-dir / --settings 显式注入项目上下文
# 注意:--bare 也跳过 hooks,所以 transcript.jsonl 不会自动产 — skill 内 Bash 直接写
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 加载 .env(API key + BASE_URL)
[ -f .env ] && set -a && source .env && set +a

# 每次 cron 跑生成独立 run-id 目录,捕获 stdout/stderr
LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M)"
mkdir -p "$LOG_DIR"

./bin/claude-haha \
    --bare \
    --add-dir "$HARNESS_ROOT" \
    --settings "$HARNESS_ROOT/.claude/settings.json" \
    --print "/auto-daily" \
    > "$LOG_DIR/cron.out" 2> "$LOG_DIR/cron.err"
RET=$?

echo "exit=$RET" > "$LOG_DIR/cron.status"
exit $RET
