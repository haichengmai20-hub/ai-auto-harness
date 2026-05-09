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

export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:8082}"
# Direct API key mode: clear any stale AUTH_TOKEN so SDK uses x-api-key header
# Proxy mode (no API key): set AUTH_TOKEN=dummy for local proxy
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  unset ANTHROPIC_AUTH_TOKEN
else
  export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-dummy}"
fi
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-${ANTHROPIC_PROXY_MODEL:-deepseek-v4-pro}}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$ANTHROPIC_MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$ANTHROPIC_MODEL}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-$ANTHROPIC_MODEL}"

# Enable thinking by default for DeepSeek tests
unset CLAUDE_CODE_DISABLE_THINKING || true
unset DISABLE_INTERLEAVED_THINKING || true

export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

if [[ -n "${BUN_PATH:-}" && -x "${BUN_PATH}" ]]; then
  BUN_BIN="$BUN_PATH"
elif [[ -n "${BUN_PATH:-}" ]]; then
  echo "[WARN] BUN_PATH is set but not executable: ${BUN_PATH}"
  BUN_BIN="$(command -v bun || true)"
else
  BUN_BIN="$(command -v bun || true)"
fi

if [[ -z "${BUN_BIN}" && -x "$HOME/.bun/bin/bun" ]]; then
  BUN_BIN="$HOME/.bun/bin/bun"
fi

if [[ -z "${BUN_BIN}" ]]; then
  echo "[ERROR] bun not found in PATH."
  echo "Install bun: https://bun.sh/  (or set BUN_PATH=/path/to/bun)"
  exit 127
fi

cd "$ROOT"
./bin/claude-haha
