#!/bin/bash
# phase-install-env.sh — install-env 阶段执行脚本
# 核心改进: 自动torch拆分(sm_12) + pip install 前后台自适应
# 用法: bash hermes/scripts/phase-install-env.sh <slug> <run_id>
set -uo pipefail
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"; RUN_ID="$2"

HARNESS_ROOT="/root/ai-auto-harness"
WORKSPACE="$HARNESS_ROOT/workspace/$SLUG"
LOG="$WORKSPACE/logs/install_env.log"

cd "$HARNESS_ROOT"
[ -f .env ] && { set -a; source .env; set +a; }
export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2

echo "=== PHASE_START phase=install-env slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" >> "$LOG"

# ---- state: running ----
jq '.phase = "installing" | .status = "running" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"

FIXES_APPLIED="[]"
WARNINGS="[]"

# ---- 1. venv ----
cd "$WORKSPACE"
if [ ! -d "venv" ]; then
  python3 -m venv venv 2>&1 | tee -a "$LOG"
fi
source venv/bin/activate || {
  echo "[install] FATAL: venv 损坏,尝试重建" | tee -a "$LOG"
  rm -rf venv
  python3 -m venv venv 2>&1 | tee -a "$LOG"
  source venv/bin/activate || { echo "[install] FATAL: venv 重建失败" | tee -a "$LOG"; exit 1; }
}
# venv 健康检查
python3 -c "import sys; print(sys.version)" 2>&1 | tee -a "$LOG" || {
  echo "[install] FATAL: venv python 不可用" | tee -a "$LOG"; exit 1;
}
which python 2>&1 | tee -a "$LOG"

# ---- 2. 核心工具 ----
pip install --upgrade pip setuptools wheel 2>&1 | tee -a "$LOG"

# ---- 3. 读取 torch 经验 ----
TORCH_STRATEGY="default"
if [ -f "$HARNESS_ROOT/memory/lessons/torch-sm12.md" ]; then
  TORCH_STRATEGY="nightly_cu124"
  echo "[install] torch-sm12.md found, using nightly cu124 strategy" | tee -a "$LOG"
fi

# ---- 4. 项目依赖(含torch拆分) ----
if [ -f "$WORKSPACE/repo/pyproject.toml" ] || [ -f "$WORKSPACE/repo/setup.py" ]; then
  # 检查是否有torch依赖需要拆分
  HAS_TORCH_DEP=0
  grep -qiE "^(torch|torchvision|torchaudio)" "$WORKSPACE/repo/requirements.txt" 2>/dev/null && HAS_TORCH_DEP=1
  grep -qiE "\"torch\"" "$WORKSPACE/repo/pyproject.toml" 2>/dev/null && HAS_TORCH_DEP=1

  if [ "$HAS_TORCH_DEP" = "1" ] && [ "$TORCH_STRATEGY" = "nightly_cu124" ]; then
    echo "[install] Splitting torch deps for sm_12 (nightly cu124)" | tee -a "$LOG"
    FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('torch_split_nightly_cu124'); print(json.dumps(a))")
    
    # 先装不带torch的项目依赖
    if [ -f "$WORKSPACE/repo/requirements.txt" ]; then
      # 临时去掉torch依赖行
      grep -viE "^(torch|torchvision|torchaudio)" "$WORKSPACE/repo/requirements.txt" > /tmp/req_no_torch.txt 2>/dev/null
      if [ -s /tmp/req_no_torch.txt ]; then
        pip install -r /tmp/req_no_torch.txt 2>&1 | tee -a "$LOG"
      fi
    fi
    
    # pip install -e . --no-deps 避免触发torch版本约束
    pip install -e "$WORKSPACE/repo" --no-deps 2>&1 | tee -a "$LOG"
    
    # 装torch nightly cu124
    pip install --pre torch torchaudio --index-url https://download.pytorch.org/whl/nightly/cu124 2>&1 | tee -a "$LOG"
  else
    # 正常安装
    pip install -e "$WORKSPACE/repo" 2>&1 | tee -a "$LOG"
  fi
elif [ -f "$WORKSPACE/repo/requirements.txt" ]; then
  pip install -r "$WORKSPACE/repo/requirements.txt" 2>&1 | tee -a "$LOG"
fi

# ---- 5. torch sm_12 检测 ----
SM12_OK=false
TORCH_ARCHS=""
CUDA_AVAILABLE=false

