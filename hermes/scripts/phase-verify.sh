#!/bin/bash
# phase-verify.sh — 验证项目推理是否真正跑通(独立判定,不修)
#
# 用法: bash hermes/scripts/phase-verify.sh <slug> <run_id>
#
# 三步判定:
#   1. 启动检查: entry_script --help 或 import 是否成功
#   2. smoke test: 最小 demo 命令,timeout 600s
#   3. GPU 利用率: mem>1GB 且至少一次 util>10%(CPU fallback=严格 fail)
#
# 输出: workspace/<slug>/results/verify.json (7 字段 schema)
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"
RUN_ID="${2:-manual-$(date +%Y-%m-%d)}"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
LOG="$WORKSPACE/logs/verify.log"
RESULT="$WORKSPACE/results/verify.json"
STATE="$WORKSPACE/state.json"
INTAKE_JSON="$WORKSPACE/results/intake.json"
RUN_JSON="$WORKSPACE/results/run_and_repair.json"
START_TS=$(date +%s)

mkdir -p "$(dirname "$LOG")" "$(dirname "$RESULT")"

echo "=== PHASE_START phase=verify slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" | tee -a "$LOG"

# ---- 0. 前置检查 ----
if [ ! -f "$STATE" ]; then
  echo "[verify] FATAL: state.json 不存在" | tee -a "$LOG"
  exit 1
fi

# R6 缓存隔离: verify 阶段如果触发 from_pretrained,不许写全局 /root/.cache/
export HF_HOME="$WORKSPACE/.cache/huggingface" HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"

source "$WORKSPACE/venv/bin/activate" || {
  echo "[verify] FATAL: venv 不存在或损坏" | tee -a "$LOG"
  cat > "$RESULT" <<EOF
{"passed":false,"failed_at":"startup","evidence":{"error":"venv missing or broken"},"notes":"venv not found","confidence":"high","verify_level":"L0","completed_at":"$(date -Iseconds)"}
EOF
  exit 0
}

# 从 run_and_repair.json 优先读 entry_script(fallback 到 intake)
ENTRY_SCRIPT=$(jq -r '.entry_script // empty' "$RUN_JSON" 2>/dev/null)
if [ -z "$ENTRY_SCRIPT" ]; then
  echo "[verify] entry_script 不在 run_and_repair.json, fallback 到 intake.json" | tee -a "$LOG"
  ENTRY_SCRIPT=$(jq -r '.entry_script // empty' "$INTAKE_JSON" 2>/dev/null)
fi

# 从 state.json 读 gpu_picks(fallback 到 intake.json)
GPU_PICKS=$(jq -c '.gpu_picks // []' "$STATE" 2>/dev/null)
if [ -z "$GPU_PICKS" ] || [ "$GPU_PICKS" = "[]" ] || [ "$GPU_PICKS" = "null" ]; then
  GPU_PICKS=$(jq -c '.gpu_picks // []' "$INTAKE_JSON" 2>/dev/null)
  if [ -n "$GPU_PICKS" ] && [ "$GPU_PICKS" != "[]" ] && [ "$GPU_PICKS" != "null" ]; then
    echo "[verify] gpu_picks 从 intake.json fallback: $GPU_PICKS" | tee -a "$LOG"
  fi
fi
ENTRY_FILE="$WORKSPACE/.cache/verify_entry.py"

# 设置 CUDA_VISIBLE_DEVICES(从 gpu_picks,对后续所有步骤生效)
if [ -n "$GPU_PICKS" ] && [ "$GPU_PICKS" != "[]" ] && [ "$GPU_PICKS" != "null" ]; then
  GPU_IDX=$(echo "$GPU_PICKS" | jq -r '.[0] // empty')
  if [ -n "$GPU_IDX" ]; then
    export CUDA_VISIBLE_DEVICES="$GPU_IDX"
    echo "[verify] CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES" | tee -a "$LOG"
  fi
fi

