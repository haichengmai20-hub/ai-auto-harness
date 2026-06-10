#!/bin/bash
# PostToolUse hook —
#  1. transcript.jsonl 落盘
#  2. R1/R4/R6/R9 硬约束检测 → hookSpecificOutput.additionalContext 注入回 LLM
#
# 输入 (stdin): {hook_event_name, tool_name, tool_input, ...}
# 输出 (stdout): JSON {hookSpecificOutput: {hookEventName:"PostToolUse", additionalContext:"..."}}
#                若无违规,无输出
#
# 用 python3 而非 jq(系统未装 jq;python3 是 stdlib 一部分)

set -u
HARNESS_ROOT="/root/ai-auto-harness"
# run 目录解析(Fix: 2026-06-02-hook-runid-clobber + 2026-06-08-run-dir-into-workspace):
#   1) $AI_HARNESS_RUN_DIR — launcher 注入的**完整路径**(权威,可指向 workspace/<slug>/runs/<id>)
#   2) $AI_HARNESS_RUN_ID  — 旧 launcher 只注入 id → 全局 runs/$id(向后兼容,不破在飞的 worker)
#   3) .current_run_id 文件 — 交互式 session 自己写的指针
if [ -n "${AI_HARNESS_RUN_DIR:-}" ]; then
    RUN_DIR="$AI_HARNESS_RUN_DIR"
else
    RUN_ID="${AI_HARNESS_RUN_ID:-$(cat "$HARNESS_ROOT/runs/.current_run_id" 2>/dev/null || echo "unknown")}"
    RUN_DIR="$HARNESS_ROOT/runs/$RUN_ID"
fi
mkdir -p "$RUN_DIR"

EVENT=$(cat 2>/dev/null || echo '{}')

# python3 一把梭:transcript 落盘 + 规则检测 + 状态机更新 + 输出 additionalContext
python3 - "$RUN_DIR" "$HARNESS_ROOT" <<'PYEOF' "$EVENT"
import json, os, re, sys, time, pathlib

RUN_DIR = pathlib.Path(sys.argv[1])
HARNESS_ROOT = pathlib.Path(sys.argv[2])
event_raw = sys.argv[3] if len(sys.argv) > 3 else "{}"
STATE_PATH = RUN_DIR / ".hook_state.json"
TRANSCRIPT = RUN_DIR / "transcript.jsonl"

ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")

# 1) transcript 落盘(任何情况)
try:
    evt = json.loads(event_raw) if event_raw.strip() else {}
except Exception:
    evt = {"event_raw_truncated": event_raw[:500]}
with TRANSCRIPT.open("a") as f:
    f.write(json.dumps({"ts": ts, "event": evt}, ensure_ascii=False) + "\n")

# 2) 抽 tool_name / cmd
tool_name = evt.get("tool_name") or (evt.get("tool_use", {}) or {}).get("name") or ""
tool_input = evt.get("tool_input") or (evt.get("tool_use", {}) or {}).get("input") or {}
cmd = tool_input.get("command", "") if isinstance(tool_input, dict) else ""

# 3) 加载 hook_state
if STATE_PATH.exists():
    try:
        state = json.loads(STATE_PATH.read_text())
    except Exception:
        state = {}
else:
    state = {}

# 4) Task() 调用 → 计数 + 提前 return
if tool_name == "Task":
    state["task_called"] = state.get("task_called", 0) + 1
    STATE_PATH.write_text(json.dumps(state))
    sys.exit(0)

# 5) 非 Bash 工具 → 不检测,直接 exit
if tool_name != "Bash" or not cmd:
    sys.exit(0)

prev_cmd     = state.get("last_cmd", "")
own_slug     = state.get("own_slug", "")
sleep_streak = state.get("sleep_streak", 0)
bash_count   = state.get("bash_count", 0) + 1
poll_count   = state.get("poll_count", 0)
task_called  = state.get("task_called", 0)
own_pids_set = set(map(str, state.get("own_pids", [])))

warnings = []

# === R4.1: 单次 sleep > 60s ===
sleep_secs = [int(s) for s in re.findall(r'\bsleep\s+(\d+)', cmd)]
has_sleep = bool(sleep_secs)
max_sleep = max(sleep_secs) if sleep_secs else 0
if max_sleep > 60:
    warnings.append(
        f"🔴 R4.1 VIOLATION: 单次 sleep {max_sleep}s > 60s 上限。本次浪费一个完整 LLM turn "
        f"(full-context token 重发,~$0.05-0.15)。改用 ≤60s 或后台化(setsid nohup ... &)。"
    )

# === R4.2: 连续 sleep ===
prev_has_sleep = bool(re.search(r'\bsleep\s+\d+', prev_cmd))
if has_sleep and prev_has_sleep:
    sleep_streak += 1
    warnings.append(
        f"🔴 R4.2 VIOLATION: 连续 sleep 第 {sleep_streak} 次(本次 sleep {max_sleep}s + 上次也 sleep)。"
        "立刻停止 sleep loop。改做:(a) 真有信息量的 Bash(tail -50 / ps aux / du -sb);"
        "(b) 写 paused_in_progress=true 到 state.json 并 return,让 cron 接续 — 比硬等划算 1000 倍。"
    )
elif has_sleep:
    sleep_streak = 1
else:
    sleep_streak = 0

