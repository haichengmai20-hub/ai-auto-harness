#!/usr/bin/env bash
# reconcile-sentinels.sh — handoff sentinel 与真实进程状态对账
#
# 问题(Fix: 2026-06-10-external-review-sentinel-wallclock-runs-fix):
#   sentinel 的终态由 setsid wrapper 退出时自写(R10),但三种情况会漏写:
#   (a) agent 自创 wrapper 丢掉 sentinel trap(scail 实测)
#   (b) wrapper 被 SIGKILL,trap 不执行
#   (c) 容器 PID 1 是 `tail -f /dev/null` 不收尸,僵尸进程 kill -0 仍"活"
#   → sentinel 永远停在 status=running,下次 cron 误判"还在跑"。
#
# 行为(保守,只写 sentinel,绝不 kill / 不删文件):
#   对每个 status=running 的 sentinel:
#   - PID 不存在 或 是 Z(僵尸) → status=dead + bytes=du 实测 + reconciled_at
#   - exit code 能从 log 尾部 grep 到则回填
#
# Usage: bash scripts/reconcile-sentinels.sh [HARNESS_ROOT]
set -uo pipefail
HARNESS_ROOT="${1:-/root/ai-auto-harness}"

python3 - "$HARNESS_ROOT" <<'PY'
import json, os, pathlib, re, subprocess, sys, time

root = pathlib.Path(sys.argv[1])
changed = 0
for sentinel in root.glob("workspace/*/.cache/handoff/*.json"):
    try:
        data = json.loads(sentinel.read_text())
    except Exception:
        continue
    if data.get("status") != "running":
        continue
    pid = data.get("pid")
    alive = False
    if pid:
        try:
            stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
            # stat[2] 是进程状态;Z = 僵尸 = 实际已死(PID1 不收尸场景)
            alive = stat[2] != "Z"
        except Exception:
            alive = False
    if alive:
        continue

    # 已死 → 写终态。bytes 用 local_dir 实测;exit_code 尽力从 log 尾部找
    local_dir = data.get("local_dir") or ""
    bytes_actual = data.get("bytes", 0)
    if local_dir and os.path.isdir(local_dir):
        try:
            out = subprocess.run(["du", "-sb", local_dir], capture_output=True, text=True, timeout=120)
            bytes_actual = int(out.stdout.split()[0])
        except Exception:
            pass
    exit_code = data.get("exit_code")
    log_path = data.get("log_path") or ""
    if exit_code is None and log_path and os.path.isfile(log_path):
        try:
            tail = subprocess.run(["tail", "-c", "4000", log_path], capture_output=True, text=True).stdout
            m = re.findall(r"exited with code (\d+)", tail)
            if m:
                exit_code = int(m[-1])
        except Exception:
            pass

    data.update({
        "status": "dead",
        "exit_code": exit_code,
        "bytes": bytes_actual,
        "completed_at": data.get("completed_at"),
        "reconciled_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "reconcile_note": "PID 已死/僵尸但 sentinel 仍 running,由 reconcile-sentinels.sh 对账写入;exit_code 来自 log 尾部(可能为 null)",
    })
    sentinel.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    print(f"reconciled: {sentinel} pid={pid} exit_code={exit_code} bytes={bytes_actual}")
    changed += 1

print(f"=== reconcile-sentinels: {changed} sentinel(s) updated ===")
PY

# ---- service 孤儿回收(F14 安全网,fix 2026-06-16-service-type-inference)----
# preflight 时机:flock+N=1 保证无活跃 run → 任何 status=running 的 service sentinel
# 且其登记 PID 仍活 = 孤儿(创建它的上个 run 已死)。R1:只杀该 workspace .cache/*.pid 登记的 PID。
WS_GLOB="${AI_HARNESS_WORKSPACE_GLOB:-/root/ai-auto-harness/workspace}"
for sent in "$WS_GLOB"/*/.cache/handoff/service-*.json; do
  [ -f "$sent" ] || continue
  [ "$(jq -r '.status // empty' "$sent" 2>/dev/null)" = running ] || continue
  sws=$(jq -r '.workspace // empty' "$sent" 2>/dev/null)
  spid=$(jq -r '.pid // empty' "$sent" 2>/dev/null)
  [ -z "$sws" ] || [ -z "$spid" ] && continue
  # R1 守卫:PID 必须登记在该 workspace 的 .cache/*.pid 里才动
  REGISTERED=false
  for pf in "$sws"/.cache/*.pid; do
    [ -f "$pf" ] || continue
    grep -qx "$spid" "$pf" 2>/dev/null && { REGISTERED=true; break; }
  done
  if [ "$REGISTERED" != true ]; then
    echo "[reconcile] service-sentinel pid=$spid 未登记在 $sws/.cache/*.pid,按 R1 不杀,只标 stopped"
  else
    st=$(awk '{print $3}' "/proc/$spid/stat" 2>/dev/null)
    if [ -n "$st" ] && [ "$st" != Z ]; then
      echo "[reconcile] 孤儿 service pid=$spid (ws=$sws) → kill"
      kill "$spid" 2>/dev/null || true; sleep 1; kill -0 "$spid" 2>/dev/null && kill -9 "$spid" 2>/dev/null || true
    fi
  fi
  tmp=$(mktemp); jq '.status="stopped" | .reconciled_at="'"$(date -Iseconds)"'"' "$sent" > "$tmp" 2>/dev/null && mv "$tmp" "$sent" || true
done
