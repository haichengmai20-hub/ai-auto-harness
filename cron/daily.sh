#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:30 触发)
#
# 启动姿势(对齐 ai-intel-deploy baseline,经 smoke test 验证):
#   IS_SANDBOX=1                       让 --dangerously-skip-permissions 在 root 下可用
#   --dangerously-skip-permissions     跳过权限提示(workspace 内全权)
#   --output-format stream-json        输出 ndjson 事件流(供 trajectory 解析)
#   --verbose                          每个 tool_use / message 都是独立行
#   CLAUDE_HAHA_BIN(env)               允许外部覆盖 binary 路径
#
# 历史:之前用 --bare 跳过 OAuth/keychain,但发现 --bare 会跳过 hooks/skills,
#       导致 /auto-daily slash command 无法识别 → 静默退出.
#       baseline 姿势完整保留 hooks/skills,只用 IS_SANDBOX 绕过 root 检测.
set -e

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
CLAUDE_HAHA_BIN="${CLAUDE_HAHA_BIN:-$HARNESS_ROOT/bin/claude-haha}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/root/.claude}"

cd "$HARNESS_ROOT"

# 加载 .env(API key + BASE_URL + 可选 HF_TOKEN)
[ -f .env ] && set -a && source .env && set +a

# 每次 cron 跑生成独立 run-id 目录
LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# 触发主 agent 工作流 — 用自然语言 prompt 触发 auto-daily skill
PROMPT="请使用 auto-daily skill 执行今日 AI 项目部署工作流(读 ai-daily-scan findings → 挑 1 个 → 5 阶段 SubAgent → 写报告)."

CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
IS_SANDBOX=1 \
"$CLAUDE_HAHA_BIN" \
    -p "$PROMPT" \
    --output-format stream-json \
    --verbose \
    --dangerously-skip-permissions \
    --settings "$HARNESS_ROOT/.claude/settings.json" \
    > "$LOG_DIR/harness.stdout.ndjson" \
    2> "$LOG_DIR/harness.stderr.log"
RET=$?

# 落 trajectory 摘要(从 ndjson 抽 assistant + tool_use 行)
python3 -c "
import json, pathlib
ndjson_path = pathlib.Path('$LOG_DIR/harness.stdout.ndjson')
out_path = pathlib.Path('$LOG_DIR/trajectory.json')
events = []
for line in ndjson_path.read_text().splitlines():
    if not line.strip(): continue
    try:
        d = json.loads(line)
    except: continue
    if d.get('type') in ('assistant', 'user', 'result'):
        events.append({'type': d.get('type'), 'subtype': d.get('subtype'),
                       'uuid': d.get('uuid'), 'duration_ms': d.get('duration_ms')})
out_path.write_text(json.dumps(events, ensure_ascii=False, indent=2))
print(f'trajectory.json: {len(events)} events')
" 2>>"$LOG_DIR/harness.stderr.log" || true

echo "exit=$RET" > "$LOG_DIR/cron.status"
exit $RET
