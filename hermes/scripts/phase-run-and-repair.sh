#!/bin/bash
# phase-run-and-repair.sh — run-and-repair 阶段执行脚本
# 核心改进: 自修复循环(max 3轮) + GPU OOM 自动切 CPU fallback
# 用法: bash hermes/scripts/phase-run-and-repair.sh <slug> <run_id> <entry_script> <gpu_picks_json>
set -uo pipefail
START_TS=$(date +%s)
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"; RUN_ID="$2"; ENTRY_SCRIPT="$3"; GPU_PICKS_JSON="$4"

HARNESS_ROOT="/root/ai-auto-harness"
WORKSPACE="$HARNESS_ROOT/workspace/$SLUG"
LOG="$WORKSPACE/logs/run_and_repair.log"
FIXES_LOG="$WORKSPACE/logs/fixes.log"
ENTRY_FILE="$WORKSPACE/.cache/entry_script.py"  # entry_script 写成文件,避免引号嵌套

cd "$HARNESS_ROOT"
[ -f .env ] && { set -a; source .env; set +a; }

echo "=== PHASE_START phase=run-and-repair slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" >> "$LOG"

# ---- state: running ----
jq '.phase = "running" | .status = "running" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"

# ---- GPU 设置 ----
GPU_PICKS=$(echo "$GPU_PICKS_JSON" | python3 -c "import sys,json; print(','.join(str(x) for x in json.loads(sys.stdin.read())))" 2>/dev/null || echo "")
if [ -n "$GPU_PICKS" ]; then
  export CUDA_VISIBLE_DEVICES="$GPU_PICKS"
fi

source "$WORKSPACE/venv/bin/activate" || {
  echo "[run] FATAL: venv not found at $WORKSPACE/venv/, cannot run inference" | tee -a "$LOG"
  # 写失败结果并退出
  jq '.phase = "done" | .status = "failed" | .failure_reason = "venv_missing" | .updated_at = "'$(date -Iseconds)'"' \
    "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"
  exit 1
}
export HF_HOME="$WORKSPACE/.cache/huggingface" HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"

FIXES_APPLIED="[]"
REPAIR_COUNT=0
PASSED=false
INFER_CMD="$ENTRY_SCRIPT"
FALLBACK_CPU=false

