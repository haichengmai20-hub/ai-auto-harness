#!/usr/bin/env bash
# healthcheck-daemon.sh — advisory check for cron/supervisord automation.
#
# Default mode exits 0 when the code-side prerequisites are present, even if the
# daemon is not installed/running. Use --strict to fail on missing daemon.
set -uo pipefail

STRICT=0
if [ "${1:-}" = "--strict" ]; then
    STRICT=1
fi

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
FAIL=0
WARN=0

pass() { echo "  PASS: $1"; }
warn() { echo "  WARN: $1"; WARN=$((WARN+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== healthcheck-daemon ==="
echo "  harness: $HARNESS_ROOT"
echo "  mode:    $([ "$STRICT" -eq 1 ] && echo strict || echo advisory)"
echo

[ -x "$HARNESS_ROOT/cron/daily.sh" ] && pass "cron/daily.sh is executable" || fail "cron/daily.sh missing or not executable"
[ -f "$HARNESS_ROOT/cron/crontab.example" ] && pass "cron/crontab.example exists" || fail "cron/crontab.example missing"

if command -v crontab >/dev/null 2>&1; then
    pass "crontab command exists"
    if crontab -l 2>/dev/null | grep -q "$HARNESS_ROOT/cron/daily.sh"; then
        pass "crontab has ai-auto-harness daily entry"
    else
        warn "crontab has no ai-auto-harness daily entry"
    fi
else
    warn "crontab command not found"
fi

if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
    pass "cron/crond process is running"
else
    warn "cron/crond process is not running"
fi

if command -v supervisord >/dev/null 2>&1 || [ -x /home/ubuntu/miniconda3/bin/supervisord ]; then
    pass "supervisord binary exists"
    if pgrep -f supervisord >/dev/null 2>&1; then
        pass "supervisord process is running"
    else
        warn "supervisord is installed but not running"
    fi
else
    warn "supervisord binary not found"
fi

if find "$HARNESS_ROOT/runs" -maxdepth 1 -type d -name 'cron-*' 2>/dev/null | grep -q .; then
    pass "runs/ contains cron-* run directories"
else
    warn "runs/ contains no cron-* run directories yet"
fi

echo
if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: $FAIL hard failure(s), $WARN warning(s)"
    exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
    echo "FAIL: strict mode found $WARN warning(s)"
    exit 1
fi
echo "PASS: daemon healthcheck completed with $WARN warning(s)"
exit 0
