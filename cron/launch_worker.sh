#!/bin/bash
# 通用 worker 启动器(对齐 ai-intel-deploy baseline 姿势)
#
# ⚠️ 所有部署(/auto-deploy, /auto-recover, /auto-daily 等)都必须经此脚本启动,
# 而非交互式手动 session。原因:
#   1. 此脚本输出 harness.stdout.ndjson(--output-format stream-json --verbose),
#      交互式 session 只产 transcript.jsonl(格式不同,cleanup G2 需额外兼容)
#   2. 此脚本负责 hook_state 初始化 / 缓存隔离 / 僵尸清理 / PID 管理,
#      交互式 session 不走这套,导致 R1/R4/R6 等规则无 hook 执行
#   3. 此脚本写 worker.pid + haha.pid + cron.status,交互式 session 不写,
#      下游 cleanup/cron 依赖这些文件判断进程状态
# 详见 Fix: 2026-05-29-g2-trace-format-flexible-fix
#
# 用法:
#   bash cron/launch_worker.sh "<prompt>" "<log_dir>" [<slug>]
#
# 例:
#   bash cron/launch_worker.sh \
#     "请使用 auto-deploy skill 部署 https://github.com/tencent-ailab/SongGeneration (slug=song-generation)" \
#     /root/ai-auto-harness/runs/manual-songgen-$(date +%s) \
#     song-generation
#
# 第 3 参数 slug 可选:若提供,会写入 hook_state.own_slug,让 PostToolUse hook 做 R1
# workspace 隔离检测(任何访问其他 workspace 都会触发 warning 注入)。
#
# 启动 flags(经 smoke test + SongGen run2 实测验证):
#   IS_SANDBOX=1                    必须,让 dangerously-skip-permissions 在 root 下可用
#   --dangerously-skip-permissions  workspace 内全权
#   --output-format stream-json     ndjson 事件流
#   --verbose                       每事件独立一行
#   --settings ...                  权限白名单 + MCP scan + PostToolUse hook
#   --mcp-config ...                项目级 MCP runtime 配置(不读 /root/.claude)
#   --append-system-prompt          R1/R4/R5/R6/R9 硬规则反复强调(skill prompt 不够硬)
#   (不用 --bare,会跳过 hooks/skills)
set -e

PROMPT="${1:-}"
LOG_DIR="${2:-}"
SLUG="${3:-}"  # 可选,用于 PostToolUse hook 做 workspace 隔离检测

if [ -z "$PROMPT" ] || [ -z "$LOG_DIR" ]; then
    echo "usage: $0 '<prompt>' '<log_dir>' [<slug>]"
    exit 1
fi

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
CLAUDE_HAHA_BIN="${CLAUDE_HAHA_BIN:-$HARNESS_ROOT/bin/claude-haha}"
CLAUDE_CONFIG_DIR="${CLAUDE_HAHA_CONFIG_DIR:-$HARNESS_ROOT/.claude-haha}"

cd "$HARNESS_ROOT"
[ -f .env ] && set -a && source .env && set +a

mkdir -p "$LOG_DIR"

# ============ run-id 注册 + hook_state 初始化(R1/R4 hook 用)============
RUN_ID=$(basename "$LOG_DIR")
echo "$RUN_ID" > "$HARNESS_ROOT/runs/.current_run_id"
# 🔴 导出给 claude-haha → SessionStart/PostToolUse hook 子进程继承,作为权威 run-id。
# SessionStart hook 会复用它(而非自造新 id 覆盖 .current_run_id),
# 否则 hook 把 transcript/纪律计数写进孤儿目录,本 run 目录永远 0 计数。
# (Fix: 2026-06-02-hook-runid-clobber-fix)
export AI_HARNESS_RUN_ID="$RUN_ID"
python3 - "$LOG_DIR/.hook_state.json" "$SLUG" <<'PYEOF'
import json, sys, time
state_path, slug = sys.argv[1], sys.argv[2]
with open(state_path, "w") as f:
    json.dump({
        "own_slug": slug,
        "own_pids": [],
        "bash_count": 0,
        "poll_count": 0,
        "task_called": 0,
        "sleep_streak": 0,
        "last_cmd": "",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }, f)
