#!/bin/bash
# SessionEnd hook — 落盘归档 + 清理老 runs
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 只 commit 报告 + memory(workspace 是 gitignored)
if [ -d .git ]; then
    git add reports/ memory/ pending_human/ 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "auto-run $(date +%Y-%m-%d-%H%M): update reports/memory" 2>/dev/null || true
    fi
fi

# 清 7 天以上 runs
find runs/ -maxdepth 1 -mtime +7 -type d -exec rm -rf {} \; 2>/dev/null || true