# === R4.5 前置: PHASE_START 标记 → poll_count 按阶段重置 ===
# (Fix: 2026-05-29-poll-count-accumulate-cross-phase — poll 上限是"每阶段 8 次",
#  不是全 run 累计;否则 fetch 用掉 7 次后 install 阶段 poll 1 次就误报)
if "PHASE_START" in cmd:
    poll_count = 0

# === R4.5: poll 类操作累计 > 8(本阶段内) ===
if re.search(r'\b(tail|sleep|kill\s+-0|du\s+-s|ps\s+aux)\b', cmd):
    poll_count += 1
    if poll_count > 8:
        warnings.append(
            f"🔴 R4.5 VIOLATION: poll 类操作(tail/sleep/kill -0/du -s/ps aux)本阶段累计 {poll_count} 次 > 8 上限。"
            f"立刻 paused_in_progress return,让主 agent / cron 接续(每多 poll 一次烧 ~$0.10,cron 接续 $0)。"
        )

# === R1: kill 命令的 PID owner check ===
kill_segments = re.findall(r'\bkill\b[^|;&\n]*', cmd)
killed_pids = set()
for seg in kill_segments:
    for p in re.findall(r'\b(\d{3,})\b', seg):
        killed_pids.add(p)
if killed_pids:
    # 合法 PID = workspace/<own_slug>/.cache/*.pid + hook_state.own_pids
    legit_pids = set(own_pids_set)
    if own_slug:
        ws_cache = HARNESS_ROOT / "workspace" / own_slug / ".cache"
        if ws_cache.exists():
            for p in ws_cache.glob("*.pid"):
                try:
                    legit_pids.add(p.read_text().strip())
                except Exception:
                    pass
    foreign = killed_pids - legit_pids
    if foreign:
        warnings.append(
            f"🔴 R1 VIOLATION: kill 了 PID {sorted(foreign)} 但这些不在本 run 的合法 PID 列表"
            f"(workspace/{own_slug}/.cache/*.pid)。**那是别人 run / 用户训练 / 系统进程**,严禁动。"
        )

# === R1.2: 跨 workspace 路径访问 ===
if own_slug:
    pattern = re.compile(rf'{re.escape(str(HARNESS_ROOT))}/workspace/([a-zA-Z0-9_-]+)')
    referenced = set(pattern.findall(cmd))
    referenced.discard(own_slug)
    if referenced:
        warnings.append(
            f"🔴 R1 VIOLATION: 命令访问了其他 workspace: {sorted(referenced)}。"
            f"本 run 只能动 workspace/{own_slug}/。"
        )

# === R6: --no-cache-dir ===
if "--no-cache-dir" in cmd:
    warnings.append(
        "🟡 R6 VIOLATION: pip install --no-cache-dir。launch_worker.sh 已 env-level 设 "
        "PIP_CACHE_DIR=隔离目录,加 --no-cache-dir 反而每次重下 wheel + 抢带宽。去掉这个 flag。"
    )

# === R9: 主 agent 干 SubAgent 活 ===
if bash_count > 20 and task_called == 0:
    warnings.append(
        f"🔴 R9 VIOLATION: 已 {bash_count} 次 Bash 但 0 次 Task()。立即停止内联执行,下一 turn 必须 "
        "dispatch Task(subagent_type=\"intake-agent\"|\"fetch-agent\"|\"install-agent\"|"
        "\"runner-agent\"|\"verify-agent\"|\"runbook-agent\"|\"cleanup-agent\")。"
        "继续主 agent 自己 bash 会导致 verify.json/runbook.json/cleanup.json 缺失。"
    )
elif bash_count > 10 and task_called == 0:
    warnings.append(
        f"🔴 R9 VIOLATION: 已 {bash_count} 次 Bash 但 0 次 Task()。主 agent 只能做路由、状态机推进、"
        "Task() dispatch 和报告聚合。各 phase 必须交给 SubAgent,否则 Phase artifacts 会缺失。"
    )
elif bash_count > 5 and task_called == 0:
    if re.search(r'\b(git\s+clone|hf\s+download|huggingface-cli\s+download|pip\s+install)\b', cmd):
        warnings.append(
            f"🟡 R9 SUSPECTED: 已 {bash_count} 次 Bash 但 0 次 Task() — 你可能是主 agent 在自己干 "
            "SubAgent 的活。git clone / hf download / pip install 应通过 "
            "Task(subagent_type=\"intake-agent\"|\"fetch-agent\"|\"install-agent\") dispatch。"
        )

# 6) 更新 hook_state
state.update({
    "last_cmd": cmd,
    "sleep_streak": sleep_streak,
    "own_slug": own_slug,
    "bash_count": bash_count,
    "poll_count": poll_count,
    "task_called": task_called,
    "updated_at": ts,
})
STATE_PATH.write_text(json.dumps(state, ensure_ascii=False))

# 7) 有违规 → 输出 additionalContext
if warnings:
    msg = (
        "Harness 硬约束告警(PostToolUse hook 自动检测,违规已落盘):\n\n"
        + "\n\n".join(warnings)
        + "\n\n详见 /root/ai-auto-harness/.claude/CLAUDE.md R1-R9 段。"
        + "这些规则有真实事故为证(SongGen run2 烧 $20.70 + 270min sleep)。请立刻调整下一 turn 行为。"
    )
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": msg,
        }
    }, ensure_ascii=False))

sys.exit(0)
PYEOF
