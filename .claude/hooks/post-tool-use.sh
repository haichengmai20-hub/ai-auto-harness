#!/bin/bash
# PostToolUse hook — 每次 tool_use/result 追到 runs/<run-id>/transcript.jsonl
# CC 通过 stdin 传 JSON event
set -e
HARNESS_ROOT="/root/ai-auto-harness"
RUN_ID=$(cat "$HARNESS_ROOT/runs/.current_run_id" 2>/dev/null || echo "unknown")
TRANSCRIPT="$HARNESS_ROOT/runs/$RUN_ID/transcript.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"

TS=$(date -Iseconds)
EVENT=$(cat 2>/dev/null || echo '{}')
# 兜底:event 不是合法 JSON 也别炸
echo "{\"ts\":\"$TS\",\"event\":$EVENT}" >> "$TRANSCRIPT" 2>/dev/null || \
  echo "{\"ts\":\"$TS\",\"event_raw\":\"$(echo "$EVENT" | head -c 500 | tr '\n' ' ')\"}" >> "$TRANSCRIPT"