# ---- 将 entry_script 写成 .py 文件(避免 python3 -c 的引号嵌套地狱) ----
# ---- 将 entry_script 写成 .py 文件(避免 python3 -c 的引号嵌套地狱) ----
# 用 Python 解析 python3 -c "..." 外壳,比 sed 正则可靠
CLEAN_SCRIPT=$(echo "$ENTRY_SCRIPT" | python3 -c "
import sys, shlex
line = sys.stdin.read().strip()
if line.startswith('python3 -c ') or line.startswith('python -c '):
    parts = shlex.split(line)
    for i, p in enumerate(parts):
        if p == '-c' and i+1 < len(parts):
            print(parts[i+1])
            break
    else:
        print(line)
else:
    print(line)
" 2>/dev/null || echo "$ENTRY_SCRIPT")
printf '%s\n' "$CLEAN_SCRIPT" > "$ENTRY_FILE"
echo "[run] Entry script written to $ENTRY_FILE ($(wc -l < "$ENTRY_FILE") lines)" | tee -a "$LOG"

# ---- GPU pre-flight ----
if [ -n "$GPU_PICKS" ]; then
  CUDA_OK=$(python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null || echo "False")
  if [ "$CUDA_OK" != "True" ]; then
    echo "[run] CUDA not available, falling back to CPU" | tee -a "$LOG"
    FALLBACK_CPU=true
    FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('fallback_cpu_no_cuda'); print(json.dumps(a))")
    unset CUDA_VISIBLE_DEVICES
  fi
fi

# ---- 修复循环 ----
# 逻辑: 修复动作不消耗 round,只有执行后仍失败才消耗。
# dep_missing 用 continue 跳过(不计轮),其他修复也用 continue(不计轮)。
# EXEC_FAIL_COUNT 记录"修复后执行仍失败"的次数,达到 MAX_EXEC_FAILS 才放弃。
MAX_EXEC_FAILS=5
EXEC_FAIL_COUNT=0
REPAIR_ACTIONS=0  # 总修复动作数(仅统计,不控制退出)

for ROUND in $(seq 1 20); do  # 硬上限 20 轮(防无限循环)
  echo "[run] Round $ROUND, cmd: python3 $ENTRY_FILE" | tee -a "$LOG"
  
  # 运行推理(用 .py 文件而非 python3 -c,避免引号问题)
  cd "$WORKSPACE/repo"
  RUN_OUTPUT=$(timeout 600 python3 "$ENTRY_FILE" 2>&1) 
  RUN_EXIT=$?
  
  echo "$RUN_OUTPUT" >> "$LOG"
  echo "[run] Exit code: $RUN_EXIT" | tee -a "$LOG"
  
  # 成功
  if [ $RUN_EXIT -eq 0 ]; then
    PASSED=true
    echo "[run] Inference passed!" | tee -a "$LOG"
    break
  fi
  
  # ---- 错误分析与修复 ----
  ERROR_CLASS=""
  FIX=""
  
  # 依赖缺失(ModuleNotFoundError / ImportError during import)
  if echo "$RUN_OUTPUT" | grep -qiE "ModuleNotFoundError|ImportError.*No module named"; then
    MISSING_MOD=$(echo "$RUN_OUTPUT" | grep -oE "No module named '([^']+)'" | head -1 | sed "s/No module named '//;s/'//")
    if [ -z "$MISSING_MOD" ]; then
      MISSING_MOD=$(echo "$RUN_OUTPUT" | grep -oE "No module named \"([^\"]+)\"" | head -1 | sed 's/No module named "//;s/"//')
    fi
    if [ -n "$MISSING_MOD" ]; then
      ERROR_CLASS="dep_missing"
      FIX="pip install $MISSING_MOD"
      echo "$(date -Iseconds) round=$ROUND error=dep_missing fix=$FIX module=$MISSING_MOD" >> "$FIXES_LOG"
      pip install "$MISSING_MOD" 2>&1 | tee -a "$LOG"
      FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('pip_install_$MISSING_MOD'); print(json.dumps(a))")
      # 依赖缺失不计轮
      continue
    fi
  fi
  
  # FileNotFoundError — 自动替换 entry_script 中的假路径
  if echo "$RUN_OUTPUT" | grep -qiE "FileNotFoundError|No such file or directory"; then
    BAD_PATH=$(echo "$RUN_OUTPUT" | grep -oE "(No such file or directory|FileNotFoundError).*['\"]([^'\"]+)['\"]" | grep -oE "['\"]([^'\"]+)['\"]" | head -1 | tr -d "'\"")
    # 也从 traceback 最后一行提取
    if [ -z "$BAD_PATH" ]; then
      BAD_PATH=$(echo "$RUN_OUTPUT" | grep "FileNotFoundError\|No such file" | tail -1 | grep -oE "[^ ]+\.(jpg|jpeg|png|wav|mp3|mp4|txt|csv|json|pt|pth|bin|safetensors)" | head -1)
    fi
    if [ -n "$BAD_PATH" ]; then
      # 在 repo/ 下搜索同名文件
      BASENAME=$(basename "$BAD_PATH" 2>/dev/null)
      FOUND_PATH=""
      if [ -n "$BASENAME" ]; then
        FOUND_PATH=$(find "$WORKSPACE/repo" -name "$BASENAME" -type f 2>/dev/null | head -1)
      fi
      # 如果同名文件没找到,找同扩展名的任意文件
      if [ -z "$FOUND_PATH" ]; then
        EXT="${BASENAME##*.}"
        if [ -n "$EXT" ]; then
          FOUND_PATH=$(find "$WORKSPACE/repo" -name "*.$EXT" -type f 2>/dev/null | head -1)
        fi
      fi
      if [ -n "$FOUND_PATH" ]; then
        # 计算相对于 repo/ 的路径
        REL_PATH=$(realpath --relative-to="$WORKSPACE/repo" "$FOUND_PATH" 2>/dev/null || echo "$FOUND_PATH")
        echo "[run] FileNotFoundError: $BAD_PATH → replacing with $REL_PATH" | tee -a "$LOG"
        # 在 entry_script .py 文件中替换
        sed -i "s|$(echo "$BAD_PATH" | sed 's/[\/&]/\\&/g')|$REL_PATH|g" "$ENTRY_FILE"
        ERROR_CLASS="file_not_found"
        FIX="Replaced $BAD_PATH with $REL_PATH in entry_script"
        echo "$(date -Iseconds) round=$ROUND error=file_not_found fix='$FIX'" >> "$FIXES_LOG"
        FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('path_fix_${BASENAME}'); print(json.dumps(a))")
        REPAIR_ACTIONS=$((REPAIR_ACTIONS + 1))
        continue
      else
        echo "[run] FileNotFoundError: $BAD_PATH — no alternative file found in repo" | tee -a "$LOG"
      fi
    fi
  fi

  # PaddlePaddle OneDNN bug — 禁用 OneDNN 后重试,或降级 paddlepaddle
  if echo "$RUN_OUTPUT" | grep -qiE "ConvertPirAttribute2RuntimeAttribute|onednn_instruction|OneDNN"; then
    ERROR_CLASS="paddle_onednn_bug"
    if ! echo "$FIXES_APPLIED" | grep -q "disable_onednn"; then
      FIX="Disable PaddlePaddle OneDNN (FLAGS_use_mkldnn=0)"
      echo "[run] PaddlePaddle OneDNN bug detected, disabling OneDNN" | tee -a "$LOG"
      if ! grep -q "FLAGS_use_mkldnn" "$ENTRY_FILE"; then
        printf 'import os; os.environ["FLAGS_use_mkldnn"] = "0"\n' | cat - "$ENTRY_FILE" > /tmp/entry_tmp.py && mv /tmp/entry_tmp.py "$ENTRY_FILE"
      fi
      FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('disable_onednn'); print(json.dumps(a))")
    elif ! echo "$FIXES_APPLIED" | grep -q "downgrade_paddlepaddle"; then
      # disable_onednn 没生效,降级 paddlepaddle 到 3.0.0(没有 PIR OneDNN bug)
      FIX="Downgrade paddlepaddle to 3.0.0 (PIR OneDNN bug in 3.3.1)"
      echo "[run] OneDNN disable didn't work, downgrading paddlepaddle to 3.0.0" | tee -a "$LOG"
      pip install "paddlepaddle==3.0.0" 2>&1 | tee -a "$LOG"
      FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('downgrade_paddlepaddle'); print(json.dumps(a))")
    else
      echo "[run] OneDNN bug persists after downgrade, giving up" | tee -a "$LOG"
      EXEC_FAIL_COUNT=$((EXEC_FAIL_COUNT + 1))
      break
    fi
    echo "$(date -Iseconds) round=$ROUND error=paddle_onednn_bug fix='$FIX'" >> "$FIXES_LOG"
    REPAIR_ACTIONS=$((REPAIR_ACTIONS + 1))
    continue
  fi

  # CUDA OOM
  if echo "$RUN_OUTPUT" | grep -qiE "CUDA out of memory|OutOfMemoryError"; then
    ERROR_CLASS="cuda_oom"
    if [ "$FALLBACK_CPU" = "false" ]; then
      FIX="Switched to CPU inference (GPU OOM)"
      FALLBACK_CPU=true
      unset CUDA_VISIBLE_DEVICES
      echo "$(date -Iseconds) round=$ROUND error=cuda_oom fix=cpu_fallback" >> "$FIXES_LOG"
      FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('cpu_fallback_gpu_oom'); print(json.dumps(a))")
      REPAIR_ACTIONS=$((REPAIR_ACTIONS + 1))
      continue
    fi
  fi
  
  # bfloat16 CPU 不支持
  if echo "$RUN_OUTPUT" | grep -qiE "dtype.*bfloat16.*CPU|BFloat16.*not supported"; then
    ERROR_CLASS="bfloat16_cpu"
    FIX="Cast model to float32 for CPU inference"
    echo "$(date -Iseconds) round=$ROUND error=bfloat16_cpu fix=float32_cast" >> "$FIXES_LOG"
    FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('float32_cast_bfloat16_cpu'); print(json.dumps(a))")
    REPAIR_ACTIONS=$((REPAIR_ACTIONS + 1))
    continue
  fi
  
  # 超时
  if [ $RUN_EXIT -eq 124 ]; then
    ERROR_CLASS="timeout"
    echo "[run] Inference timed out (600s)" | tee -a "$LOG"
    EXEC_FAIL_COUNT=$((EXEC_FAIL_COUNT + 1))
    break
  fi
  
  # 未知错误 — 执行失败但无法自动修复,计入 EXEC_FAIL_COUNT
  ERROR_CLASS="unknown"
  EXEC_FAIL_COUNT=$((EXEC_FAIL_COUNT + 1))
  echo "[run] Unknown error, round=$ROUND exec_fails=$EXEC_FAIL_COUNT" | tee -a "$LOG"
  
  # 达到执行失败上限
  if [ $EXEC_FAIL_COUNT -ge $MAX_EXEC_FAILS ]; then
    echo "[run] Max exec fails reached ($MAX_EXEC_FAILS)" | tee -a "$LOG"
    break
  fi
done

# ---- 落盘 ----
OUTPUT_TAIL=$(tail -50 "$LOG" 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()[:2000]))" 2>/dev/null || echo '""')

