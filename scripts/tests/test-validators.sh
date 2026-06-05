#!/usr/bin/env bash
# test-validators.sh — offline regression tests for fetch-weights / artifacts validators.
#
# Why this exists (Fix #30 / #31):
#   - validate-fetch-weights.sh is the integrity check that catches Xet-corrupted
#     downloads (controlfoley: CLAP model 469MB on disk vs 2.2GB expected). Before
#     this test the validator logic was only exercised by ad-hoc, uncommitted fixtures.
#   - validate-artifacts.sh is the Phase-5 artifact gate (verify/runbook/cleanup JSON).
#
# These tests are 100% offline: validate-fetch-weights.sh takes an optional
# manifest_json arg, so we feed a synthetic Hugging Face manifest instead of hitting
# the network. Small byte sizes keep the run instant while still exercising the exact
# >5% size-mismatch branch that the real corruption tripped.
#
# Usage:  bash scripts/tests/test-validators.sh
# Exit:   0 = all asserts pass, 1 = a test failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH_VALIDATOR="$SCRIPTS_DIR/validate-fetch-weights.sh"
ARTIFACT_VALIDATOR="$SCRIPTS_DIR/validate-artifacts.sh"

PASS=0
FAIL=0

# run <expected_rc> <label> <cmd...>
run() {
    local expected="$1"; shift
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq "$expected" ]; then
        echo "  PASS [$label] (rc=$rc)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$label] expected rc=$expected got rc=$rc"
        echo "$out" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fixture: a workspace whose local_dir has files of known size ──
REPO_ID="acme/test-model"
WS="$TMP/ws"
LOCAL_DIR="$WS/.cache/hf_models/$REPO_ID"
mkdir -p "$LOCAL_DIR"
# good.bin: 1000 bytes, matches manifest exactly
head -c 1000 /dev/zero > "$LOCAL_DIR/good.bin"
# clap.pt: 469 bytes locally but manifest will claim 2200 bytes (the controlfoley bug,
# scaled down 1e6x) → >5% mismatch → must FAIL.
head -c 469 /dev/zero > "$LOCAL_DIR/clap.pt"

manifest() {  # $1 = output path; emits a HF-shaped manifest
    cat > "$1"
}

echo "=== validate-fetch-weights.sh ==="

# Case 1: all sizes within 5% → PASS (rc 0)
manifest "$TMP/m_pass.json" <<JSON
{"siblings":[{"rfilename":"good.bin","size":1000}]}
JSON
run 0 "fetch: sizes match" \
    bash "$FETCH_VALIDATOR" "$WS" "$REPO_ID" "$LOCAL_DIR" "$TMP/m_pass.json"

# Case 2: size mismatch (469 vs 2200, ~79% off) → FAIL (rc 1)  [reproduces controlfoley]
manifest "$TMP/m_mismatch.json" <<JSON
{"siblings":[{"rfilename":"good.bin","size":1000},{"rfilename":"clap.pt","size":2200}]}
JSON
run 1 "fetch: size mismatch (Xet corruption)" \
    bash "$FETCH_VALIDATOR" "$WS" "$REPO_ID" "$LOCAL_DIR" "$TMP/m_mismatch.json"

# Case 3: manifest lists a file missing on disk → FAIL (rc 1)
manifest "$TMP/m_missing.json" <<JSON
{"siblings":[{"rfilename":"good.bin","size":1000},{"rfilename":"absent.safetensors","size":5000}]}
JSON
run 1 "fetch: file missing locally" \
    bash "$FETCH_VALIDATOR" "$WS" "$REPO_ID" "$LOCAL_DIR" "$TMP/m_missing.json"

# Case 4: local_dir does not exist → FAIL (rc 1)
run 1 "fetch: local_dir missing" \
    bash "$FETCH_VALIDATOR" "$WS" "$REPO_ID" "$WS/.cache/hf_models/nope" "$TMP/m_pass.json"

echo
echo "=== validate-artifacts.sh ==="

# Case 5: full valid artifact set (verify passed → cleanup required) → PASS (rc 0)
AWS="$TMP/aws"
mkdir -p "$AWS/results"
cat > "$AWS/results/verify.json" <<JSON
{"passed":true,"failed_at":null,"evidence":"smoke 3/3","notes":"ok","confidence":"high","completed_at":"2026-06-05T00:00:00Z"}
JSON
cat > "$AWS/results/runbook.json" <<JSON
{"slug":"acme","runbook_path":"$AWS/RUNBOOK.md","status":"done","completed_at":"2026-06-05T00:00:00Z"}
JSON
: > "$AWS/RUNBOOK.md"
cat > "$AWS/results/cleanup.json" <<JSON
{"slug":"acme","dry_run":false,"freed_bytes":123,"completed_at":"2026-06-05T00:00:00Z"}
JSON
run 0 "artifacts: full valid set" \
    bash "$ARTIFACT_VALIDATOR" "$AWS"

# Case 6: verify.json missing → FAIL (rc 1)
BWS="$TMP/bws"
mkdir -p "$BWS/results"
run 1 "artifacts: verify.json missing" \
    bash "$ARTIFACT_VALIDATOR" "$BWS"

# Case 7: verify.json present but .passed not boolean → FAIL (rc 1)
CWS="$TMP/cws"
mkdir -p "$CWS/results"
cat > "$CWS/results/verify.json" <<JSON
{"passed":"yes","failed_at":null,"evidence":"x","notes":"x","confidence":"high","completed_at":"2026-06-05T00:00:00Z"}
JSON
run 1 "artifacts: .passed not boolean" \
    bash "$ARTIFACT_VALIDATOR" "$CWS"

echo
echo "================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL VALIDATOR TESTS PASSED"
