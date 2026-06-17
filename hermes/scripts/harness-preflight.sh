#!/bin/bash
# harness-preflight.sh — Hermes cron 0-token 预检(迁移方案 4.3 / 9.3)
# 用法:hermes cron 的 --script(默认模式:stdout 注入 agent prompt)
# 职责:并发判定 + reconcile 三件套 + 环境自检 + 状态摘要。
# 只输出 agent 需要的结论,不输出过程噪声。
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT" || { echo "FATAL: $HARNESS_ROOT 不存在,中止"; exit 1; }
mkdir -p state

echo "=== ai-auto-harness preflight $(date -Iseconds) ==="

# ---- -1. 磁盘门槛(2026-06-12 用户要求,与 CC daily.sh 同一阈值) ----
# free < 150GB 不起新 run:本机还跑训练,部署峰值(权重+venv+wheel)必须让路。
MIN_FREE_GB="${AI_HARNESS_MIN_FREE_GB:-150}"
FREE_GB=$(df -BG "$HARNESS_ROOT" | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]; then
    echo "DISK_GATE: free=${FREE_GB}GB < ${MIN_FREE_GB}GB,磁盘不足。"
    echo "→ 指令:本次不接续、不选新项目、不 dispatch 任何阶段;输出一行'磁盘门槛跳过'即结束。已在后台的下载不受影响。"
    exit 0
fi

# ---- 0. 并发判定(替代 CC daily.sh 的 flock 全程持锁) ----
# guard.env.sh 在 harness 树内每个 bash 启动时 touch state/agent-heartbeat。
# 心跳 < 30min = 可能有另一个 agent run(本 cron 或人工 session)在干活。
HB="state/agent-heartbeat"
if [ -f "$HB" ]; then
    AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$HB") ) / 60 ))
    if [ "$AGE_MIN" -lt 30 ]; then
        echo "BUSY: agent-heartbeat ${AGE_MIN}min 前仍在更新,疑似已有 run 在进行。"
        echo "→ 指令:本次只读 workspace/*/state.json 输出一行状态,不 dispatch 任何阶段,立即结束。"
        exit 0
    fi