PYEOF

# meta.json
PROMPT_JSON=$(echo "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')
cat > "$LOG_DIR/meta.json" <<JSON
{
  "started_at": "$(date -Iseconds)",
  "run_id": "$RUN_ID",
  "slug": "$SLUG",
  "prompt": $PROMPT_JSON
}
JSON

# ============ 缓存隔离(env-level 强制) ============
ISOLATED_CACHE="${ISOLATED_CACHE_DIR:-$LOG_DIR/.cache}"
mkdir -p "$ISOLATED_CACHE"/{huggingface,torch,pip,xdg}
export HF_HOME="$ISOLATED_CACHE/huggingface"
export HF_HUB_CACHE="$ISOLATED_CACHE/huggingface"
export TRANSFORMERS_CACHE="$ISOLATED_CACHE/huggingface"
export TORCH_HOME="$ISOLATED_CACHE/torch"
export PIP_CACHE_DIR="$ISOLATED_CACHE/pip"
export XDG_CACHE_HOME="$ISOLATED_CACHE/xdg"
if [ -n "${HF_TOKEN:-}" ]; then
  export HF_TOKEN
fi
echo "isolated cache: $ISOLATED_CACHE" >> "$LOG_DIR/meta.json"

# ============ 代理环境 HF 下载优化(避免代理 503 Too many open connections) ============
# Fix: 2026-06-08-proxy-hf-download-503-fix
# 根因:公司 HTTP 代理连接池有限,Xet 多连接打爆代理 → 503。
# 解法:禁 Xet(它起多个并发连接) + 限 HF 下载并发连接数,走代理但不打爆。
# 注:本机无直连外网能力(Errno 101 Network is unreachable),不能 unset proxy 或 no_proxy。
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_CONCURRENCY="${HF_HUB_DOWNLOAD_CONCURRENCY:-2}"
echo "HF download: XET=disabled CONCURRENCY=$HF_HUB_DOWNLOAD_CONCURRENCY (proxy-safe)" >> "$LOG_DIR/meta.json"

# ============ 启动前清理:扫旧的僵尸 worker / 残留 bg 进程 ============
# 用户报反复僵尸 [bun] <defunct>(run2 / run1 多次留尸).
# 这里只清"明确死了"的:对每个 runs/<run-id>/worker.pid,kill -0 不通 → 找它的子进程清理.
# 不杀活的 — 用户可能有别的 run 在跑.
python3 - <<'PYEOF' >> "$LOG_DIR/meta.json" 2>&1 || true
import os, pathlib, signal
import subprocess
runs = pathlib.Path("/root/ai-auto-harness/runs")
cleaned = []
for run_dir in runs.glob("*/worker.pid"):
    try:
        pid = int(run_dir.read_text().strip())
    except Exception:
        continue
    # 自己不要清自己(虽然此时 worker.pid 还没写,但提前防御)
    if pid == os.getpid():
        continue
    # PID 还活着 → 跳过
    try:
        os.kill(pid, 0)
        continue
    except OSError:
        pass
    # PID 死了:看看 .cache/*.pid 有没有它起的 bg 进程
    cache_dir = run_dir.parent / ".cache"
    if not cache_dir.exists():
        cache_dir = run_dir.parent.parent / "workspace" / run_dir.parent.name.replace("songgen-e2e-", "") / ".cache"
    if cache_dir.exists():
        for pf in cache_dir.glob("*.pid"):
            try:
                child_pid = int(pf.read_text().strip())
                os.kill(child_pid, 0)
                os.kill(child_pid, signal.SIGTERM)
                cleaned.append(f"{run_dir.parent.name}: killed orphan {child_pid}")
            except Exception:
                pass
# 不输出到 meta.json 主体(JSON 已闭合),日志另存
if cleaned:
    with open("/root/ai-auto-harness/runs/.last_cleanup.log", "a") as f:
        import time
        f.write(f"=== {time.strftime('%Y-%m-%dT%H:%M:%S')} {os.getpid()} ===\n")
        for c in cleaned:
            f.write(c + "\n")
PYEOF

# ============ 僵尸/孤儿 hf 进程审计(P2-11)============
# 用户报 17 个 <defunct> hf 进程从 May21 残留。
# 🔴 保守边界(守 R1 + R-HO-1):
#   - 真僵尸(state Z 且 PPID==1,父已死)→ 已被 init 自动收割,这里只**记录**计数
#   - 活着的 `hf download`(含 setsid nohup PPID==1 的)→ **绝不杀**:那是 fetch-weights
#     合法的跨 cron 接续设计(R4.4),也可能是用户/别的 run 的下载
#   - 只清「上面 dead-worker 清理段已确认死亡的 worker 名下、且在其 .cache/*.pid 里的」进程
#     (该逻辑已在上一个 python 块完成)。本块**只报告**,给人决策,不做破坏性 kill。
python3 - <<'PYEOF' >> "/root/ai-auto-harness/runs/.last_cleanup.log" 2>&1 || true
import subprocess, time
try:
    out = subprocess.run(["ps", "-eo", "pid,ppid,stat,etimes,args"],
                         capture_output=True, text=True, timeout=10).stdout
except Exception:
    out = ""
zombie_hf = []        # 真僵尸 hf
orphan_live_hf = []   # 活的 PPID==1 hf download(legit setsid resume，只报告不杀)
for ln in out.splitlines()[1:]:
    parts = ln.split(None, 4)
    if len(parts) < 5:
        continue
    pid, ppid, stat, etimes, args = parts
    if "hf download" not in args and not (args.startswith("hf ") or "/hf " in args):
        continue
    if stat.startswith("Z"):
        zombie_hf.append((pid, ppid, etimes))
    elif ppid == "1":
        orphan_live_hf.append((pid, etimes, args[:80]))
if zombie_hf or orphan_live_hf:
    print(f"--- hf process audit {time.strftime('%Y-%m-%dT%H:%M:%S')} ---")
    if zombie_hf:
        print(f"  defunct(Z) hf x{len(zombie_hf)}: {zombie_hf[:10]} (init 会自动收割,无需手动)")
    if orphan_live_hf:
        print(f"  live PPID=1 hf download x{len(orphan_live_hf)}(可能是合法跨 cron 接续,**未杀**,人工核实):")
        for p in orphan_live_hf[:10]:
            print(f"    pid={p[0]} etimes={p[1]}s {p[2]}")
PYEOF

# ============ trap: worker 退出时清理 bg 子进程 ============
WORKER_PID_FILE="$LOG_DIR/worker.pid"
echo "$$" > "$WORKER_PID_FILE"

cleanup() {
    local code=$?
    # 杀 launch_worker.sh 起的所有子进程(claude-haha + 它派生的)
    # 但不杀已经 disowned 的 setsid nohup 进程(那些是合法跨 cron 接续设计)
    if [ -n "${HAHA_PID:-}" ]; then
        kill -TERM "$HAHA_PID" 2>/dev/null || true
    fi
    # 写一行结束记录
    echo "{\"exit\":$code,\"ended_at\":\"$(date -Iseconds)\"}" > "$LOG_DIR/cron.status"
    exit $code
}
trap cleanup EXIT INT TERM

# ============ 启动 claude-haha worker ============
# --append-system-prompt 加 R1-R9 浓缩版,反复强调
APPEND_PROMPT=$(cat <<'PROMPT_EOF'

# 🔴 Harness 硬规则(违反会被 PostToolUse hook 实时 warn,并落 transcript)

**R1 workspace 隔离**:只能动 workspace/<own-slug>/ — 严禁读/写/du/tail 其他 workspace;严禁 kill 不在 $WORKSPACE/.cache/*.pid 里的 PID(那是别人 run / 用户训练)

**R4 sleep 治理**:
- 单次 sleep ≤ 60s
- 连续 sleep 绝对禁(上一 turn 是 sleep,这一 turn 不许)
- poll 类操作累计 ≤ 8 turn,超过即 paused_in_progress return 让 cron 接续
- 长任务用 `setsid nohup ... &` 后台 + 记 PID 到 $WORKSPACE/.cache/*.pid,LLM 不守

**R5 串行带宽**:fetch-weights 完全 done 才进 install-env;fetch 还在 bg 跑时不许启动 pip install

**R6 pip**:严禁 `--no-cache-dir`(launch_worker 已 env-level 设 PIP_CACHE_DIR)

**R9 主 agent 职责**:主 agent 只做 4 件事 — 路由 / 状态机 / Task() dispatch / 写报告。git clone / hf download / pip install / python -m ... 这些**全部**通过 Task(subagent_type="intake-agent"|"fetch-agent"|"install-agent"|"runner-agent"|"verify-agent") dispatch 给 SubAgent。

每个 SubAgent 进出必须 echo `=== PHASE_START phase=X slug=Y ts=... ===` 和 `=== PHASE_END phase=X slug=Y status=done ts=... ===`,monitor 靠这两行抓事件。

R1-R9 完整说明在 .claude/CLAUDE.md。违反会有 hook 实时 additionalContext 告警。
PROMPT_EOF
)

CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
IS_SANDBOX=1 \
AI_HARNESS_RUN_ID="$RUN_ID" \
HF_HOME="$HF_HOME" \
HF_HUB_CACHE="$HF_HUB_CACHE" \
TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
TORCH_HOME="$TORCH_HOME" \
PIP_CACHE_DIR="$PIP_CACHE_DIR" \
XDG_CACHE_HOME="$XDG_CACHE_HOME" \
HF_TOKEN="${HF_TOKEN:-}" \
"$CLAUDE_HAHA_BIN" \
    -p "$PROMPT" \
    --append-system-prompt "$APPEND_PROMPT" \
    --output-format stream-json \
    --verbose \
    --dangerously-skip-permissions \
    --setting-sources user,project,local \
    --mcp-config "$HARNESS_ROOT/.mcp.json" \
    --settings "$HARNESS_ROOT/.claude/settings.json" \
    > "$LOG_DIR/harness.stdout.ndjson" \
    2> "$LOG_DIR/harness.stderr.log" &
HAHA_PID=$!
echo "$HAHA_PID" > "$LOG_DIR/haha.pid"

# 等 claude-haha 结束
wait "$HAHA_PID"
RET=$?
HAHA_PID=""  # 清空,避免 trap cleanup 重复 kill

# 跑完落 trajectory.json(从 ndjson 抽关键事件)
python3 -c "
import json, pathlib
nd = pathlib.Path('$LOG_DIR/harness.stdout.ndjson')
out = pathlib.Path('$LOG_DIR/trajectory.json')
events = []
for line in nd.read_text().splitlines() if nd.exists() else []:
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue
    typ = d.get('type')
    if typ == 'assistant':
        msg = d.get('message', {}).get('content', [])
        for c in msg if isinstance(msg, list) else []:
            if c.get('type') == 'tool_use':
                events.append({'type':'tool_use', 'name':c.get('name'),
                               'input_preview': str(c.get('input',{}))[:200]})
            elif c.get('type') == 'text':
                txt = c.get('text','')
                if txt.strip():
                    events.append({'type':'text', 'preview':txt[:300]})
    elif typ == 'result':
        events.append({'type':'result', 'subtype':d.get('subtype'),
                       'duration_ms':d.get('duration_ms'),
                       'cost_usd':d.get('total_cost_usd'),
                       'num_turns':d.get('num_turns')})
out.write_text(json.dumps(events, ensure_ascii=False, indent=2))
print(f'trajectory.json: {len(events)} events written')
" 2>>"$LOG_DIR/harness.stderr.log" || true

# 事后纪律审计(R9/R4/R1)— 解析 ndjson 产 discipline-report.json。
# 与 PostToolUse hook 互补:hook 是 mid-run advisory,这里是 worker 退出后的兜底审计。
# (Fix: 2026-06-02-hook-runid-clobber-fix)
bash "$HARNESS_ROOT/scripts/validate-run-discipline.sh" "$LOG_DIR/harness.stdout.ndjson" "$SLUG" \
    >> "$LOG_DIR/meta.json.discipline" 2>&1 || true

# trap cleanup 会写 cron.status
exit $RET
