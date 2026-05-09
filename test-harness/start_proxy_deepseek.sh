#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ps/dcr/claudecode/claudecode_sourcecode1"
KEY_FILE="$ROOT/test-harness/.env.cc_keys"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "[ERROR] Missing $KEY_FILE"
  echo "Create it first: cp $ROOT/test-harness/.env.cc_keys.example $KEY_FILE"
  exit 1
fi

set -a
source "$KEY_FILE"
set +a

: "${OPENAI_BASE_URL:?OPENAI_BASE_URL is required}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"
: "${ANTHROPIC_PROXY_MODEL:?ANTHROPIC_PROXY_MODEL is required}"

export ANTHROPIC_PROXY_PORT="${ANTHROPIC_PROXY_PORT:-8082}"
export ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS="${ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS:-8192}"

cd "$ROOT"
pkill -f anthropic-qwen-proxy || true

BUN=/home/ps/dcr_claude_home/.bun/bin/bun
[[ -x "$BUN" ]] || BUN=bun

"$BUN" run anthropic-qwen-proxy
