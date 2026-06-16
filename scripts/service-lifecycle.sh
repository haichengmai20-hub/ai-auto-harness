#!/usr/bin/env bash
# 服务型项目生命周期机械动作:start / wait-ready / stop。
# 读 <workspace>/results/intake.json 的 .service。被 run-and-repair / verify SubAgent 调。
# ephemeral within-run:不跨 cron;sentinel 仅供孤儿回收(reconcile-sentinels.sh)。
set -u
ACTION="${1:-}"; WS="${2:-}"; EXTRA="${3:-}"
[ -z "$WS" ] && { echo "usage: service-lifecycle.sh <start|wait-ready|stop> <workspace> [timeout]" >&2; exit 2; }
INTAKE="$WS/results/intake.json"
LOG="$WS/logs/backend.log"
PIDFILE="$WS/.cache/backend.pid"
mkdir -p "$WS/.cache/handoff" "$WS/logs"
# KNOWN GOTCHA FIX: use set-u-safe nested default so fixtures without either var don't crash
SENT="$WS/.cache/handoff/service-${AI_HARNESS_RUN_ID:-${RUN_ID:-svc}}.json"

svc(){ jq -r ".service.$1 // empty" "$INTAKE" 2>/dev/null; }

case "$ACTION" in
  start)
    START_CMD=$(svc start_cmd)
    [ -z "$START_CMD" ] && { echo "no start_cmd in intake.json" >&2; exit 2; }
    nohup bash -c "$START_CMD" > "$LOG" 2>&1 &
    BPID=$!
    echo "$BPID" > "$PIDFILE"
    # 登记 launcher 派生子进程(若 start_cmd 是 wrapper)
    sleep 1
    pgrep -P "$BPID" >> "$PIDFILE" 2>/dev/null || true
    cat > "$SENT" <<JSON
{"phase":"service","status":"running","pid":$BPID,"run_id":"${AI_HARNESS_RUN_ID:-${RUN_ID:-svc}}","workspace":"$WS","started_at":"$(date -Iseconds)","log_path":"$LOG"}
JSON
    echo "$BPID"
    ;;
  wait-ready)
    TIMEOUT="${EXTRA:-300}"; TYPE=$(svc 'ready_signal.type'); DEADLINE=$(( $(date +%s) + TIMEOUT ))
    INTERVAL=3
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if [ "$TYPE" = http ]; then
        URL=$(svc 'ready_signal.url'); WANT=$(svc 'ready_signal.expect_status'); WANT="${WANT:-200}"
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$URL" 2>/dev/null || echo 000)
        [ "$CODE" = "$WANT" ] && { echo "ready(http $CODE)"; exit 0; }
      else
        PAT=$(svc 'ready_signal.pattern')
        grep -qE "$PAT" "$LOG" 2>/dev/null && { echo "ready(log)"; exit 0; }
      fi
      # backend 崩了就别再等
      BPID=$(head -1 "$PIDFILE" 2>/dev/null)
      if [ -n "$BPID" ]; then
        ST=$(awk '{print $3}' "/proc/$BPID/stat" 2>/dev/null)
        { [ -z "$ST" ] || [ "$ST" = Z ]; } && { echo "backend died before ready" >&2; exit 3; }
      fi
      sleep "$INTERVAL"; [ "$INTERVAL" -lt 15 ] && INTERVAL=$((INTERVAL+3))   # R4.6 动态间隔(≤60s)
    done
    echo "wait-ready timeout after ${TIMEOUT}s" >&2; exit 1
    ;;
  stop)
    STOP_CMD=$(svc stop_cmd)
    [ -n "$STOP_CMD" ] && bash -c "$STOP_CMD" >> "$LOG" 2>&1 || true
    if [ -f "$PIDFILE" ]; then
      while read -r pid; do
        [ -z "$pid" ] && continue
        ST=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
        { [ -z "$ST" ] || [ "$ST" = Z ]; } && continue   # 已死/僵尸(kill -0 会误判活)
        kill "$pid" 2>/dev/null || true
      done < "$PIDFILE"
      sleep 2
      while read -r pid; do
        [ -z "$pid" ] && continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      done < "$PIDFILE"
      sleep 1  # wait for kernel to reap after SIGKILL
      rm -f "$PIDFILE"
    fi
    [ -f "$SENT" ] && { tmp=$(mktemp); jq '.status="stopped" | .stopped_at="'"$(date -Iseconds)"'"' "$SENT" > "$tmp" 2>/dev/null && mv "$tmp" "$SENT" || true; }
    echo stopped
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