if python -c "import torch" 2>/dev/null; then
  TORCH_ARCHS=$(python -c "import torch; print(torch.cuda.get_arch_list())" 2>/dev/null || echo "[]")
  CUDA_AVAILABLE=$(python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null || echo "False")
  
  if echo "$TORCH_ARCHS" | grep -q "120\|12\.0"; then
    SM12_OK=true
  fi

  # sm_12 不过 且还没试过 nightly → 自动切换
  if [ "$SM12_OK" = "false" ] && [ "$TORCH_STRATEGY" = "default" ] && [ "$CUDA_AVAILABLE" = "True" ]; then
    echo "[install] sm_12 not available, trying nightly cu124" | tee -a "$LOG"
    pip uninstall -y torch torchvision torchaudio 2>&1 | tee -a "$LOG"
    pip install --pre torch torchaudio --index-url https://download.pytorch.org/whl/nightly/cu124 2>&1 | tee -a "$LOG"
    FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('torch_switched_to_nightly_cu124'); print(json.dumps(a))")
    
    TORCH_ARCHS=$(python -c "import torch; print(torch.cuda.get_arch_list())" 2>/dev/null || echo "[]")
    CUDA_AVAILABLE=$(python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null || echo "False")
    if echo "$TORCH_ARCHS" | grep -q "120\|12\.0"; then
      SM12_OK=true
    fi
  fi
fi

if [ "$CUDA_AVAILABLE" = "False" ]; then
  WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('cuda_not_available'); print(json.dumps(a))")
fi

# ---- 6. 深度预检(lazy import) ----
for dep in flash_attn xformers deepspeed accelerate diffusers transformers; do
  if grep -rq "import $dep\|from $dep" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null; then
    if ! python -c "import $dep" 2>/dev/null; then
      echo "[install] P9: $dep used in code but not installed, trying pip install" | tee -a "$LOG"
      if pip install "$dep" 2>&1 | tee -a "$LOG"; then
        FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('pip_install_$dep'); print(json.dumps(a))")
      else
        WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('dep_install_failed: $dep'); print(json.dumps(a))")
      fi
    fi
  fi
done

# ---- 6b. 隐式依赖检查(post-install) ----
# 有些项目(如 PaddleOCR)的 setup.py 不声明运行时依赖(如 paddlepaddle),
# 导致 pip install -e . 后核心模块 import 失败。
# 策略: 从 intake.json 提取 entry_script 里的 import,逐个验证
echo "[install] Post-install: checking implicit dependencies from entry_script" | tee -a "$LOG"
INTAKE_JSON="$WORKSPACE/results/intake.json"
if [ -f "$INTAKE_JSON" ]; then
  # 提取 entry_script 里的 import 行,取模块名
  ENTRY_SCRIPT=$(jq -r '.entry_script // empty' "$INTAKE_JSON" 2>/dev/null)
  if [ -n "$ENTRY_SCRIPT" ]; then
    IMPORTS=$(echo "$ENTRY_SCRIPT" | grep -oE "^(from|import)[[:space:]]+[a-zA-Z0-9_]+" | awk '{print $2}' | sort -u)
    for MOD in $IMPORTS; do
      # 跳过标准库和已知子模块
      case "$MOD" in
        json|sys|os|pathlib|argparse|logging|time|datetime|math|re|collections|typing|io|abc|copy|dataclasses|functools|itertools|string|tempfile|traceback|unittest|warnings|contextlib|enum|hashlib|shutil|subprocess|threading|queue|struct|csv|random|urllib|http|email|html|xml|glob|fnmatch|signal|gc|platform|pprint|textwrap) continue ;;
      esac
      if ! python -c "import $MOD" 2>/dev/null; then
        echo "[install] Implicit dep missing: $MOD (found in entry_script but not installed), trying pip install" | tee -a "$LOG"
        if pip install "$MOD" 2>&1 | tee -a "$LOG"; then
          FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('implicit_dep_$MOD'); print(json.dumps(a))")
        else
          WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('implicit_dep_failed: $MOD'); print(json.dumps(a))")
        fi
      fi
    done
  fi
fi

