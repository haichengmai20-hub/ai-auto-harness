#!/bin/bash
# SessionEnd hook — 落盘归档 + 清理老 runs
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

RUN_ID="${AI_HARNESS_RUN_ID:-$(cat "$HARNESS_ROOT/runs/.current_run_id" 2>/dev/null || echo "unknown")}"
RUN_DIR="$HARNESS_ROOT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

# Handoff sentinel audit: do not mutate workspace state here. This hook only
# records whether long-running background work needs the next session/cron to
# resume via Task().
python3 - "$HARNESS_ROOT" "$RUN_DIR/handoff-audit.json" <<'PYEOF' >&2 || true
import json, pathlib, sys, time

root = pathlib.Path(sys.argv[1])
audit_path = pathlib.Path(sys.argv[2])
items = []
for sentinel in sorted(root.glob("workspace/*/.cache/handoff/*.json")):
    try:
        data = json.loads(sentinel.read_text())
    except Exception as exc:
        data = {"status": "invalid_json", "error": str(exc)}
    rel = str(sentinel.relative_to(root))
    data.setdefault("path", rel)
    data.setdefault("slug", sentinel.parents[2].name)
    items.append(data)

payload = {
    "checked_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "sentinel_count": len(items),
    "attention": [
        item for item in items
        if item.get("status") in ("running", "done", "failed", "paused_in_progress", "invalid_json")
    ],
    "items": items,
}
audit_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))

if payload["attention"]:
    print("Harness handoff audit: pending/finished long-task sentinels need resume review:")
    for item in payload["attention"][:12]:
        print("  - " + json.dumps({
            "slug": item.get("slug"),
            "phase": item.get("phase"),
            "status": item.get("status"),
            "pid": item.get("pid"),
            "path": item.get("path"),
        }, ensure_ascii=False, sort_keys=True))
    print(f"  audit: {audit_path}")
PYEOF

# 只 commit 报告 + memory(workspace 是 gitignored)
if [ -d .git ]; then
    git add reports/ memory/ pending_human/ 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "auto-run $(date +%Y-%m-%d-%H%M): update reports/memory" 2>/dev/null || true
    fi
fi

# 清 7 天以上 runs
find runs/ -maxdepth 1 -mtime +7 -type d -exec rm -rf {} \; 2>/dev/null || true
