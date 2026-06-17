#!/bin/bash
# phase-intake.sh — intake 阶段执行脚本
# 子代理只需: bash hermes/scripts/phase-intake.sh <slug> <run_id> <github_url> <hf_repos> <estimated_params_b> <estimated_weight_size_gb> <gated_repos> <scenario_hits>
# 所有逻辑自包含,子代理不用读playbook
set -uo pipefail
START_TS=$(date +%s)
export AI_HARNESS_GUARD_SKIP=1  # 脚本自身不受guard拦截

SLUG="$1"; RUN_ID="$2"; GITHUB_URL="$3"; HF_REPOS="$4"; EST_PARAMS_B="$5"; EST_WEIGHT_GB="$6"; GATED_REPOS="$7"; SCENARIO_HITS="$8"

HARNESS_ROOT="/root/ai-auto-harness"
WORKSPACE="$HARNESS_ROOT/workspace/$SLUG"
LOG="$WORKSPACE/logs/intake.log"

# 恢复环境
cd "$HARNESS_ROOT"
[ -f .env ] && { set -a; source .env; set +a; }
export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2

# ---- 1. workspace 初始化 ----
mkdir -p "$WORKSPACE"/{.cache/huggingface,.cache/hf_hub,.cache/transformers,.cache/handoff,repo,logs,results,runs/$RUN_ID}
echo "==== intake start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=intake slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="

# ---- 2. 写初始 state.json ----
cat > "$WORKSPACE/state.json" <<STATEJSON
{
  "slug": "$SLUG",
  "github_url": "$GITHUB_URL",
  "hf_repos": $(echo "$HF_REPOS" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))"),
  "estimated_params_b": $EST_PARAMS_B,
  "estimated_weight_size_gb": $EST_WEIGHT_GB,
  "gated_repos": $(echo "$GATED_REPOS" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))"),
  "scenario_hits": $(echo "$SCENARIO_HITS" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))"),
  "phase": "intake",
  "status": "running",
  "phases_done": [],
  "started_at": "$(date -Iseconds)",
  "updated_at": "$(date -Iseconds)"
}
STATEJSON

# ---- 3. clone ----
cd "$WORKSPACE"
if [ -d "$WORKSPACE/repo/.git" ]; then
  echo "[intake] repo already exists, skipping clone" >> "$LOG"
else
  if ! git clone --depth=1 "$GITHUB_URL" repo >> "$LOG" 2>&1; then
    echo "FATAL: git clone failed" >> "$LOG"
    python3 -c "
import json
result = {'blocked': ['git_clone_failed'], 'warnings': [], 'ready_to_fetch': False, 'completed_at': '$(date -Iseconds)'}
with open('$WORKSPACE/results/intake.json', 'w') as f: json.dump(result, f, indent=2)
"
    jq '.status = "paused_for_human" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"
    echo "INTAKE_RESULT: BLOCKED git_clone_failed"
    exit 0
  fi
  # Fix5: git submodule 初始化
  echo "[intake] Initializing git submodules..." >> "$LOG"
  (cd "$WORKSPACE/repo" && git submodule update --init --recursive 2>&1 | head -20 >> "$LOG" || true)
fi

# ---- 4. 推断 entry_script + entry_type ----
ENTRY_SCRIPT=""
ENTRY_TYPE="script"  # script/gradio/service/docker
PYTHON_VERSION="3.10"
PYTHON_CONFIDENCE="high"

# 检查 pyproject.toml
if [ -f "$WORKSPACE/repo/pyproject.toml" ]; then
  PY_REQ=$(grep -A1 "requires-python" "$WORKSPACE/repo/pyproject.toml" 2>/dev/null | head -2)
  if echo "$PY_REQ" | grep -qE "3\.(9|10|11|12)"; then
    PYTHON_VERSION=$(echo "$PY_REQ" | grep -oE "3\.[0-9]+" | head -1)
    PYTHON_CONFIDENCE="high"
  fi
fi

# 辅助函数: 检测文件是否为 Gradio/Streamlit Web UI
is_gradio_file() {
  local f="$1"
  # 检查文件内容是否含 Gradio/Streamlit 标记
  grep -lE "import gradio|from gradio|gr\.Interface|gr\.Blocks|Gradio Demo|import streamlit|st\." "$f" 2>/dev/null | grep -q .
}