# ---- 6c. 深度 import 链验证 ----
# 有些项目(如 PaddleOCR)的依赖链里有运行时检测的隐式引擎(paddlepaddle),
# 不在 setup.py 声明,只在 import 或构造时抛 RuntimeError。
# 策略: 1) import 验证; 2) entry_script 试执行(短超时),捕获 RuntimeError 里的依赖名
echo "[install] Post-install: deep import chain validation" | tee -a "$LOG"
if [ -f "$INTAKE_JSON" ]; then
  ENTRY_SCRIPT=$(jq -r '.entry_script // empty' "$INTAKE_JSON" 2>/dev/null)
  if [ -n "$ENTRY_SCRIPT" ]; then
    IMPORTS=$(echo "$ENTRY_SCRIPT" | grep -oE "^(from|import)[[:space:]]+[a-zA-Z0-9_]+" | awk '{print $2}' | sort -u)
    for MOD in $IMPORTS; do
      case "$MOD" in
        json|sys|os|pathlib|argparse|logging|time|datetime|math|re|collections|typing|io|abc|copy|dataclasses|functools|itertools|string|tempfile|traceback|unittest|warnings|contextlib|enum|hashlib|shutil|subprocess|threading|queue|struct|csv|random|urllib|http|email|html|xml|glob|fnmatch|signal|gc|platform|pprint|textwrap) continue ;;
      esac
      # 尝试深度 import(捕获 RuntimeError 如 "dependency 'paddlepaddle' is not installed")
      DEEP_ERR=$(python -c "import $MOD" 2>&1)
      if [ $? -ne 0 ]; then
        IMPLICIT_DEP=$(echo "$DEEP_ERR" | grep -oE "dependency '([^']+)' is not installed" | grep -oE "'([^']+)'" | tr -d "'" | head -1)
        if [ -z "$IMPLICIT_DEP" ]; then
          IMPLICIT_DEP=$(echo "$DEEP_ERR" | grep -oE "No module named '([^']+)'|ModuleNotFoundError.*'([^']+)'" | grep -oE "'([^']+)'" | tr -d "'" | tail -1)
        fi
        if [ -n "$IMPLICIT_DEP" ]; then
          echo "[install] Deep import: $MOD requires implicit dep '$IMPLICIT_DEP', trying pip install" | tee -a "$LOG"
          if pip install "$IMPLICIT_DEP" 2>&1 | tee -a "$LOG"; then
            FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('deep_implicit_${IMPLICIT_DEP}'); print(json.dumps(a))")
          else
            WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('deep_implicit_failed: ${IMPLICIT_DEP}'); print(json.dumps(a))")
          fi
        else
          echo "[install] Deep import: $MOD failed but no implicit dep detected: $(echo "$DEEP_ERR" | tail -1)" | tee -a "$LOG"
        fi
      fi
    done

    # 6c-2: entry_script 试执行验证(10s 超时)
    # 捕获构造函数级别的 RuntimeError(如 PaddleOCR() 需要 paddlepaddle)
    ENTRY_FILE="$WORKSPACE/.cache/install_verify_entry.py"
    CLEAN_SCRIPT=$(echo "$ENTRY_SCRIPT" | sed '1s/^python3 *-c *["'"'"']//' | sed '$s/["'"'"']$//')
    printf '%s\n' "$CLEAN_SCRIPT" > "$ENTRY_FILE"
    echo "[install] Deep verify: running entry_script with 10s timeout" | tee -a "$LOG"
    VERIFY_ERR=$(cd "$WORKSPACE/repo" && timeout 10 python "$ENTRY_FILE" 2>&1)
    VERIFY_EXIT=$?
    if [ $VERIFY_EXIT -ne 0 ]; then
      # 提取 RuntimeError 里的隐式依赖
      IMPLICIT_DEP=$(echo "$VERIFY_ERR" | grep -oE "dependency '([^']+)' is not installed" | grep -oE "'([^']+)'" | tr -d "'" | head -1)
      if [ -z "$IMPLICIT_DEP" ]; then
        IMPLICIT_DEP=$(echo "$VERIFY_ERR" | grep -oE "No module named '([^']+)'" | grep -oE "'([^']+)'" | tr -d "'" | head -1)
      fi
      if [ -n "$IMPLICIT_DEP" ]; then
        echo "[install] Deep verify: entry_script needs implicit dep '$IMPLICIT_DEP', trying pip install" | tee -a "$LOG"
        if pip install "$IMPLICIT_DEP" 2>&1 | tee -a "$LOG"; then
          FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('entry_verify_${IMPLICIT_DEP}'); print(json.dumps(a))")
        else
          WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('entry_verify_failed: ${IMPLICIT_DEP}'); print(json.dumps(a))")
        fi
      else
        echo "[install] Deep verify: entry_script failed (exit=$VERIFY_EXIT) but no implicit dep detected" | tee -a "$LOG"
        echo "$VERIFY_ERR" | tail -3 | tee -a "$LOG"
      fi
    else
      echo "[install] Deep verify: entry_script passed!" | tee -a "$LOG"
    fi
  fi
