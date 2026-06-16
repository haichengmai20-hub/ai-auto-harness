#!/usr/bin/env bash
# service-lifecycle.sh fixture 测试。无 pytest,纯 bash 断言。
set -u
HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
LC="$HARNESS_ROOT/scripts/service-lifecycle.sh"
PASS=0; FAIL=0
ok(){ echo "ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkws(){ # $1=ready_type ; 造一个临时 workspace + intake.json
  local ws; ws=$(mktemp -d)
  mkdir -p "$ws/.cache/handoff" "$ws/results" "$ws/logs"
  if [ "$1" = log ]; then
    cat > "$ws/results/intake.json" <<JSON
{"entry_type":"service","service":{"start_cmd":"sleep 300","ready_signal":{"type":"log","pattern":"SERVER READY"},"stop_cmd":"","port":0,"output_path":"out.txt"}}
JSON
  else
    cat > "$ws/results/intake.json" <<JSON
{"entry_type":"service","service":{"start_cmd":"python3 -m http.server $2 --bind 127.0.0.1","ready_signal":{"type":"http","url":"http://127.0.0.1:$2/","expect_status":200},"stop_cmd":"","port":$2,"output_path":"out.txt"}}
JSON
  fi
  echo "$ws"
}

# T2.1 start 写 PID + sentinel + 进程活
WS=$(mkws log)
bash "$LC" start "$WS" >/dev/null 2>&1
PID=$(head -1 "$WS/.cache/backend.pid" 2>/dev/null)
{ [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; } && ok "start: 进程活+PID登记" || bad "start: 进程没起/没登记"
[ -f "$WS"/.cache/handoff/service-*.json ] && ok "start: 写了 sentinel" || bad "start: 没写 sentinel"

# T2.2 wait-ready(log 型):pattern 出现→exit 0
echo "xxx SERVER READY yyy" >> "$WS/logs/backend.log"
bash "$LC" wait-ready "$WS" 5 >/dev/null 2>&1 && ok "wait-ready(log): 命中→0" || bad "wait-ready(log): 命中没返回 0"

# T2.3 stop:进程死 + sentinel stopped
bash "$LC" stop "$WS" >/dev/null 2>&1
# Use /proc/<pid>/stat to check liveness: zombie (Z) counts as dead (kill -0 passes for zombies in containers without PID-1 reaping)
_ST=$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null)
{ [ -z "$_ST" ] || [ "$_ST" = Z ]; } && ok "stop: 进程已死" || bad "stop: 进程还活(state=$_ST)"
grep -q '"status": *"stopped"' "$WS"/.cache/handoff/service-*.json 2>/dev/null && ok "stop: sentinel=stopped" || bad "stop: sentinel 没标 stopped"
rm -rf "$WS"

# T2.4 wait-ready 超时:pattern 不出现→exit 1
WS=$(mkws log); bash "$LC" start "$WS" >/dev/null 2>&1
if bash "$LC" wait-ready "$WS" 2 >/dev/null 2>&1; then bad "wait-ready: 该超时却返回 0"; else ok "wait-ready: 超时返回非 0"; fi
bash "$LC" stop "$WS" >/dev/null 2>&1; rm -rf "$WS"

# T2.5 wait-ready(http 型):真起 http.server 健康检查
PORT=$(( (RANDOM % 2000) + 23000 ))
WS=$(mkws http "$PORT"); export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
bash "$LC" start "$WS" >/dev/null 2>&1
bash "$LC" wait-ready "$WS" 10 >/dev/null 2>&1 && ok "wait-ready(http): 200→0" || bad "wait-ready(http): 健康检查没过"
bash "$LC" stop "$WS" >/dev/null 2>&1; rm -rf "$WS"

echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]
