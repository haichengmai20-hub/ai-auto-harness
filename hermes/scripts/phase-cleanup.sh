#!/bin/bash
# phase-cleanup.sh — 白名单清理 workspace 可重建产物(~30GB→~50MB)
#
# 用法: bash hermes/scripts/phase-cleanup.sh <slug> <run_id> [dry_run] [force_cleanup_incomplete]
#
# 保留: state.json / results/ / logs/ / runs/ / output/ / artifacts/
# 删除: venv / .cache / hf_cache / repo / weights (白名单固定 5 项)
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"
RUN_ID="${2:-manual-$(date +%Y-%m-%d)}"
DRY_RUN="${3:-false}"
FORCE_INCOMPLETE="${4:-false}"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
LOG="$WORKSPACE/logs/cleanup.log"
RESULT="$WORKSPACE/results/cleanup.json"
STATE="$WORKSPACE/state.json"
START_TS=$(date +%s)

mkdir -p "$(dirname "$LOG")" "$(dirname "$RESULT")"

echo "=== PHASE_START phase=cleanup slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" | tee -a "$LOG"

# ---- G1 路径前缀安全门 ----
if [[ "$WORKSPACE" != /root/ai-auto-harness/workspace/* ]] || [[ "$WORKSPACE" != *"$SLUG"* ]]; then
  echo "[cleanup] G1 REFUSED: 路径不合法 $WORKSPACE" | tee -a "$LOG"
  cat > "$RESULT" <<JSON
{"skipped":true,"skipped_reason":"G1_path_prefix_refused","removed":[],"freed_bytes":0,"freed_human":"0B","dry_run":$DRY_RUN,"completed_at":"$(date -Iseconds)","duration_seconds":0}
JSON
  exit 0
fi

# ---- G2 trace 完整 ----
RUN_DIR="$WORKSPACE/runs/$RUN_ID"
TRACE_OK=true
if [ ! -d "$RUN_DIR" ] || [ ! -f "$RUN_DIR/meta.json" ]; then
  # Hermes 下 trace 在 Hermes DB,检查 results/ 五阶段 json 齐全替代
  # 文件名映射: phase名 → 实际文件名
  for phase_file in intake.json fetch.json install.json run_and_repair.json verify.json; do
    [ -f "$WORKSPACE/results/$phase_file" ] || TRACE_OK=false
  done
fi
if [ "$TRACE_OK" = false ]; then
  echo "[cleanup] G2 REFUSED: trace 不完整" | tee -a "$LOG"
  # 写 pending_human
  echo "trace 不完整,无法安全清理" > "/root/ai-auto-harness/pending_human/${SLUG}.md" 2>/dev/null || true
  cat > "$RESULT" <<JSON
{"skipped":true,"skipped_reason":"G2_trace_incomplete","removed":[],"freed_bytes":0,"freed_human":"0B","dry_run":$DRY_RUN,"completed_at":"$(date -Iseconds)","duration_seconds":0}
JSON
  exit 0
fi

# ---- G3 runbook 已写 ----
RUNBOOK_PATH=$(jq -r '.runbook_path // empty' "$STATE" 2>/dev/null)
if [ -z "$RUNBOOK_PATH" ] || [ ! -f "$RUNBOOK_PATH" ] || [ "$(wc -c < "$RUNBOOK_PATH" 2>/dev/null)" -lt 1024 ]; then
  echo "[cleanup] G3 REFUSED: runbook 未写或过小" | tee -a "$LOG"
  cat > "$RESULT" <<JSON
{"skipped":true,"skipped_reason":"G3_runbook_missing","removed":[],"freed_bytes":0,"freed_human":"0B","dry_run":$DRY_RUN,"completed_at":"$(date -Iseconds)","duration_seconds":0}
JSON
  exit 0
fi

# ---- G4 verify 通过 ----
VERIFY_PASSED=$(jq -r '.passed // false' "$WORKSPACE/results/verify.json" 2>/dev/null)
if [ "$VERIFY_PASSED" != "true" ] && [ "$FORCE_INCOMPLETE" != "true" ]; then
  echo "[cleanup] G4 REFUSED: verify 未通过且未 force" | tee -a "$LOG"
  cat > "$RESULT" <<JSON
{"skipped":true,"skipped_reason":"G4_verify_failed","removed":[],"freed_bytes":0,"freed_human":"0B","dry_run":$DRY_RUN,"completed_at":"$(date -Iseconds)","duration_seconds":0}
JSON
  exit 0
fi

# ---- 白名单删除(固定 5 项,严禁增减) ----
TARGETS=(venv .cache hf_cache repo weights)
FREED_BYTES=0
REMOVED=()

for target in "${TARGETS[@]}"; do
  TARGET_PATH="$WORKSPACE/$target"
  if [ -d "$TARGET_PATH" ]; then
    SIZE_BYTES=$(du -sb "$TARGET_PATH" 2>/dev/null | awk '{print $1}')
    if [ "$DRY_RUN" = "true" ]; then
      echo "[DRY] would rm -rf $TARGET_PATH ($SIZE_BYTES bytes)" | tee -a "$LOG"
    else
      rm -rf "$TARGET_PATH" && echo "removed $TARGET_PATH ($SIZE_BYTES bytes)" | tee -a "$LOG"
    fi
    FREED_BYTES=$((FREED_BYTES + SIZE_BYTES))
    REMOVED+=("$target")
  else
    echo "skipped $TARGET_PATH (NOT EXIST)" | tee -a "$LOG"
  fi
done

# ---- 保留审计 ----
echo "[cleanup] 验证保留文件..." | tee -a "$LOG"
MISSED=()
for must_exist in state.json results logs; do
  if [ ! -e "$WORKSPACE/$must_exist" ]; then
    MISSED+=("$must_exist")
    echo "[cleanup] ⚠️ 保留项缺失: $must_exist" | tee -a "$LOG"
  fi
done

# ---- 落盘 ----
DURATION_SEC=$(( $(date +%s) - START_TS ))
FREED_HUMAN=$(numfmt --to=iec "$FREED_BYTES" 2>/dev/null || echo "${FREED_BYTES}B")
REMOVED_JSON=$(printf '%s\n' "${REMOVED[@]}" | jq -R . | jq -s .)

cat > "$RESULT" <<JSON
{
  "skipped": false,
  "skipped_reason": null,
  "removed": $REMOVED_JSON,
  "freed_bytes": $FREED_BYTES,
  "freed_human": "$FREED_HUMAN",
  "dry_run": $DRY_RUN,
  "completed_at": "$(date -Iseconds)",
  "duration_seconds": $DURATION_SEC
}
JSON

# 更新 state
jq '.phase = "archived" | .status = "done" | .phases_done += ["cleanup"] | .updated_at = "'$(date -Iseconds)'"' "$STATE" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$STATE"

# 清理 pending_human(如果存在)
rm -f "/root/ai-auto-harness/pending_human/${SLUG}.md" 2>/dev/null

echo "[cleanup] 完成: freed=$FREED_HUMAN removed=${#REMOVED[@]} duration=${DURATION_SEC}s" | tee -a "$LOG"
echo "=== PHASE_END phase=cleanup slug=$SLUG status=done ts=$(date -Iseconds) ===" | tee -a "$LOG"
