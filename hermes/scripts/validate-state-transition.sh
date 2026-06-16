#!/bin/bash
# validate-state-transition.sh — 检查 phase 序列合法性
#
# 用法: bash hermes/scripts/validate-state-transition.sh <workspace_path>
#
# 合法流转:
#   null → fetching → installing → running → verifying → runbook_pending → cleanup_pending → done/archived
#
# 返回: 0=合法, 1=非法(输出错误信息到 stderr)
set -uo pipefail

WORKSPACE="$1"
STATE="$WORKSPACE/state.json"

if [ ! -f "$STATE" ]; then
  echo "ERROR: state.json not found at $STATE" >&2
  exit 1
fi

# 定义合法的 phase 序列(索引=顺序)
declare -A PHASE_ORDER=(
  ["intake"]=1
  ["fetching"]=2
  ["installing"]=3
  ["running"]=4
  ["verifying"]=5
  ["runbook_pending"]=6
  ["cleanup_pending"]=7
  ["done"]=8
  ["archived"]=8
)

# 当前 phase
CURRENT_PHASE=$(jq -r '.phase // "null"' "$STATE" 2>/dev/null)
PHASES_DONE=$(jq -r '.phases_done // [] | join(",")' "$STATE" 2>/dev/null)

# 检查 phase 合法性
if [ "$CURRENT_PHASE" != "null" ] && [ -z "${PHASE_ORDER[$CURRENT_PHASE]:-}" ]; then
  echo "ERROR: Unknown phase '$CURRENT_PHASE' in $STATE" >&2
  exit 1
fi

# 检查 phases_done 与 phase 的一致性
# 如果 phase=verifying,则 phases_done 应包含 intake,fetch-weights,install-env,run-and-repair
declare -A DONE_REQUIRED=(
  ["fetching"]="intake"
  ["installing"]="intake,fetch-weights"
  ["running"]="intake,fetch-weights,install-env"
  ["verifying"]="intake,fetch-weights,install-env,run-and-repair"
  ["runbook_pending"]="intake,fetch-weights,install-env,run-and-repair,verify"
  ["cleanup_pending"]="intake,fetch-weights,install-env,run-and-repair,verify,write-deploy-runbook"
)

REQUIRED="${DONE_REQUIRED[$CURRENT_PHASE]:-}"
if [ -n "$REQUIRED" ]; then
  IFS=',' read -ra REQ_ARR <<< "$REQUIRED"
  for req in "${REQ_ARR[@]}"; do
    if ! echo "$PHASES_DONE" | grep -q "$req"; then
      echo "WARNING: phase=$CURRENT_PHASE but '$req' not in phases_done ($PHASES_DONE)" >&2
      # 不 exit 1,只是警告(有些 phase 可能有合法跳过)
    fi
  done
fi

# 检查状态组合合法性
STATUS=$(jq -r '.status // "unknown"' "$STATE" 2>/dev/null)
case "$STATUS" in
  done|archived)
    # phase 必须是 done/archived
    if [ "$CURRENT_PHASE" != "done" ] && [ "$CURRENT_PHASE" != "archived" ]; then
      echo "WARNING: status=$STATUS but phase=$CURRENT_PHASE (should be done/archived)" >&2
    fi
    ;;
  running|paused_in_progress)
    # phase 不能是 done/archived
    if [ "$CURRENT_PHASE" = "done" ] || [ "$CURRENT_PHASE" = "archived" ]; then
      echo "ERROR: status=$STATUS but phase=$CURRENT_PHASE (inconsistent)" >&2
      exit 1
    fi
    ;;
esac

exit 0