fi
# 第二轴:CC 版 run 不写心跳,用 state.json 新鲜度兜底(status=running 且 20min 内被 agent 更新过)
NOW=$(date +%s)
for f in workspace/*/state.json; do
    [ -f "$f" ] || continue
    ST=$(jq -r '.status // ""' "$f" 2>/dev/null)
    [ "$ST" = "running" ] || continue
    UP=$(jq -r '.updated_at // ""' "$f" 2>/dev/null)
    UPS=$(date -d "$UP" +%s 2>/dev/null) || continue
    if [ $(( NOW - UPS )) -lt 1200 ] || [ "$UPS" -gt "$NOW" ]; then
        echo "BUSY: $(jq -r .slug "$f") state.json status=running 且 updated_at=$UP(<20min),另一条流水线(可能是 CC 版 cron)正在干活。"
        echo "→ 指令:本次只读状态输出一行摘要,不 dispatch 任何阶段,立即结束。"
        exit 0
    fi
done

# ---- 0.5 后台下载免守判定(fix: 2026-06-12-resume-fake-exit) ----
# 后台 setsid nohup 下载健康时不需要 agent(khala 实战 4 次续跑全空转)。
# helper 同 CC 版共用:WAITING=健康(活/非僵尸/30min 内有进度) vs NEEDS_AGENT。
BG_CHECK=$(bash scripts/check-bg-downloads.sh 2>/dev/null || true)
BG_WAITING=$(echo "$BG_CHECK" | grep "^WAITING" || true)
BG_NEEDS=$(echo "$BG_CHECK" | grep "^NEEDS_AGENT" || true)
if [ -n "$BG_WAITING" ] && [ -z "$BG_NEEDS" ]; then
    echo "BG_DOWNLOAD: 所有 in_progress 均为健康后台下载:"
    echo "$BG_WAITING"
    echo "→ 指令:不接续、不选新项目、不 dispatch;输出一行'后台下载进行中,无需介入'即结束(1 turn)。"
    exit 0
fi
[ -n "$BG_NEEDS" ] && { echo "--- 需 agent 介入的后台任务 ---"; echo "$BG_NEEDS"; }

# ---- 1. reconcile 三件套(平台代码兜底,保守:只写文件不杀进程) ----
for s in reconcile-sentinels.sh reconcile-state.sh enforce-wallclock.sh; do
    if [ -x "scripts/$s" ] || [ -f "scripts/$s" ]; then
        OUT=$(bash "scripts/$s" 2>&1) || true
        # 只透出有动作的行(修正了什么);"0 xxx(s) updated" 横幅是无事行,过滤
        echo "$OUT" | grep -iE "fixed|corrected|marked|wallclock|dead|zombie|→" \
                    | grep -vE ": 0 [a-z-]+\(s\)" | head -10 || true
    fi
done

# ---- 2. 环境自检 ----
# no_proxy 污染检查(fix #36:外网域名进 no_proxy = 强制直连 = 断网)
if grep -E "^(no_proxy|NO_PROXY)=" .env 2>/dev/null | grep -qiE "huggingface|github|firebaseio"; then
    echo "🔴 FATAL: .env 的 no_proxy 含外网域名(本机无直连,会断网)。修复 .env 后再跑。"
    exit 0
fi
# 代理连通性(经代理拿 HF API,5s 超时;失败只警告不阻断)
PROXY_OK=$(. ./.env 2>/dev/null; curl -sL -m 8 -o /dev/null -w "%{http_code}" https://huggingface.co/api/models/gpt2 2>/dev/null || echo 000)
[ "$PROXY_OK" = "200" ] || echo "⚠️ 代理探测 HF API 返回 $PROXY_OK(非 200),下载可能受阻"

# ---- 3. 资源水位 ----
DISK_FREE_GB=$(df -BG /root | awk 'NR==2 {gsub("G","",$4); print $4}')
echo "磁盘 free: ${DISK_FREE_GB}GB"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' '{printf "GPU%s: used=%dMiB free=%dMiB\n", $1, $2, $3}' || echo "⚠️ nvidia-smi 不可用"

# workspace 占用摘要（只输出 top 5 + 可清理汇总，不输出全表）
echo "--- workspace 占用 top5 ---"
bash scripts/workspace-stats.sh 2>/dev/null | grep -E '^\s+\S+\s+[0-9]+' | sort -k2 -rh | head -5 || true
ARCHIVED_INFO=$(bash scripts/workspace-stats.sh 2>/dev/null | grep "可清理:" || true)
[ -n "$ARCHIVED_INFO" ] && echo "  $ARCHIVED_INFO"

# ---- 4. 接续/积压摘要 ----
echo "--- in_progress 项目(接续优先,不挑新) ---"
FOUND=0
for f in workspace/*/state.json; do
    [ -f "$f" ] || continue
    LINE=$(jq -r 'select(.phase != null)
        | select((.phase | IN("done","archived","paused_for_human")) | not)
        | select((.status // "") != "paused_for_human")
        | "\(.slug) phase=\(.phase) status=\(.status // "?") updated=\(.updated_at // "?") prev_fail=\(.previous_failure // "-")"' \
        "$f" 2>/dev/null)
    if [ -n "$LINE" ]; then echo "  $LINE"; FOUND=1; fi
done
[ "$FOUND" = "0" ] && echo "  (无 — 走 scan_today 选新项目)"

echo "--- *_RESOLVED 重试标记(P8:资源已释放,必须重试) ---"
grep -l "_RESOLVED" workspace/*/state.json 2>/dev/null | while read -r f; do
    jq -r '"  \(.slug): previous_failure=\(.previous_failure)"' "$f" 2>/dev/null
done || true

echo "--- pending_human 积压(跳过这些 slug,报告里标注) ---"
ls pending_human/*.md 2>/dev/null | sed 's/^/  /' || echo "  (无)"

echo "--- outcomes 待回填 ---"
if [ -s "state/outcomes-pending.jsonl" ]; then
    echo "  state/outcomes-pending.jsonl 有 $(wc -l < state/outcomes-pending.jsonl) 行,需逐行重试 record_outcome"
else
    echo "  (无)"
fi

echo "=== preflight end(以上摘要进入你的上下文,按 ai-auto-harness skill 的工作流执行)==="
