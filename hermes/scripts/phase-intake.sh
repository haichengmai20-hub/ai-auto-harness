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
fi

# ---- 4. 推断 entry_script ----
ENTRY_SCRIPT=""
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

# 查找 entry script
for candidate in "inference.py" "demo.py" "app.py" "run.py" "main.py" "predict.py"; do
  if find "$WORKSPACE/repo" -name "$candidate" -type f 2>/dev/null | head -1 | grep -q .; then
    ENTRY_SCRIPT=$(find "$WORKSPACE/repo" -name "$candidate" -type f 2>/dev/null | head -1 | sed "s|$WORKSPACE/repo/||")
    break
  fi
done

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
HF_REFS=$(grep -rn "from_pretrained\|hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | head -20)
echo "HF refs found: $HF_REFS" >> "$LOG"

# 从传入的 hf_repos 构建 weight_target_paths
if [ "$HF_REPOS" != "[]" ]; then
  WEIGHT_PATHS_JSON=$(echo "$HF_REPOS" | python3 -c "
import sys, json
repos = json.loads(sys.stdin.read())
paths = [{'hf_repo': r, 'target_rel': f'.cache/hf_models/{r}'} for r in repos]
print(json.dumps(paths))
")
  HF_DEPS_JSON="$HF_REPOS"
fi

# ---- 6. Preflight ----
BLOCKED_JSON="[]"
WARNINGS_JSON="[]"
GATED_OK=true
GPU_PICKS_JSON="[]"
FREE_DISK_GB=0

# 磁盘
FREE_DISK_GB=$(df -BG /root | awk 'NR==2 {gsub("G","",$4); print $4}')
NEED_DISK=$(echo "$EST_WEIGHT_GB + 50" | bc 2>/dev/null || echo 100)
if [ "${FREE_DISK_GB:-0}" -lt "${NEED_DISK:-100}" ]; then
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