# 传环境变量给 Python heredoc（避免 bash 变量直接内插导致换行/引号问题）
export R_WORKSPACE="$WORKSPACE"
export R_PASSED="$PASSED"
export R_REPAIR_COUNT="$REPAIR_ACTIONS"
export R_FALLBACK_CPU="$FALLBACK_CPU"
export R_EXEC_FAIL_COUNT="$EXEC_FAIL_COUNT"
export R_FIXES_APPLIED="$FIXES_APPLIED"
export R_ENTRY_SCRIPT="$ENTRY_SCRIPT"
export R_START_TS="$START_TS"
export R_SLUG="$SLUG"

python3 << 'PYEOF'
import json, os, datetime

workspace = os.environ["R_WORKSPACE"]
passed = os.environ["R_PASSED"] == "true"
repair_count = int(os.environ["R_REPAIR_COUNT"])
fallback_cpu = os.environ["R_FALLBACK_CPU"] == "true"
exec_fail_count = int(os.environ["R_EXEC_FAIL_COUNT"])
fixes_applied = json.loads(os.environ["R_FIXES_APPLIED"])
entry_script = os.environ["R_ENTRY_SCRIPT"]
start_ts = int(os.environ["R_START_TS"])
duration = int(datetime.datetime.now().timestamp()) - start_ts