# 查找 entry script — 跳过 Gradio/Streamlit Web UI 文件
for candidate in "inference.py" "run_inference.py" "generate.py" "predict.py" "demo.py" "app.py" "run.py" "main.py"; do
  if find "$WORKSPACE/repo" -name "$candidate" -type f 2>/dev/null | head -1 | grep -q .; then
    CANDIDATE_PATH=$(find "$WORKSPACE/repo" -name "$candidate" -type f 2>/dev/null | head -1)
    if is_gradio_file "$CANDIDATE_PATH"; then
      echo "[intake] $candidate 是 Gradio/Streamlit Web UI,跳过" >> "$LOG"
      # 如果还没找到非 Gradio 入口,记录这个以备 fallback
      if [ -z "$ENTRY_SCRIPT" ]; then
        GRADIO_FALLBACK=$(echo "$CANDIDATE_PATH" | sed "s|$WORKSPACE/repo/||")
      fi
      continue
    fi
    ENTRY_SCRIPT=$(echo "$CANDIDATE_PATH" | sed "s|$WORKSPACE/repo/||")
    echo "[intake] entry_script=$ENTRY_SCRIPT (type=script)" >> "$LOG"
    break
  fi
done

# 如果所有候选都是 Gradio,使用 fallback 并标记 entry_type=gradio
if [ -z "$ENTRY_SCRIPT" ] && [ -n "$GRADIO_FALLBACK" ]; then
  ENTRY_SCRIPT="$GRADIO_FALLBACK"
  ENTRY_TYPE="gradio"
  echo "[intake] 所有候选都是 Gradio/Streamlit UI,使用 fallback=$ENTRY_SCRIPT (type=gradio)" >> "$LOG"
fi

# 检查 PyPI 包项目(没有 repo 入口,需手写推理脚本)
if [ -z "$ENTRY_SCRIPT" ] && [ -f "$WORKSPACE/repo/pyproject.toml" ]; then
  PKG_NAME=$(grep -m1 "^name" "$WORKSPACE/repo/pyproject.toml" 2>/dev/null | sed 's/.*=.*"\(.*\)".*/\1/' | head -1)
  if [ -n "$PKG_NAME" ]; then
    ENTRY_TYPE="pypi_package"
    echo "[intake] PyPI 包项目(pkg=$PKG_NAME),需手写推理脚本 (type=pypi_package)" >> "$LOG"
  fi
fi

# 检查 setup.py console_scripts
if [ -z "$ENTRY_SCRIPT" ] && [ -f "$WORKSPACE/repo/setup.py" ]; then
  CONSOLE=$(grep "console_scripts" "$WORKSPACE/repo/setup.py" 2>/dev/null | head -1)
  if [ -n "$CONSOLE" ]; then
    ENTRY_SCRIPT="console_script"
  fi
fi

# 检查 README quickstart
if [ -z "$ENTRY_SCRIPT" ] && [ -f "$WORKSPACE/repo/README.md" ]; then
  ENTRY_SCRIPT=$(grep -oE "python[3]? .+\.py" "$WORKSPACE/repo/README.md" 2>/dev/null | head -1 | sed 's/python[3]* //')
  # 检查 quickstart 找到的文件是否也是 Gradio
  if [ -n "$ENTRY_SCRIPT" ] && [ -f "$WORKSPACE/repo/$ENTRY_SCRIPT" ]; then
    if is_gradio_file "$WORKSPACE/repo/$ENTRY_SCRIPT"; then
      echo "[intake] README quickstart $ENTRY_SCRIPT 也是 Gradio,标记 type=gradio" >> "$LOG"
      ENTRY_TYPE="gradio"
    fi
  fi
fi

