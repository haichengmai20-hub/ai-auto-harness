#!/bin/bash
# 通用 worker 启动器(对齐 ai-intel-deploy baseline 姿势)
#
# 用法:
#   bash cron/launch_worker.sh "<prompt>" "<log_dir>"
#
# 例:
#   bash cron/launch_worker.sh \
#     "请使用 auto-deploy skill 部署 https://github.com/tencent-ailab/SongGeneration" \
#     /root/ai-auto-harness/runs/manual-songgen-$(date +%s)
#
# 环境变量:
#   AI_AUTO_HARNESS_ROOT   默认 /root/ai-auto-harness
#   CLAUDE_HAHA_BIN        默认 $AI_AUTO_HARNESS_ROOT/bin/claude-haha
#   CLAUDE_CONFIG_DIR      默认 /root/.claude
#
# 启动 flags(经 smoke test 验证 work):
#   IS_SANDBOX=1                    必须,让 dangerously-skip-permissions 在 root 下可用
#   --dangerously-skip-permissions  workspace 内全权
#   --output-format stream-json     ndjson 事件流
#   --verbose                       每事件独立一行(供 trajectory.json 解析)
#   --settings ...                  权限白名单 + MCP scan server
#   (不用 --bare,会跳过 hooks/skills)
#   (不用 --add-dir,cwd 已经在 harness root 等价效果)
set -e

PROMPT="${1:-}"
LOG_DIR="${2:-}"

if [ -z "$PROMPT" ] || [ -z "$LOG_DIR" ]; then
    echo "usage: $0 '<prompt>' '<log_dir>'"
    exit 1
fi

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
CLAUDE_HAHA_BIN="${CLAUDE_HAHA_BIN:-$HARNESS_ROOT/bin/claude-haha}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/root/.claude}"

cd "$HARNESS_ROOT"
[ -f .env ] && set -a && source .env && set +a

mkdir -p "$LOG_DIR"
echo "{\"started_at\":\"$(date -Iseconds)\",\"prompt\":$(echo "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" > "$LOG_DIR/meta.json"

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

# 跑完落 trajectory.json(从 ndjson 抽关键事件)
python3 -c "
import json, pathlib
nd = pathlib.Path('$LOG_DIR/harness.stdout.ndjson')
out = pathlib.Path('$LOG_DIR/trajectory.json')
events = []
for line in nd.read_text().splitlines() if nd.exists() else []:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue
    typ = d.get('type')
    if typ == 'assistant':
        msg = d.get('message', {}).get('content', [])
        for c in msg if isinstance(msg, list) else []:
            if c.get('type') == 'tool_use':
                events.append({'type':'tool_use', 'name':c.get('name'),
                               'input_preview': str(c.get('input',{}))[:200]})
            elif c.get('type') == 'text':
                txt = c.get('text','')
                if txt.strip():
                    events.append({'type':'text', 'preview':txt[:300]})
    elif typ == 'result':
        events.append({'type':'result', 'subtype':d.get('subtype'),
                       'duration_ms':d.get('duration_ms'),
                       'cost_usd':d.get('total_cost_usd'),
                       'num_turns':d.get('num_turns')})
out.write_text(json.dumps(events, ensure_ascii=False, indent=2))
print(f'trajectory.json: {len(events)} events written')
" 2>>"$LOG_DIR/harness.stderr.log" || true

echo "{\"exit\":$RET,\"ended_at\":\"$(date -Iseconds)\"}" > "$LOG_DIR/cron.status"
exit $RET
