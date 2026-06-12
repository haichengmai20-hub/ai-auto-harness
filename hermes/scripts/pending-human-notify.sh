#!/bin/bash
# pending-human-notify.sh — no_agent cron:pending_human/ 有新文件就推送(迁移方案 9.8)
# 用法:hermes cron create "every 30m" --no-agent --script pending-human-notify.sh --deliver telegram
# 空输出 = 静默。已通知过的文件不重复推(按文件名记录在 state/.pending-human-notified)。
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT" 2>/dev/null || exit 0

MARK="state/.pending-human-notified"
touch "$MARK"

NEW=""
for f in pending_human/*.md; do
    [ -f "$f" ] || continue
    if ! grep -qsxF "$f" "$MARK"; then
        NEW="${NEW}${f}\n"
    fi
done

# 已删除的(人处理完)从记录里清掉,下次再出现可重新通知
TMP=$(mktemp)
while IFS= read -r line; do
    [ -f "$line" ] && echo "$line"
done < "$MARK" > "$TMP"
mv "$TMP" "$MARK"

[ -z "$NEW" ] && exit 0

echo "=== ai-auto-harness 需要人手介入 ==="
printf "%b" "$NEW" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "--- $f ---"
    # 推标题 + 原因 + 建议(头 25 行足够人决策)
    head -25 "$f"
    echo "$f" >> "$MARK"
    echo ""
done
echo "处理完后删除对应 pending_human/<slug>.md,下次 cron 会重新尝试该项目。"
