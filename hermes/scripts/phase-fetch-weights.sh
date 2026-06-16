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
LOG="$WORKSPACE/logs/fetch_weights.log"

cd "$HARNESS_ROOT"
[ -f .env ] && { set -a; source .env; set +a; }
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
    export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2
    export HF_HOME='$WORKSPACE/.cache/huggingface' HF_HUB_CACHE='$WORKSPACE/.cache/hf_hub'
    [ -f '$HARNESS_ROOT/.env' ] && { set -a; source '$HARNESS_ROOT/.env'; set +a; }
    hf download '$REPO' --local-dir '$DEST' --token '\$HF_TOKEN' 2>&1
    RC=\$?
    BYTES=\$(du -sb '$DEST' 2>/dev/null | awk '{print \$1}')
    python3 -c 'import json,sys,time; path,rc,bytes_,pid=sys.argv[1],int(sys.argv[2]),int(sys.argv[3] or 0),int(sys.argv[4]); json.dump({\"status\":\"done\" if rc==0 else \"failed\",\"slug\":\"$SLUG\",\"phase\":\"fetch-weights\",\"repo\":\"$REPO\",\"pid\":pid,\"exit_code\":rc,\"started_at\":\"\$STARTED_AT\",\"completed_at\":time.strftime(\"%Y-%m-%dT%H:%M:%S%z\"),\"local_dir\":\"$DEST\",\"bytes\":bytes_}, open(path,\"w\"), ensure_ascii=False, indent=2)' '$SENTINEL' \"\$RC\" \"\${BYTES:-0}\" \"\$BASHPID\"
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
    # symlink
    if [ -f "$WORKSPACE/results/intake.json" ]; then
      jq -r '.weight_target_paths // [] | .[] | "\(.hf_repo) \(.target_rel)"' "$WORKSPACE/results/intake.json" 2>/dev/null | while read REPO TARGET_REL; do
        SRC="$WORKSPACE/.cache/hf_models/$REPO"
        DST="$WORKSPACE/repo/$TARGET_REL"
        mkdir -p "$(dirname "$DST")"
        [ -e "$DST" ] && [ ! -L "$DST" ] && mv "$DST" "$DST.bak"
        ln -sfn "$SRC" "$DST"
      done
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
