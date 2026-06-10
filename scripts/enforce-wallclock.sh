#!/usr/bin/env bash
# enforce-wallclock.sh — R3 wall-clock 上限的代码级兜底
#
# 问题(Fix: 2026-06-10-external-review-sentinel-wallclock-runs-fix):
#   R3 各阶段上限(intake 15 / fetch 180 / install 60 / run 135 / verify 30 min)
#   是纯 prompt 软约束。SubAgent 中途死掉/被 kill 时 state.json 永远停在
#   status=running,下次 cron 的接续逻辑会被假 running 状态干扰。
#
# 行为(保守,只改 state.json status 字段,绝不 kill 进程):
#   workspace/*/state.json 中 status=="running" 且 updated_at 距今超过
#   该 phase 上限 1.5 倍(容忍正常慢) → status=paused_in_progress + 注记。
#   语义安全:paused_in_progress 本来就是"下次 cron 接续"的标准状态。
#
# Usage: bash scripts/enforce-wallclock.sh [HARNESS_ROOT]
set -uo pipefail
HARNESS_ROOT="${1:-/root/ai-auto-harness}"

python3 - "$HARNESS_ROOT" <<'PY'
import json, pathlib, sys, time
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1])
# R3 上限(分钟) × 1.5 容忍系数
LIMITS_MIN = {
    "intake": 15, "fetch-weights": 180, "fetching": 180,
    "install-env": 60, "installing": 60,
    "run-and-repair": 135, "running": 135,
    "verify": 30, "verifying": 30,
    "runbook": 30, "cleanup": 30,
}
TOLERANCE = 1.5
now = time.time()
changed = 0
for sf in root.glob("workspace/*/state.json"):
    try:
        s = json.loads(sf.read_text())
    except Exception:
        continue
    if s.get("status") != "running":
        continue
    phase = s.get("phase") or ""
    limit_min = LIMITS_MIN.get(phase)
    if not limit_min:
        continue
    ts_raw = s.get("updated_at") or s.get("started_at")
    if not ts_raw:
        continue
    try:
        ts = datetime.fromisoformat(ts_raw).timestamp()
    except Exception:
        continue
    age_min = (now - ts) / 60
    if age_min <= limit_min * TOLERANCE:
        continue
    s["status"] = "paused_in_progress"
    s["wallclock_enforced_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    s["wallclock_note"] = (
        f"R3 enforcement: phase={phase} status=running 已 {age_min:.0f}min "
        f"> 上限 {limit_min}min×{TOLERANCE},强制转 paused_in_progress(未 kill 任何进程)"
    )
    sf.write_text(json.dumps(s, ensure_ascii=False, indent=2))
    print(f"enforced: {sf.parent.name} phase={phase} stale {age_min:.0f}min → paused_in_progress")
    changed += 1
print(f"=== enforce-wallclock: {changed} state(s) updated ===")
PY