# ---- 4b. 扫描测试数据文件(供 entry_script 使用) ----
# 找 repo 里的图片/音频/文本等测试文件,避免硬编码假路径
TEST_DATA_FILE=""
for ext in jpg png jpeg wav mp3 txt csv; do
  TEST_DATA_FILE=$(find "$WORKSPACE/repo" -name "*.$ext" -type f ! -path "*/.git/*" ! -path "*/node_modules/*" ! -path "*/venv/*" 2>/dev/null | head -1)
  if [ -n "$TEST_DATA_FILE" ]; then
    TEST_DATA_FILE=$(realpath --relative-to="$WORKSPACE/repo" "$TEST_DATA_FILE" 2>/dev/null || echo "$TEST_DATA_FILE")
    break
  fi
done
echo "[intake] Test data file: ${TEST_DATA_FILE:-none}" >> "$LOG"

# ---- 5. 校准 hf_deps + weight_target_paths ----
HF_DEPS_JSON="[]"
WEIGHT_PATHS_JSON="[]"

# 扫描代码中的 HF 引用
export REPO_DIR="$WORKSPACE/repo"
HF_REFS=$(grep -rn "from_pretrained\|hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | head -20)
echo "HF refs found: $HF_REFS" >> "$LOG"

# 从传入的 hf_repos 构建 weight_target_paths
# F14: 最小可验证子集 — 多变体项目(如 Qwen3-TTS 6 个 repo)不需全下
# 筛选策略: 优先选最大变体 + Tokenizer/Codec 必需 + 跳过 Base/fine-tune-only 变体
if [ "$HF_REPOS" != "[]" ]; then
  FILTERED_REPOS=$(echo "$HF_REPOS" | python3 << 'PYEOF'
import sys, json, re

repos = json.loads(sys.stdin.read())
if len(repos) <= 2:
    # 1-2 个 repo,全下(没必要筛选)
    print(json.dumps(repos))
    sys.exit(0)

# 多 repo 筛选逻辑
essential = []  # 必需: Tokenizer/Codec/Vocoder
main_models = []  # 主模型: CustomVoice/VoiceDesign 等(功能最全)
base_models = []  # 基础: Base 模型(fine-tune 用,推理不需要)
others = []

for r in repos:
    name = r.split("/")[-1] if "/" in r else r
    lower = name.lower()
    
    # Tokenizer/Codec/Vocoder — 必需依赖
    if any(kw in lower for kw in ["tokenizer", "codec", "vocoder", "processor", "config"]):
        essential.append(r)
    # Base 模型 — fine-tune 用,推理验证不需要
    elif "base" in lower and "custom" not in lower and "instruct" not in lower:
        base_models.append(r)
    # CustomVoice/VoiceDesign/Instruct — 功能最全变体
    elif any(kw in lower for kw in ["custom", "voice", "instruct", "chat", " instruct", "it"]):
        main_models.append(r)
    else:
        others.append(r)

# 选择策略:
# 1. 必需依赖全选
# 2. 主模型选最大尺寸(验证上限)
# 3. Base 模型跳过(除非没有主模型)
# 4. others 选一个(最小的,节省空间)

result = list(essential)

if main_models:
    # 选最大的(按参数量排序,取最大)
    def extract_size(name):
        # 尝试从名字提取参数量: 1.7B, 0.6B, 7B, 13B 等
        match = re.search(r'(\d+\.?\d*)[Bb]', name)
        return float(match.group(1)) if match else 0
    main_models.sort(key=extract_size, reverse=True)
    result.append(main_models[0])  # 最大的主模型
elif base_models:
    # 没有主模型,只能用 Base
    base_models.sort(key=lambda x: extract_size(x), reverse=True)
    result.append(base_models[0])
elif others:
    # 没有分类信息,选最大的
    others.sort(key=lambda x: extract_size(x), reverse=True)
    result.append(others[0])

# 如果还有 others 且总数<4,加一个最小的(增加覆盖率)
remaining = [r for r in (others + main_models[1:] + base_models[1:]) if r not in result]
if remaining and len(result) < 4:
    remaining.sort(key=lambda x: extract_size(x))
    result.append(remaining[0])

skipped = [r for r in repos if r not in result]
if skipped:
    print(f"[intake] F14: Skipped non-essential repos: {skipped}", file=sys.stderr)

print(json.dumps(result))
PYEOF
)
  # 如果筛选失败,回退到全量下载
  if [ -z "$FILTERED_REPOS" ] || [ "$FILTERED_REPOS" = "[]" ]; then
    echo "[intake] F14 filter failed, falling back to full download" >> "$LOG"
    FILTERED_REPOS="$HF_REPOS"
  fi
  
  WEIGHT_PATHS_JSON=$(echo "$FILTERED_REPOS" | python3 -c "
import sys, json
repos = json.loads(sys.stdin.read())
paths = [{'hf_repo': r, 'target_rel': f'.cache/hf_models/{r}'} for r in repos]
print(json.dumps(paths))
")
  HF_DEPS_JSON="$FILTERED_REPOS"
  
  # Fix5-B: weight_target_paths 环境变量路径映射增强
  # 扫描代码中的权重路径 hardcode + 环境变量，构建更准确的 symlink 映射
  WEIGHT_PATHS_JSON=$(echo "$FILTERED_REPOS" | python3 << 'PYEOF5B'
import sys, json, os, re, pathlib

repos = json.loads(sys.stdin.read())
repo_dir = os.environ.get("REPO_DIR", "")
paths = []

for r in repos:
    entry = {"hf_repo": r, "target_rel": f".cache/hf_models/{r}"}
    
    if not repo_dir or not os.path.isdir(repo_dir):
        paths.append(entry)
        continue
    
    # 策略1: 从 from_pretrained 调用中提取 local_dir / cache_dir 参数
    # 例: from_pretrained("org/model", cache_dir="checkpoints/")
    for py in pathlib.Path(repo_dir).rglob("*.py"):
        try:
            text = py.read_text(errors="ignore")
        except:
            continue
        # 找 local_dir= / cache_dir= / model_path= 等参数
        for m in re.finditer(
            r'(?:local_dir|cache_dir|model_path|ckpt_dir|weight_dir|checkpoint_dir)\s*[=:]\s*["\']([^"\']+)["\']',
            text
        ):
            custom_path = m.group(1)
            if custom_path and not custom_path.startswith(("/", "$", "~")):
                entry["target_rel"] = custom_path
                entry["symlink_from"] = f".cache/hf_models/{r}"
                break
        
        # 如果已找到就不再搜
        if entry.get("symlink_from"):
            break
    
    # 策略2: 扫描环境变量路径映射(README + .env + 代码)
    # 例: MAGENTA_HOME=xxx, TRANSFORMERS_CACHE=xxx, CKPT_PATH=xxx
    if not entry.get("symlink_from") and repo_dir:
        env_patterns = []
        # 从 .env 文件
        env_file = pathlib.Path(repo_dir) / ".env"
        if env_file.exists():
            for line in env_file.read_text(errors="ignore").splitlines():
                m = re.match(r'^\s*([A-Z_]+(?:MODEL|CKPT|WEIGHT|PATH|HOME|CACHE|DIR)[A-Z_]*)\s*=\s*(.+)', line)
                if m:
                    env_patterns.append((m.group(1), m.group(2).strip().strip('"').strip("'")))
        
        # 从 README 和代码中 grep 环境变量引用
        for doc in list(pathlib.Path(repo_dir).glob("README*")) + list(pathlib.Path(repo_dir).glob("*.md")):
            try:
                text = doc.read_text(errors="ignore")
            except:
                continue
            for m in re.finditer(
                r'(?:export\s+)?([A-Z_]+(?:MODEL|CKPT|WEIGHT|PATH|HOME|CACHE|DIR)[A-Z_]*)\s*[=:]\s*["\']?([^"\'\s\n]+)',
                text
            ):
                env_patterns.append((m.group(1), m.group(2)))
        
        # 如果找到环境变量路径映射，记录到 weight_target_paths
        if env_patterns:
            entry["env_mappings"] = [{"var": k, "value": v} for k, v in env_patterns[:5]]
    
    paths.append(entry)

print(json.dumps(paths, ensure_ascii=False))
PYEOF5B
)
  
  # 记录筛选信息
  ORIGINAL_COUNT=$(echo "$HF_REPOS" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "?")
  FILTERED_COUNT=$(echo "$FILTERED_REPOS" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "?")
  echo "[intake] F14: hf_repos ${ORIGINAL_COUNT}→${FILTERED_COUNT} (minimal verifiable subset)" >> "$LOG"
fi

# ---- 6. Preflight ----
BLOCKED_JSON="[]"
WARNINGS_JSON="[]"
GATED_OK=true
GPU_PICKS_JSON="[]"
FREE_DISK_GB=0

# 磁盘 — 乘以 3x 安全系数(HF 下载含 .cache 元数据+LFS,实测 2-4.4x 偏差)
FREE_DISK_GB=$(df -BG /root | awk 'NR==2 {gsub("G","",$4); print $4}')
NEED_DISK=$(python3 -c "print(int(float('$EST_WEIGHT_GB' or 0) * 3 + 50))" 2>/dev/null || echo 150)
echo "[intake] Disk check: free=${FREE_DISK_GB}GB, need=${NEED_DISK}GB (est=${EST_WEIGHT_GB}GB × 3 + 50)" >> "$LOG"
if [ "${FREE_DISK_GB:-0}" -lt "${NEED_DISK:-150}" ]; then
  BLOCKED_JSON=$(echo "$BLOCKED_JSON" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('disk_low: free=${FREE_DISK_GB}GB need=${NEED_DISK}GB'); print(json.dumps(a))")
fi

# GPU
GPU_INFO=$(nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "")
if [ -n "$GPU_INFO" ]; then
  GPU_PICKS_JSON=$(echo "$GPU_INFO" | python3 -c "
import sys, json
lines = sys.stdin.read().strip().split('\n')
picks = []
for line in lines:
    parts = [p.strip() for p in line.split(',')]
    if len(parts) == 4:
        idx, used, free, total = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
        # 跳过训练卡(used >= 25000MiB)
        if used >= 25000:
            continue
        # 跳过GPU0-3(用户RL训练区)
        if idx < 4:
            continue
        # 每卡最少留6GB(用户偏好)
        if free >= 6144:
            picks.append(idx)
print(json.dumps(picks))
")
fi

# Gated 检查
for repo in $(echo "$GATED_REPOS" | python3 -c "import sys,json; [print(r) for r in json.loads(sys.stdin.read())]" 2>/dev/null); do
  IS_GATED=$(curl -s "https://huggingface.co/api/models/$repo" 2>/dev/null | jq -r '.gated // "false"' 2>/dev/null || echo "check_failed")
  if [ "$IS_GATED" != "false" ]; then
    # 实测
    DL_TEST=$(HF_HOME="$WORKSPACE/.cache/huggingface" hf download "$repo" config.json --token "$HF_TOKEN" 2>&1)
    if echo "$DL_TEST" | grep -qiE "Access denied|requires approval|Cannot access gated repo|401|403"; then
      BLOCKED_JSON=$(echo "$BLOCKED_JSON" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('gated_needs_approval: $repo'); print(json.dumps(a))")
      GATED_OK=false
    fi
  fi
done

# 30B 检查
if [ "$EST_PARAMS_B" -gt 30 ] 2>/dev/null; then
  BLOCKED_JSON=$(echo "$BLOCKED_JSON" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('model_too_large'); print(json.dumps(a))")
fi

# GPU 不足 warning
NEED_VRAM_MB=$(echo "$EST_WEIGHT_GB * 1024 * 1.5" | bc 2>/dev/null || echo 0)
GPU_FREE_TOTAL=$(echo "$GPU_INFO" | python3 -c "
import sys
total = 0
for line in sys.stdin.read().strip().split('\n'):
    parts = [p.strip() for p in line.split(',')]
    if len(parts) == 4:
        idx, used, free = int(parts[0]), int(parts[1]), int(parts[2])
        if used < 25000 and idx >= 4:
            total += free
print(total)
" 2>/dev/null || echo 0)
if [ "${GPU_FREE_TOTAL:-0}" -lt "${NEED_VRAM_MB:-0}" ] && [ "${#BLOCKED_JSON}" -le 2 ]; then
  WARNINGS_JSON=$(echo "$WARNINGS_JSON" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('gpu_vram_insufficient: free=${GPU_FREE_TOTAL}MB need=${NEED_VRAM_MB}MB'); print(json.dumps(a))")
fi

READY_TO_FETCH=true
if [ "${#BLOCKED_JSON}" -gt 2 ]; then
  READY_TO_FETCH=false
fi

# ---- 7. 落盘 ----
# 传环境变量给 Python heredoc
export IN_SLUG="$SLUG"
export IN_WORKSPACE="$WORKSPACE"
export IN_ENTRY_SCRIPT="$ENTRY_SCRIPT"
export IN_ENTRY_TYPE="$ENTRY_TYPE"
export IN_HF_DEPS_JSON="$HF_DEPS_JSON"
export IN_WEIGHT_PATHS_JSON="$WEIGHT_PATHS_JSON"
export IN_GPU_PICKS_JSON="$GPU_PICKS_JSON"
export IN_BLOCKED_JSON="$BLOCKED_JSON"
export IN_WARNINGS_JSON="$WARNINGS_JSON"
export IN_PYTHON_VERSION="$PYTHON_VERSION"
export IN_PYTHON_CONFIDENCE="$PYTHON_CONFIDENCE"
export IN_GATED_OK="$GATED_OK"
export IN_FREE_DISK_GB="${FREE_DISK_GB:-0}"
export IN_READY_TO_FETCH="$READY_TO_FETCH"
export IN_TEST_DATA_FILE="${TEST_DATA_FILE:-}"
export IN_START_TS="$START_TS"

python3 << 'PYEOF'
import json, os, datetime

slug = os.environ["IN_SLUG"]
workspace = os.environ["IN_WORKSPACE"]
entry_script = os.environ["IN_ENTRY_SCRIPT"] or None
entry_type = os.environ.get("IN_ENTRY_TYPE", "script") or "script"
hf_deps = json.loads(os.environ["IN_HF_DEPS_JSON"])
weight_paths = json.loads(os.environ["IN_WEIGHT_PATHS_JSON"])
gpu_picks = json.loads(os.environ["IN_GPU_PICKS_JSON"])
blocked = json.loads(os.environ["IN_BLOCKED_JSON"])
warnings = json.loads(os.environ["IN_WARNINGS_JSON"])
gated_ok = os.environ["IN_GATED_OK"] == "true"
ready_to_fetch = os.environ["IN_READY_TO_FETCH"] == "true"
free_disk_gb = float(os.environ.get("IN_FREE_DISK_GB", "0"))
python_version = os.environ["IN_PYTHON_VERSION"]
python_confidence = os.environ["IN_PYTHON_CONFIDENCE"]
test_data_file = os.environ.get("IN_TEST_DATA_FILE", "")
start_ts = int(os.environ["IN_START_TS"])
duration = int(datetime.datetime.now().timestamp()) - start_ts

result = {
    "entry_script": entry_script,
    "entry_type": entry_type,
    "hf_deps": hf_deps,
    "weight_target_paths": weight_paths,
    "gpu_picks": gpu_picks,
    "blocked": blocked,
    "warnings": warnings,
    "python_version": python_version,
    "python_version_confidence": python_confidence,
    "preflight": {
        "gated_ok": gated_ok,
        "free_disk_gb": free_disk_gb,
        "gpu_available": gpu_picks,
    },
    "ready_to_fetch": ready_to_fetch,
    "test_data_file": test_data_file,
    "duration_seconds": duration,
    "completed_at": datetime.datetime.now().isoformat()
}

with open(os.path.join(workspace, "results", "intake.json"), "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# 更新 state.json
state_path = os.path.join(workspace, "state.json")
with open(state_path) as f:
    state = json.load(f)

if result["blocked"]:
    state["phase"] = "paused_for_human"
    state["status"] = "paused_for_human"
else:
    state["phase"] = "fetching"
    state["phases_done"] = ["intake"]
    state["status"] = "done"
    state["intake_result"] = result

state["updated_at"] = datetime.datetime.now().isoformat()
with open(state_path, "w") as f:
    json.dump(state, f, indent=2, ensure_ascii=False)

print("INTAKE_RESULT: " + ("BLOCKED" if result["blocked"] else "OK"))
PYEOF

echo "=== PHASE_END phase=intake slug=$SLUG status=$(jq -r '.status' "$WORKSPACE/state.json") ts=$(date -Iseconds) ==="
