#!/bin/bash
# phase-runbook.sh — 从部署 trace 抽 AI 友好的部署手册
#
# 用法: bash hermes/scripts/phase-runbook.sh <slug> <run_id> [force_status]
#
# 输出:
#   - reports/runbooks/<slug>-<YYYY-MM-DD>.md
#   - workspace/<slug>/results/runbook.json
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"
RUN_ID="${2:-manual-$(date +%Y-%m-%d)}"
FORCE_STATUS="${3:-}"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
LOG="$WORKSPACE/logs/runbook.log"
RESULT="$WORKSPACE/results/runbook.json"
STATE="$WORKSPACE/state.json"
START_TS=$(date +%s)

mkdir -p "$(dirname "$LOG")" "$(dirname "$RESULT")" "/root/ai-auto-harness/reports/runbooks"

echo "=== PHASE_START phase=runbook slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" | tee -a "$LOG"

# ---- 0. 数据源收集 ----
VERIFY_RESULT=$(jq -c '.' "$WORKSPACE/results/verify.json" 2>/dev/null || echo '{"passed":false}')
VERIFY_PASSED=$(echo "$VERIFY_RESULT" | jq -r '.passed // false')
INTAKE_RESULT=$(jq -c '.' "$WORKSPACE/results/intake.json" 2>/dev/null || echo '{}')
INSTALL_RESULT=$(jq -c '.' "$WORKSPACE/results/install_env.json" 2>/dev/null || echo '{}')
RUN_RESULT=$(jq -c '.' "$WORKSPACE/results/run_and_repair.json" 2>/dev/null || echo '{}')
FETCH_RESULT=$(jq -c '.' "$WORKSPACE/results/fetch-weights.json" 2>/dev/null || echo '{}')

GITHUB_URL=$(jq -r '.github_url // "unknown"' "$WORKSPACE/state.json" 2>/dev/null)
STARTED_AT=$(jq -r '.started_at // .updated_at // "unknown"' "$WORKSPACE/state.json" 2>/dev/null)
UPDATED_AT=$(jq -r '.updated_at // "unknown"' "$WORKSPACE/state.json" 2>/dev/null)

# ---- 1. status 推导 ----
if [ -n "$FORCE_STATUS" ]; then
  STATUS="$FORCE_STATUS"
elif [ "$VERIFY_PASSED" = "true" ]; then
  STATUS="success"
else
  PHASE=$(jq -r '.phase // "unknown"' "$STATE" 2>/dev/null)
  if [ "$PHASE" = "done" ] || [ "$PHASE" = "archived" ]; then
    STATUS="incomplete_verify_failed"
  else
    STATUS="paused_at_${PHASE}"
  fi
fi