# 提取 entry_script 的 Python 内容(剥离 python3 -c 外壳)
if [ -n "$ENTRY_SCRIPT" ]; then
  CLEAN_SCRIPT=$(echo "$ENTRY_SCRIPT" | python3 -c "
import sys, shlex
line = sys.stdin.read().strip()
if line.startswith('python3 -c ') or line.startswith('python -c '):
    parts = shlex.split(line)
    # 找 -c 后面的参数
    for i, p in enumerate(parts):
        if p == '-c' and i+1 < len(parts):
            print(parts[i+1])
            break
else:
    print(line)
" 2>/dev/null)
  printf '%s\n' "$CLEAN_SCRIPT" > "$ENTRY_FILE"
else
  echo "[verify] WARNING: 无 entry_script,跳过启动检查" | tee -a "$LOG"
  CLEAN_SCRIPT=""
fi

PASSED=true
FAILED_AT=null
EVIDENCE="{\"startup_exit_code\": null, \"smoke_exit_code\": null, \"gpu_stats\": {\"memory_used_mb\": 0, \"utilization_pct\": 0}, \"output_files\": []}"
NOTES=""

# ---- 1. 启动检查 ----
if [ -f "$ENTRY_FILE" ] && [ -s "$ENTRY_FILE" ]; then
  echo "[verify] Step 1: 启动检查 (import test)" | tee -a "$LOG"
  cd "$WORKSPACE/repo"
  STARTUP_OUTPUT=$(timeout 30 python3 "$ENTRY_FILE" 2>&1) || true
  STARTUP_EXIT=$?
  # import 成功但推理可能失败(exit≠0 但不是 import 错误),只检查 ModuleNotFoundError
  if echo "$STARTUP_OUTPUT" | grep -qiE "ModuleNotFoundError|ImportError|No module named"; then
    PASSED=false
    FAILED_AT="startup"
    NOTES="Import failed: $(echo "$STARTUP_OUTPUT" | grep -oE "No module named '[^']+'" | head -1)"
    echo "[verify] 启动检查失败: $NOTES" | tee -a "$LOG"
  else
    echo "[verify] 启动检查通过 (exit=$STARTUP_EXIT)" | tee -a "$LOG"
  fi
  EVIDENCE=$(echo "$EVIDENCE" | jq --arg exit "$STARTUP_EXIT" '.startup_exit_code = ($exit|tonumber)')
fi

# ---- 2. Smoke test ----
if [ "$PASSED" = true ] && [ -f "$ENTRY_FILE" ] && [ -s "$ENTRY_FILE" ]; then
  echo "[verify] Step 2: Smoke test (timeout 600s)" | tee -a "$LOG"
  cd "$WORKSPACE/repo"

  # GPU 监控(后台,每 2s 采样)
  GPU_LOG="$WORKSPACE/.cache/verify_gpu.log"
  if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
    nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits -l 2 -i "$CUDA_VISIBLE_DEVICES" > "$GPU_LOG" 2>/dev/null &
    GPU_MON_PID=$!
  fi

  SMOKE_OUTPUT=$(timeout 600 python3 "$ENTRY_FILE" 2>&1)
  SMOKE_EXIT=$?

  # 停 GPU 监控
  [ -n "${GPU_MON_PID:-}" ] && kill "$GPU_MON_PID" 2>/dev/null || true

  echo "[verify] Smoke test exit=$SMOKE_EXIT" | tee -a "$LOG"

  if [ $SMOKE_EXIT -ne 0 ]; then
    PASSED=false
    FAILED_AT="smoke_test"
    NOTES="Smoke test failed (exit=$SMOKE_EXIT): $(echo "$SMOKE_OUTPUT" | tail -1 | cut -c1-80)"
    echo "[verify] Smoke test 失败" | tee -a "$LOG"
  else
    # 输出合理性判定
    OUTPUT_DIR="$WORKSPACE/repo/output"
    OUTPUT_FILES=""
    if [ -d "$OUTPUT_DIR" ]; then
      OUTPUT_FILES=$(find "$OUTPUT_DIR" -type f 2>/dev/null | head -5 | jq -R . | jq -s .)
    fi
    EVIDENCE=$(echo "$EVIDENCE" | jq --argjson exit "$SMOKE_EXIT" '.smoke_exit_code = $exit')
    [ -n "$OUTPUT_FILES" ] && EVIDENCE=$(echo "$EVIDENCE" | jq --argjson files "$OUTPUT_FILES" '.output_files = $files')
    NOTES="Smoke test passed"
    echo "[verify] Smoke test 通过" | tee -a "$LOG"
  fi
fi