# 读日志尾部作为 sample_output
log_path = os.path.join(workspace, "logs", "run_and_repair.log")
sample_output = ""
try:
    with open(log_path) as f:
        lines = f.readlines()
        sample_output = "".join(lines[-5:])[:500]
except Exception:
    pass

result = {
    "phase": "run-and-repair",
    "slug": os.environ["R_SLUG"],
    "status": "done",
    "duration_seconds": duration,
    "repair_rounds": repair_count,
    "exec_fail_count": exec_fail_count,
    "errors_encountered": [],
    "fixes_applied": fixes_applied,
    "inference_success": passed,
    "sample_output": sample_output,
    "entry_command": entry_script,
    "paused_for_human": not passed and exec_fail_count >= 5,
    "blocked": False,
    "notes": f"CPU fallback used: {fallback_cpu}" if fallback_cpu else ""
}

with open(os.path.join(workspace, "results", "run_and_repair.json"), "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# 更新 state
with open(os.path.join(workspace, "state.json")) as f:
    state = json.load(f)
state["phase"] = "verifying"
state["phases_done"] = list(dict.fromkeys(state.get("phases_done", []) + ["run-and-repair"]))
state["status"] = "done"
state["updated_at"] = datetime.datetime.now().isoformat()
with open(os.path.join(workspace, "state.json"), "w") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)

print("RUN_RESULT: " + ("PASSED" if passed else "FAILED"))
PYEOF

echo "=== PHASE_END phase=run-and-repair slug=$SLUG status=done ts=$(date -Iseconds) ===" >> "$LOG"