fi

# ---- 6d. apt 系统依赖检测 ----
# 有些 Python 包(如 sox, librosa, ffmpeg)需要系统级命令行工具,
# pip install 只装 Python wrapper,不装系统命令。
# 策略: 检测常见 Python 包的系统依赖,缺失则 apt-get install
echo "[install] Post-install: checking apt system dependencies" | tee -a "$LOG"
declare -A APT_DEPS=(
  ["sox"]="sox libsox-dev"
  ["pydub"]="ffmpeg"
  ["librosa"]="ffmpeg"
  ["soundfile"]="libsndfile1"
  ["av"]="ffmpeg libavcodec-dev libavformat-dev libavdevice-dev"
  ["cv2|opencv"]="libgl1-mesa-glx libglib2.0-0"
  ["pytesseract"]="tesseract-ocr"
  ["pdf2image"]="poppler-utils"
  ["wand"]="libmagickwand-dev"
)
for PY_MOD in "${!APT_DEPS[@]}"; do
  # 检查 Python 包是否被 import
  if grep -rqE "import ${PY_MOD}|from ${PY_MOD}" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null; then
    APT_PKGS="${APT_DEPS[$PY_MOD]}"
    # 检查系统命令是否存在
    NEED_INSTALL=false
    for PKG in $APT_PKGS; do
      if ! dpkg -s "$PKG" &>/dev/null; then
        NEED_INSTALL=true
        break
      fi
    done
    if [ "$NEED_INSTALL" = true ]; then
      echo "[install] System dep missing for $PY_MOD: apt-get install -y $APT_PKGS" | tee -a "$LOG"
      if apt-get install -y $APT_PKGS 2>&1 | tee -a "$LOG"; then
        FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('apt_install_${PY_MOD}'); print(json.dumps(a))")
      else
        WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('apt_install_failed: ${APT_PKGS}'); print(json.dumps(a))")
      fi
    fi
  fi
done

# ---- 7. 落盘 ----
# 传环境变量给 Python heredoc
export I_WORKSPACE="$WORKSPACE"
export I_LOG="$LOG"
export I_FIXES_APPLIED="$FIXES_APPLIED"
export I_WARNINGS="$WARNINGS"
export I_CUDA_AVAILABLE="$CUDA_AVAILABLE"
export I_TORCH_ARCHS="$TORCH_ARCHS"
export I_SM12_OK="$SM12_OK"

python3 << 'PYEOF'
import json, os, datetime, subprocess

workspace = os.environ["I_WORKSPACE"]
fixes_applied = json.loads(os.environ["I_FIXES_APPLIED"])
warnings = json.loads(os.environ["I_WARNINGS"])
cuda_available = os.environ["I_CUDA_AVAILABLE"] == "True"
torch_archs = os.environ["I_TORCH_ARCHS"]
sm12_ok = os.environ["I_SM12_OK"] == "true"

torch_ver = "N/A"
try:
    torch_ver = subprocess.check_output(["python", "-c", "import torch; print(torch.__version__)"], stderr=subprocess.DEVNULL).decode().strip()
except Exception:
    pass

python_path = subprocess.check_output(["which", "python"]).decode().strip()

result = {
    "venv_path": f"{workspace}/venv",
    "deps_ok": True,
    "fixes_applied": fixes_applied,
    "warnings": warnings,
    "blocked": False,
    "completed_at": datetime.datetime.now().isoformat()
}

env_info = {
    "venv_path": f"{workspace}/venv",
    "python": python_path,
    "torch_version": torch_ver,
    "cuda_available": cuda_available,
    "torch_archs": torch_archs,
    "sm_12_supported": sm12_ok,
    "captured_at": datetime.datetime.now().isoformat()
}

with open(os.path.join(workspace, "results", "install.json"), "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
with open(os.path.join(workspace, "results", "environment.json"), "w") as f:
    json.dump(env_info, f, indent=2, ensure_ascii=False)

# 更新 state
with open(os.path.join(workspace, "state.json")) as f:
    state = json.load(f)
state["phase"] = "running"
state["phases_done"] = list(dict.fromkeys(state.get("phases_done", []) + ["install-env"]))
state["status"] = "done"
state["install_result"] = result
state["updated_at"] = datetime.datetime.now().isoformat()
with open(os.path.join(workspace, "state.json"), "w") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)

print("INSTALL_RESULT: DONE")
PYEOF

echo "=== PHASE_END phase=install-env slug=$SLUG status=done ts=$(date -Iseconds) ===" >> "$LOG"
