#!/bin/bash
# phase-fetch-weights.sh — fetch-weights 阶段执行脚本
# 核心改进: setsid nohup 后台下载 + sentinel,子代理只需启动+快速检查+退出
# 用法: bash hermes/scripts/phase-fetch-weights.sh <slug> <run_id> <hf_repos_json> <gated_repos_json>
set -uo pipefail
START_TS=$(date +%s)
export AI_HARNESS_GUARD_SKIP=1

SLUG="$1"; RUN_ID="$2"; HF_REPOS_JSON="$3"; GATED_REPOS_JSON="$4"

HARNESS_ROOT="/root/ai-auto-harness"
WORKSPACE="$HARNESS_ROOT/workspace/$SLUG"
export WORKSPACE
LOG="$WORKSPACE/logs/fetch_weights.log"

cd "$HARNESS_ROOT"
[ -f .env ] && { set -a; source .env; set +a; }

# ---- Fix4: proxy-503 绕过 ----
# 代理环境下 hf download 走直连，避免 503 Too many open connections
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy 2>/dev/null || true
export no_proxy="${no_proxy:+$no_proxy,}huggingface.co,.huggingface.co,.xet.cn"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}huggingface.co,.huggingface.co,.xet.cn"

# ---- Fix6: R3 wall-clock 兜底 ----
# 单个 repo 下载超过 MAX_DOWNLOAD_MINUTES 则标记超时
MAX_DOWNLOAD_MINUTES=${MAX_DOWNLOAD_MINUTES:-120}

export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2

echo "=== PHASE_START phase=fetch-weights slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ===" >> "$LOG"

# ---- state: running ----
jq '.phase = "fetching" | .status = "running" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"

WEIGHTS_DONE=()
WEIGHTS_FAILED=()
ALL_DONE=true

# 解析 hf_repos
REPOS=$(echo "$HF_REPOS_JSON" | python3 -c "import sys,json; [print(r) for r in json.loads(sys.stdin.read())]" 2>/dev/null)