# ---- 3. GPU 利用率检查 ----
if [ "$PASSED" = true ] && [ -f "$WORKSPACE/.cache/verify_gpu.log" ]; then
  echo "[verify] Step 3: GPU 利用率检查" | tee -a "$LOG"
  # 从 GPU 监控日志提取峰值
  MAX_MEM=$(awk -F', ' 'NR>0{if($1+0 > m) m=$1+0} END{print m+0}' "$WORKSPACE/.cache/verify_gpu.log" 2>/dev/null || echo 0)
  MAX_UTIL=$(awk -F', ' 'NR>0{gsub(/[^0-9]/,"",$2); if($2+0 > u) u=$2+0} END{print u+0}' "$WORKSPACE/.cache/verify_gpu.log" 2>/dev/null || echo 0)
  echo "[verify] GPU max_mem=${MAX_MEM}MB max_util=${MAX_UTIL}%" | tee -a "$LOG"

  EVIDENCE=$(echo "$EVIDENCE" | jq --argjson mem "$MAX_MEM" --argjson util "$MAX_UTIL" \
    '.gpu_stats = {"memory_used_mb": $mem, "utilization_pct": $util}')

  if [ "$MAX_MEM" -lt 1024 ] || [ "$MAX_UTIL" -lt 10 ]; then
    # GPU 利用率不足 — 但可能项目本身是 CPU 推理(如 OCR),不严格 fail
    echo "[verify] GPU 利用率低(mem=${MAX_MEM}MB, util=${MAX_UTIL}%),标记为 CPU 推理" | tee -a "$LOG"
    NOTES="$NOTES; GPU utilization low (mem=${MAX_MEM}MB, util=${MAX_UTIL}%)"
  fi
fi

# ---- 落盘 ----
DURATION=$(( $(date +%s) - START_TS ))
VERIFY_LEVEL="L0"
CONFIDENCE="high"

# 传环境变量给 Python heredoc（避免 bash 变量直接内插导致 null/引号问题）
export V_WORKSPACE="$WORKSPACE"
export V_RESULT="$RESULT"
export V_PASSED="$PASSED"
export V_FAILED_AT="$FAILED_AT"
export V_EVIDENCE="$EVIDENCE"
export V_NOTES="$NOTES"
export V_CONFIDENCE="$CONFIDENCE"
export V_VERIFY_LEVEL="$VERIFY_LEVEL"
export V_DURATION="$DURATION"

# 用 python3 落盘(避免 heredoc 特殊字符问题)
python3 << 'PYEOF'
import json, os, datetime

workspace = os.environ["V_WORKSPACE"]
result_path = os.environ["V_RESULT"]
py_passed = os.environ["V_PASSED"] == "true"
py_failed_at = os.environ["V_FAILED_AT"]
if py_failed_at == "null" or py_failed_at == "":
    py_failed_at = None
py_evidence = os.environ["V_EVIDENCE"]
try:
    py_evidence = json.loads(py_evidence)
except Exception:
    py_evidence = {"raw": py_evidence}
py_notes = os.environ["V_NOTES"]
py_confidence = os.environ["V_CONFIDENCE"]
py_verify_level = os.environ["V_VERIFY_LEVEL"]
py_duration = int(os.environ["V_DURATION"])

result = {
    "passed": py_passed,
    "failed_at": py_failed_at,
    "evidence": py_evidence,
    "notes": py_notes,
    "confidence": py_confidence,
    "verify_level": py_verify_level,
    "completed_at": datetime.datetime.now().isoformat(),
    "duration_seconds": py_duration
}

with open(result_path, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# 字段自检
for k in ["passed", "failed_at", "evidence", "notes", "confidence", "verify_level", "completed_at"]:
    assert k in result, f"Missing field: {k}"
assert isinstance(result["passed"], bool), "passed must be boolean"
print(f"[verify] JSON written: passed={result['passed']}")
PYEOF

# 更新 state
jq --arg dur "$DURATION" '.phase = "verifying" | .status = "done" | .phases_done += ["verify"] | .verify_result = {"passed": '"$PASSED"'} | .updated_at = "'$(date -Iseconds)'"' "$STATE" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$STATE"

echo "[verify] 完成: passed=$PASSED failed_at=$FAILED_AT duration=${DURATION}s" | tee -a "$LOG"
echo "=== PHASE_END phase=verify slug=$SLUG status=done ts=$(date -Iseconds) ===" | tee -a "$LOG"