# ---- 2. duration 计算 ----
if [ "$STARTED_AT" != "unknown" ] && [ "$UPDATED_AT" != "unknown" ]; then
  START_S=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
  END_S=$(date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
  DURATION_MIN=$(( (END_S - START_S) / 60 ))
  [ "$DURATION_MIN" -lt 0 ] && DURATION_MIN=0
else
  DURATION_MIN=0
fi

# ---- 3. 踩坑抽取 ----
TRAPS=""
# 从 install result 提取 fixes_applied
INSTALL_FIXES=$(echo "$INSTALL_RESULT" | jq -r '.fixes_applied[]? // empty' 2>/dev/null)
if [ -n "$INSTALL_FIXES" ]; then
  while IFS= read -r fix; do
    TRAPS="${TRAPS}- **${fix}**: 见 install 阶段日志\n"
  done <<< "$INSTALL_FIXES"
fi

# 从 run result 提取 fixes_applied
RUN_FIXES=$(echo "$RUN_RESULT" | jq -r '.fixes_applied[]? // empty' 2>/dev/null)
if [ -n "$RUN_FIXES" ]; then
  while IFS= read -r fix; do
    TRAPS="${TRAPS}- **${fix}**: 见 run 阶段日志\n"
  done <<< "$RUN_FIXES"
fi

[ -z "$TRAPS" ] && TRAPS="(无特殊踩坑)"

# ---- 4. 生成 runbook ----
DATE=$(date +%Y-%m-%d)
RUNBOOK_PATH="/root/ai-auto-harness/reports/runbooks/${SLUG}-${DATE}.md"

cat > "$RUNBOOK_PATH" <<RBEOF
---
slug: ${SLUG}
date: ${DATE}
status: ${STATUS}
github: ${GITHUB_URL}
verify_passed: ${VERIFY_PASSED}
duration_min: ${DURATION_MIN}
total_cost_usd: null
---

# ${SLUG} 部署手册

> 自动生成于 ai-auto-harness (Hermes 方案A)

## 1. 给 AI 的部署 prompt

克隆 ${GITHUB_URL} 后,安装依赖并运行推理脚本。项目参数:
- 估算参数量: $(jq -r '.estimated_params_b // "unknown"' "$WORKSPACE/state.json" 2>/dev/null)
- Python: $(jq -r '.python_version // "3.12"' "$INTAKE_RESULT" 2>/dev/null)
- GPU: $(jq -c '.gpu_picks // []' "$INTAKE_RESULT" 2>/dev/null)

## 2. 前置要求

- Python $(jq -r '.python_version // "3.12"' "$INTAKE_RESULT" 2>/dev/null)
- GPU: $(jq -c '.gpu_picks // []' "$INTAKE_RESULT" 2>/dev/null) (如果项目需要)
- 磁盘: 权重+venv 约 $(du -sh "$WORKSPACE" 2>/dev/null | awk '{print $1}' || echo "unknown")

## 3. 5 Stage 完整指令

### Stage 1: clone
\`\`\`bash
git clone ${GITHUB_URL}
cd $(basename "$GITHUB_URL" .git)
\`\`\`

### Stage 2: 拉权重
\`\`\`bash
$(jq -r '.fetch_commands[]? // "echo 无权重下载命令"' "$FETCH_RESULT" 2>/dev/null | head -3 || echo "echo 无权重下载命令")
\`\`\`

### Stage 3: 装环境
\`\`\`bash
python3 -m venv venv && source venv/bin/activate
pip install -e ".[ocr-core]"  # 按项目实际调整
$(if [ -n "$INSTALL_FIXES" ]; then echo "# 隐式依赖补充:"; while IFS= read -r fix; do echo "# ${fix}"; done <<< "$INSTALL_FIXES"; fi)
\`\`\`

### Stage 4: 推理
\`\`\`bash
source venv/bin/activate
$(jq -r '.entry_script // "echo 无推理脚本"' "$INTAKE_RESULT" 2>/dev/null | head -5 || echo "echo 无推理脚本")
\`\`\`

### Stage 5: 验证
\`\`\`bash
# verify 独立判定: $( [ "$VERIFY_PASSED" = "true" ] && echo "通过" || echo "未通过" )
\`\`\`

## 4. 已知踩坑速查

${TRAPS}

## 5. 成本耗时

- 总耗时: ${DURATION_MIN} 分钟
- Token 成本: null (Hermes 方案A,terminal 直跑,3KB context)

## 6. Trace 指针

- workspace: ${WORKSPACE}/
- run_id: ${RUN_ID}
- verify_result: ${VERIFY_RESULT}

## 7. 失败 case 标记

- verify_passed: ${VERIFY_PASSED}
- failed_at: $(jq -r '.failed_at // "null"' "$VERIFY_RESULT" 2>/dev/null)
RBEOF

# ---- 5. 敏感信息扫描 ----
LEAKED=false
if grep -qE "hf_[a-zA-Z0-9]{30,}|sk-ant-[a-zA-Z0-9_-]{20,}" "$RUNBOOK_PATH" 2>/dev/null; then
  sed -i 's/hf_[a-zA-Z0-9]\{30,\}/${HF_TOKEN}/g' "$RUNBOOK_PATH"
  LEAKED=true
fi
if grep -qF "/root/ai-auto-harness/" "$RUNBOOK_PATH" 2>/dev/null; then
  sed -i 's|/root/ai-auto-harness/|${HARNESS_ROOT}/|g' "$RUNBOOK_PATH"
  LEAKED=true
fi
[ "$LEAKED" = true ] && echo "[runbook] 敏感信息已脱敏" | tee -a "$LOG"

# ---- 6. 落盘 ----
RUNBOOK_BYTES=$(wc -c < "$RUNBOOK_PATH" 2>/dev/null || echo 0)
AI_PROMPT_WORDS=$(grep -c '.' "$RUNBOOK_PATH" 2>/dev/null || echo 0)
DURATION_SEC=$(( $(date +%s) - START_TS ))

cat > "$RESULT" <<JSON
{
  "slug": "${SLUG}",
  "runbook_path": "${RUNBOOK_PATH}",
  "runbook_bytes": ${RUNBOOK_BYTES},
  "status": "${STATUS}",
  "ai_prompt_word_count": ${AI_PROMPT_WORDS},
  "stage_count": 5,
  "traps_documented": $(echo "$TRAPS" | grep -c '^\-' || echo 0),
  "completed_at": "$(date -Iseconds)",
  "duration_seconds": ${DURATION_SEC}
}
JSON

# 更新 state
jq --arg path "$RUNBOOK_PATH" '.phase = "runbook_pending" | .status = "done" | .phases_done += ["write-deploy-runbook"] | .runbook_path = $path | .updated_at = "'$(date -Iseconds)'"' "$STATE" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$STATE"

echo "[runbook] 完成: status=$STATUS path=$RUNBOOK_PATH duration=${DURATION_SEC}s" | tee -a "$LOG"
echo "=== PHASE_END phase=runbook slug=$SLUG status=done ts=$(date -Iseconds) ===" | tee -a "$LOG"
