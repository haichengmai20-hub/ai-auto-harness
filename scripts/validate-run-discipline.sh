#!/bin/bash
# validate-run-discipline.sh — 事后(post-run)纪律审计
#
# PostToolUse hook 是 mid-run advisory(只注入提醒,不阻断,且需 hook 真触发)。
# 本脚本是**事后**审计:worker 退出后解析 runs/<id>/harness.stdout.ndjson,
# 统计 Bash/Task/sleep,检测 R9(主 agent 不 dispatch)/R4(sleep 滥用)/R1(跨 workspace),
# 产出 runs/<id>/discipline-report.json + 人读告警。与 hook 互补,即使 hook 漏触发也有兜底。
#
# (建立: Fix 2026-06-02-hook-runid-clobber-fix — 该 fix 发现 hook 写错目录,
#  此审计器确保纪律数据有第二来源,不依赖 hook 落点正确。)
#
# 用法:
#   bash scripts/validate-run-discipline.sh <run_id | path/to/harness.stdout.ndjson> [own_slug]
#
# 退出码:始终 0(advisory),违规写入 report 的 violations[] + stderr 告警。
set -u
HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
ARG="${1:-}"
OWN_SLUG="${2:-}"

if [ -z "$ARG" ]; then
    echo "usage: $0 <run_id | ndjson_path> [own_slug]" >&2
    exit 0
fi

# 解析 ndjson 路径 + run 目录
# 优先把 ARG 当文件路径(launch_worker 传完整 ndjson 路径,位置无关);
# 否则当 run_id,在 workspace/<slug>/runs/<id>(新)与全局 runs/<id>(legacy)两处查找。
# (Fix: 2026-06-08-run-dir-into-workspace)
if [ -f "$ARG" ]; then
    NDJSON="$ARG"
    RUN_DIR="$(dirname "$ARG")"
else
    RUN_DIR="$HARNESS_ROOT/runs/$ARG"
    if [ ! -f "$RUN_DIR/harness.stdout.ndjson" ]; then
        WS_MATCH="$(ls -d "$HARNESS_ROOT"/workspace/*/runs/"$ARG" 2>/dev/null | head -1)"
        [ -n "$WS_MATCH" ] && RUN_DIR="$WS_MATCH"
    fi
    NDJSON="$RUN_DIR/harness.stdout.ndjson"
fi

if [ ! -f "$NDJSON" ]; then
    echo "validate-run-discipline: ndjson not found: $NDJSON" >&2
    exit 0
fi

# own_slug 兜底:从 hook_state / meta.json 取
if [ -z "$OWN_SLUG" ]; then
    OWN_SLUG="$(python3 -c "import json,sys
for p in ['$RUN_DIR/.hook_state.json','$RUN_DIR/meta.json']:
    try:
        d=json.load(open(p))
        v=d.get('own_slug') or d.get('slug')
        if v: print(v); break
    except Exception: pass" 2>/dev/null)"
fi

REPORT="$RUN_DIR/discipline-report.json"

python3 - "$NDJSON" "$OWN_SLUG" "$REPORT" "$HARNESS_ROOT" <<'PY'
import json, sys, re

ndjson, own_slug, report_path, harness_root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

bash = task = 0
names = {}
sleeps = []            # 每次含 sleep 的 Bash 的最大秒数
max_sleep = 0
max_sleep_streak = 0
cur_streak = 0
prev_sleep = False
poll_count = 0         # tail/ps/du/kill -0/sleep 类
cross_ws = set()       # 访问到的其他 workspace slug

POLL_RE = re.compile(r'\b(tail|sleep|kill\s+-0|du\s+-s|ps\s+aux)\b')
SLEEP_RE = re.compile(r'\bsleep\s+(\d+)')
WS_RE = re.compile(re.escape(harness_root) + r'/workspace/([a-zA-Z0-9_-]+)')

for line in open(ndjson, errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "assistant":
        continue
    for c in d.get("message", {}).get("content", []) or []:
        if c.get("type") != "tool_use":
            continue
        n = c.get("name", "")
        names[n] = names.get(n, 0) + 1
        if n == "Task":
            task += 1
        if n == "Bash":
            bash += 1
            cmd = (c.get("input", {}) or {}).get("command", "") or ""
            ss = [int(x) for x in SLEEP_RE.findall(cmd)]
            if ss:
                m = max(ss); sleeps.append(m); max_sleep = max(max_sleep, m)
                cur_streak = cur_streak + 1 if prev_sleep else 1
                max_sleep_streak = max(max_sleep_streak, cur_streak)
                prev_sleep = True
            else:
                prev_sleep = False
            if POLL_RE.search(cmd):
                poll_count += 1
            if own_slug:
                for s in WS_RE.findall(cmd):
                    if s != own_slug:
                        cross_ws.add(s)

violations = []
# R9: 主 agent 大量 Bash 但从不 Task() dispatch
if bash > 5 and task == 0:
    violations.append({
        "rule": "R9", "severity": "high",
        "detail": f"{bash} 次 Bash 但 0 次 Task() — 主 agent 在自己干 SubAgent 的活(应 dispatch)"
    })
# R4.1: 单次 sleep > 60s
if max_sleep > 60:
    violations.append({"rule": "R4.1", "severity": "medium",
                       "detail": f"单次 sleep {max_sleep}s > 60s 上限"})
# R4.2: 连续 sleep
if max_sleep_streak >= 2:
    violations.append({"rule": "R4.2", "severity": "high",
                       "detail": f"连续 sleep 最长 {max_sleep_streak} 次(sleep loop)"})
# R4.5: poll 累计 > 8
if poll_count > 8:
    violations.append({"rule": "R4.5", "severity": "medium",
                       "detail": f"poll 类操作累计 {poll_count} 次 > 8 上限"})
# R1: 跨 workspace 访问
if cross_ws:
    violations.append({"rule": "R1", "severity": "high",
                       "detail": f"Bash 访问了其他 workspace: {sorted(cross_ws)}"})

report = {
    "own_slug": own_slug or None,
    "tool_counts": dict(sorted(names.items(), key=lambda x: -x[1])),
    "bash_count": bash,
    "task_called": task,
    "sleep_count": len(sleeps),
    "sleep_secs": sleeps,
    "max_sleep": max_sleep,
    "max_sleep_streak": max_sleep_streak,
    "poll_count": poll_count,
    "cross_workspace": sorted(cross_ws),
    "violations": violations,
    "clean": len(violations) == 0,
}
with open(report_path, "w") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

# 人读输出
print(f"discipline: Bash={bash} Task={task} sleep={len(sleeps)}(max {max_sleep}s, streak {max_sleep_streak}) poll={poll_count}")
if violations:
    sys.stderr.write(f"⚠️  {len(violations)} 条纪律违规(详见 {report_path}):\n")
    for v in violations:
        sys.stderr.write(f"   🔴 {v['rule']} [{v['severity']}]: {v['detail']}\n")
else:
    print("✅ 无纪律违规")
PY

exit 0