for REPO in $REPOS; do
  DEST="$WORKSPACE/.cache/hf_models/$REPO"
  mkdir -p "$DEST" "$WORKSPACE/.cache/handoff"
  SAFE_REPO=$(echo "$REPO" | tr '/:' '__')
  SENTINEL="$WORKSPACE/.cache/handoff/fetch-weights-$SAFE_REPO.json"
  PID_FILE="$WORKSPACE/.cache/$(basename $REPO).pid"

  echo "[fetch] Processing $REPO → $DEST" >> "$LOG"

  # ---- 接续判定 ----
  # 已有 sentinel 且 status=done → 跳过
  if [ -f "$SENTINEL" ]; then
    S_STATUS=$(jq -r '.status // ""' "$SENTINEL" 2>/dev/null)
    if [ "$S_STATUS" = "done" ]; then
      echo "[fetch] $REPO already done (sentinel), skipping" >> "$LOG"
      WEIGHTS_DONE+=("$REPO")
      continue
    fi
  fi

  # 已有后台下载在跑 → 不重启
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ]; then
      PID_STATE=$(awk '{print $3}' "/proc/$OLD_PID/stat" 2>/dev/null || echo "DEAD")
      if [ "$PID_STATE" != "DEAD" ] && [ "$PID_STATE" != "Z" ]; then
        echo "[fetch] $REPO download PID=$OLD_PID still alive (state=$PID_STATE), not restarting" >> "$LOG"
        echo "BG_DOWNLOAD_ALIVE: $REPO PID=$OLD_PID"
        ALL_DONE=false
        continue
      fi
    fi
  fi

  # 并发防护
  if pgrep -f "hf download.*$REPO" >/dev/null 2>&1; then
    echo "[fetch] $REPO already downloading (pgrep), skipping" >> "$LOG"
    ALL_DONE=false
    continue
  fi

  # ---- gated 检查 ----
  for gated in $(echo "$GATED_REPOS_JSON" | python3 -c "import sys,json; [print(r) for r in json.loads(sys.stdin.read())]" 2>/dev/null); do
    if [ "$REPO" = "$gated" ]; then
      echo "[fetch] $REPO is gated, checking access..." >> "$LOG"
      DL_TEST=$(hf download "$REPO" config.json --token "$HF_TOKEN" 2>&1 | head -5)
      if echo "$DL_TEST" | grep -qiE "Access denied|requires approval|Cannot access gated repo|401|403"; then
        echo "[fetch] $REPO gated access denied" >> "$LOG"
        WEIGHTS_FAILED+=("$REPO")
        continue 2
      fi
    fi
  done

  # ---- 启动后台下载(setsid nohup) ----
  echo "[fetch] Starting background download for $REPO" >> "$LOG"
  setsid nohup bash -c "
    set +e
    STARTED_AT=\$(date -Iseconds)
    STARTED_EPOCH=\$(date +%s)
    # Fix4: 子进程也绕代理
    unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy 2>/dev/null || true
    export no_proxy='${no_proxy}' NO_PROXY='${NO_PROXY}'
    export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2
    export HF_HOME='$WORKSPACE/.cache/huggingface' HF_HUB_CACHE='$WORKSPACE/.cache/hf_hub'
    [ -f '$HARNESS_ROOT/.env' ] && { set -a; source '$HARNESS_ROOT/.env'; set +a; }

    # Fix6: wall-clock 超时守护
    timeout \${MAX_DOWNLOAD_MINUTES}m hf download '$REPO' --local-dir '$DEST' --token \"$HF_TOKEN\" 2>&1
    RC=\$?

    # Fix6: 超时检测
    NOW_EPOCH=\$(date +%s)
    ELAPSED_MIN=\$(( (NOW_EPOCH - STARTED_EPOCH) / 60 ))
    if [ \$RC -eq 124 ]; then
      echo '[fetch] WALLCLOCK TIMEOUT: $REPO exceeded \${MAX_DOWNLOAD_MINUTES}min, marking failed' >> '$LOG'
    fi

    # Fix1: 下载完整性校验
    BYTES=\$(du -sb '$DEST' 2>/dev/null | awk '{print \$1}')
    if [ \$RC -eq 0 ] && [ -n \"\$BYTES\" ] && [ \"\$BYTES\" -gt 0 ]; then
      # 查询 HF API 获取预期大小
      EXPECTED_SIZE=\$(python3 -c '
import json, sys, subprocess, os
repo = \"$REPO\"
token = os.environ.get(\"HF_TOKEN\", \"\")
try:
    result = subprocess.run([\"hf\", \"api\", \"info\", repo, \"--token\", token],
                          capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        sys.exit(0)
    # 预期大小从 siblings 汇总
    total = 0
    for line in result.stdout.split(\"\n\"):
        if \"size\" in line.lower():
            try:
                parts = line.split(\":\")
                if len(parts) >= 2:
                    total += int(parts[-1].strip().rstrip(\",\"))
            except: pass
    if total > 0:
        print(total)
except: pass
' 2>/dev/null || echo 0)
      if [ -n \"\$EXPECTED_SIZE\" ] && [ \"\$EXPECTED_SIZE\" -gt 0 ]; then
        RATIO=\$(python3 -c \"print(\$BYTES / \$EXPECTED_SIZE)\" 2>/dev/null || echo 1)
        # 5% 容差
        python3 -c \"exit(0 if 0.95 <= float('\$RATIO') <= 1.05 else 1)\" 2>/dev/null
        if [ \$? -ne 0 ]; then
          echo \"[fetch] INTEGRITY WARNING: $REPO actual=\${BYTES}B expected=\${EXPECTED_SIZE}B ratio=\${RATIO} (outside 95-105%%)\" >> '$LOG'
          # 不标记 failed（可能 HF API 返回不准），但记录警告
        fi
      fi
      # 检查 .incomplete 文件残留
      INCOMPLETE_COUNT=\$(find '$DEST' -name '*.incomplete' 2>/dev/null | wc -l)
      if [ \"\$INCOMPLETE_COUNT\" -gt 0 ]; then
        echo \"[fetch] INCOMPLETE FILES: $REPO has \$INCOMPLETE_COUNT .incomplete files\" >> '$LOG'
        RC=1
      fi
    fi

    python3 -c 'import json,sys,time; path,rc,bytes_,pid=sys.argv[1],int(sys.argv[2]),int(sys.argv[3] or 0),int(sys.argv[4]); json.dump({\"status\":\"done\" if rc==0 else \"failed\",\"slug\":\"$SLUG\",\"phase\":\"fetch-weights\",\"repo\":\"$REPO\",\"pid\":pid,\"exit_code\":rc,\"started_at\":\"$STARTED_AT\",\"completed_at\":time.strftime(\"%Y-%m-%dT%H:%M:%S%z\"),\"local_dir\":\"$DEST\",\"bytes\":bytes_}, open(path,\"w\"), ensure_ascii=False, indent=2)' '$SENTINEL' \"\$RC\" \"\${BYTES:-0}\" \"\$BASHPID\"
    exit \$RC
  " >> "$LOG" 2>&1 &
  PID=$!
  echo $PID > "$PID_FILE"
  echo "[fetch] Background PID=$PID for $REPO" >> "$LOG"

  # 更新 state fetch_state
  jq --arg repo "$REPO" --arg pid "$PID" --arg started "$(date -Iseconds)" \
    '.fetch_state = (.fetch_state // {}) | .fetch_state.bg_shells = (.fetch_state.bg_shells // []) | .fetch_state.bg_shells += [{"repo": $repo, "pid": ($pid|tonumber), "started_at": $started}]' \
    "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"

  ALL_DONE=false
done

# ---- 判定结果 ----
if [ "$ALL_DONE" = "true" ]; then
  # 全部完成 → 校验 + symlink
  for REPO in $REPOS; do
    DEST="$WORKSPACE/.cache/hf_models/$REPO"
    # 检查 .incomplete
    INCOMPLETE=$(find "$DEST" -name "*.incomplete" 2>/dev/null | wc -l)
    if [ "$INCOMPLETE" -gt 0 ]; then
      echo "[fetch] WARNING: $REPO has $INCOMPLETE .incomplete files" >> "$LOG"
      ALL_DONE=false
    fi
  done

  if [ "$ALL_DONE" = "true" ]; then
    # symlink — Fix5-B: 读取 weight_target_paths 的 symlink_from 字段做精准映射
    if [ -f "$WORKSPACE/results/intake.json" ]; then
      python3 << 'SYMLINK_PY'
import json, os, pathlib

workspace = os.environ.get("WORKSPACE", "")
intake = json.loads(pathlib.Path(f"{workspace}/results/intake.json").read_text())
wtp = intake.get("weight_target_paths", [])

for entry in wtp:
    hf_repo = entry.get("hf_repo", "")
    target_rel = entry.get("target_rel", "")
    symlink_from = entry.get("symlink_from", "")
    
    if not hf_repo or not target_rel:
        continue
    
    # 确定源目录
    if symlink_from:
        src = f"{workspace}/{symlink_from}"
    else:
        src = f"{workspace}/.cache/hf_models/{hf_repo}"
    
    # 确定目标路径
    dst = f"{workspace}/repo/{target_rel}"
    
    # 如果 target_rel 不是 .cache/hf_models 开头(代码里 hardcode 的路径)
    # 需要建 symlink 把下载目录映射到代码期望的位置
    if not target_rel.startswith(".cache/hf_models"):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.exists(dst) and not os.path.islink(dst):
            # 备份非 symlink 的原始文件/目录
            import shutil
            shutil.move(dst, dst + ".bak")
        os.symlink(src, dst)
        print(f"[symlink] {src} → {dst}")
    else:
        # 默认路径不需要额外 symlink(fetch 已经下载到正确位置)
        pass
    
    # env_mappings: 设置环境变量指向正确路径
    for mapping in entry.get("env_mappings", []):
        var = mapping.get("var", "")
        val = mapping.get("value", "")
        if var:
            # 写到 .env.local 供 run-and-repair 使用
            env_local = pathlib.Path(f"{workspace}/repo/.env.local")
            lines = env_local.read_text().splitlines() if env_local.exists() else []
            lines.append(f"{var}={workspace}/.cache/hf_models/{hf_repo}")
            env_local.write_text("\n".join(lines) + "\n")
            print(f"[env] {var}={workspace}/.cache/hf_models/{hf_repo}")
SYMLINK_PY
    fi

    # 计算 bytes
    TOTAL_BYTES=0
    for REPO in $REPOS; do
      DEST="$WORKSPACE/.cache/hf_models/$REPO"
      B=$(du -sb "$DEST" 2>/dev/null | awk '{print $1}')
      TOTAL_BYTES=$((TOTAL_BYTES + ${B:-0}))
    done

    # 写 result
    DONE_JSON=$(printf '%s\n' "${WEIGHTS_DONE[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")
    FAIL_JSON=$(printf '%s\n' "${WEIGHTS_FAILED[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")

    cat > "$WORKSPACE/results/fetch.json" << FETCHJSON
{
  "weights_done": $DONE_JSON,
  "failed": $FAIL_JSON,
  "paused_in_progress": false,
  "bytes_total": $TOTAL_BYTES,
  "duration_seconds": $(($(date +%s) - START_TS)),
  "completed_at": "$(date -Iseconds)"
}
FETCHJSON

    jq '.phase = "installing" | .status = "done" | .phases_done += ["fetch-weights"] | .fetch_result = (inputs) | .updated_at = "'$(date -Iseconds)'"' \
      "$WORKSPACE/state.json" "$WORKSPACE/results/fetch.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"

    echo "FETCH_RESULT: DONE"
  else
    # 有 .incomplete → paused_in_progress
    jq '.status = "paused_in_progress" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"
    echo "FETCH_RESULT: PAUSED_IN_PROGRESS (incomplete files)"
  fi
else
  # 有后台下载在跑 → paused_in_progress
  jq '.status = "paused_in_progress" | .updated_at = "'$(date -Iseconds)'"' "$WORKSPACE/state.json" > /tmp/state_tmp.json && mv /tmp/state_tmp.json "$WORKSPACE/state.json"
  echo "FETCH_RESULT: PAUSED_IN_PROGRESS (bg downloads running)"
fi

echo "=== PHASE_END phase=fetch-weights slug=$SLUG status=$(jq -r '.status' "$WORKSPACE/state.json") ts=$(date -Iseconds) ===" >> "$LOG"
