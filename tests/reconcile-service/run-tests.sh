#!/usr/bin/env bash
set -u
HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
RS="$HARNESS_ROOT/scripts/reconcile-sentinels.sh"
PASS=0; FAIL=0; ok(){ echo "ok: $1"; PASS=$((PASS+1)); }; bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# 隔离一个假 workspace 根(reconcile 应只扫 workspace/*/.cache/handoff)
TROOT=$(mktemp -d); WS="$TROOT/workspace/svc-test"; mkdir -p "$WS/.cache/handoff"

# 孤儿:status=running 且 PID 活
sleep 600 & ORPHAN=$!; echo "$ORPHAN" > "$WS/.cache/backend.pid"
cat > "$WS/.cache/handoff/service-old.json" <<JSON
{"phase":"service","status":"running","pid":$ORPHAN,"run_id":"old","workspace":"$WS"}
JSON

AI_HARNESS_WORKSPACE_GLOB="$TROOT/workspace" bash "$RS" >/dev/null 2>&1 || true
kill -0 "$ORPHAN" 2>/dev/null && { bad "孤儿 PID 没被杀"; kill -9 "$ORPHAN" 2>/dev/null; } || ok "孤儿 PID 被杀"
grep -q '"status": *"stopped"' "$WS/.cache/handoff/service-old.json" && ok "sentinel 标 stopped" || bad "sentinel 没标 stopped"

# R1:未登记在任何 .cache/*.pid 的外部 PID,即使被 sentinel 引用也不杀
sleep 600 & EXT=$!
cat > "$WS/.cache/handoff/service-ext.json" <<JSON
{"phase":"service","status":"running","pid":$EXT,"run_id":"old","workspace":"$WS"}
JSON
# 注意:不把 EXT 写进 backend.pid(模拟外部进程)
AI_HARNESS_WORKSPACE_GLOB="$TROOT/workspace" bash "$RS" >/dev/null 2>&1 || true
kill -0 "$EXT" 2>/dev/null && ok "外部未登记 PID 未被杀(R1)" || bad "误杀了未登记 PID(违反 R1)"
kill -9 "$EXT" 2>/dev/null || true; rm -rf "$TROOT"

echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]
