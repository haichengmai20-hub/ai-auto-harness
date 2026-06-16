# 服务型推理支持(entry_type=service)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ai-auto-harness 能部署「起后端服务 → 等就绪 → 调 API 推理 → 验产物 → 停服务」类项目(vLLM/Gradio/Flask 后端),CC 版优先。

**Architecture:** 三决策(spec):①真实推理往返(降级用 verify_level L0/L1);②intake 全包 service descriptor;③ephemeral within-run(必停、不跨 cron,孤儿靠 reconcile 兜底)。`start/wait-ready/stop` 三个**机械**动作抽进新脚本 `scripts/service-lifecycle.sh`(可单测),run-and-repair / verify SubAgent 调它;**infer + 修复**是 LLM 判断,留在 SKILL。**⚠️ 偏离 spec 文件清单:新增 `scripts/service-lifecycle.sh` 共享脚本(DRY + 可测),留 review。**

**Tech Stack:** bash(SKILL 内 LLM 指令 + 两个可测脚本)、jq、curl、`/proc/<pid>/stat` 判活。无 pytest;脚本用 fixture 自测,SKILL 改动用 `bash -n`/jq/grep 自检。

**维护方式(本项目 D1-D7):** 先 fix.md → 改文件加 ChangeLog → commit(`[fix]|[skill]|[spec]` 格式)→ 回填 hash → 更新 fixes/README + master plan。

---

## File Structure

| 文件 | 责任 | 任务 |
|---|---|---|
| `docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md` | fix 记录(D1 先写) | T1 |
| `scripts/service-lifecycle.sh`(新) | 机械动作:`start`/`wait-ready`/`stop`,读 intake.json descriptor,登记 PID+sentinel | T2 |
| `tests/service-lifecycle/`(新,fixture) | T2 的 fixture 自测脚本 | T2 |
| `.claude/skills/intake/SKILL.md` | F13:entry_type 检测 + service descriptor + return schema | T3 |
| `.claude/skills/run-and-repair/SKILL.md` | F1+F4:service 分支(调 helper + LLM infer/修复 + 必停)+ run.json 字段 | T4 |
| `.claude/skills/verify/SKILL.md` | F11:service 分支 + verify_level L0/L1 + evidence | T5 |
| `.claude/skills/cleanup-deployed-workspace/SKILL.md` | F12:杀本 workspace 登记 PID(whitelist rm 前) | T6 |
| `scripts/reconcile-sentinels.sh` | 孤儿回收:preflight 杀掉 status=running 且 PID 活的 service sentinel | T7 |
| `docs/framework-issues-cc-complete.md` / `fixes/README.md` / master plan | 状态 + 索引 + 回填 | T8 |

依赖序:T1(fix) → T2(helper,被 T4/T5 调) → T3(schema,被 T4/T5/T6 读) → T4 → T5 → T6 → T7 → T8(治理收尾)。

---

## Task 1: 先写 fix.md(D1)

**Files:**
- Create: `docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md`

- [ ] **Step 1: 写 fix.md**

```markdown
# Fix: 服务型推理支持(entry_type=service)

**日期**: 2026-06-16
**严重度**: P0(最大架构缺口,服务型项目全挂)
**触发**: khala/vLLM/Gradio/Flask 类项目跑不通(只认 python3 script.py)
**Spec**: [2026-06-16-service-type-inference-design.md](../specs/2026-06-16-service-type-inference-design.md)
**关联**: framework-issues-cc-complete.md F1/F4/F11/F12/F13/F14

## 人话版
平台原来只会跑「一条命令出结果」的脚本。很多 AI 项目得先把后端服务起起来、等它就绪、再发请求拿结果、最后关掉。这次让四个阶段都认识「服务型」项目:intake 把启动/就绪/请求/停止四件事写清楚,run 真跑一遍往返,verify 独立再验一遍,cleanup/preflight 保证服务不会变成占着 GPU 的孤儿。

## 三决策(brainstorm)
1. 真实推理往返(降级 verify_level L0=仅就绪 / L1=真往返)
2. intake 全包 descriptor(run 只执行,请求错=普通修复轮)
3. ephemeral within-run(必停、不跨 cron;孤儿靠 reconcile 兜底)

## 影响范围
- 新增 `scripts/service-lifecycle.sh`(start/wait-ready/stop,可测)
- `.claude/skills/{intake,run-and-repair,verify,cleanup-deployed-workspace}/SKILL.md`
- `scripts/reconcile-sentinels.sh`(孤儿回收)

## 验证
见 spec「成功标准/验证」表 + 各任务 fixture。

## 状态
- [ ] T2 helper + fixture
- [ ] T3 intake / T4 run / T5 verify / T6 cleanup
- [ ] T7 reconcile 孤儿回收
- [ ] T8 治理 + 回填
- [ ] 实战:一个真实服务型项目走完 L1

## 修复结果
- **commit hash**: (待回填)
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md
git commit -m "[fix] 服务型推理支持 fix.md(先写,D1)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `scripts/service-lifecycle.sh`(机械动作,可测)

**Files:**
- Create: `scripts/service-lifecycle.sh`
- Test: `tests/service-lifecycle/run-tests.sh`

接口:`service-lifecycle.sh <start|wait-ready|stop> <workspace> [extra]`。读 `<workspace>/results/intake.json` 的 `.service`。

- [ ] **Step 1: 写 fixture 测试(先失败)**

Create `tests/service-lifecycle/run-tests.sh`:

```bash
#!/usr/bin/env bash
# service-lifecycle.sh fixture 测试。无 pytest,纯 bash 断言。
set -u
HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
LC="$HARNESS_ROOT/scripts/service-lifecycle.sh"
PASS=0; FAIL=0
ok(){ echo "ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkws(){ # $1=ready_type ; 造一个临时 workspace + intake.json
  local ws; ws=$(mktemp -d)
  mkdir -p "$ws/.cache/handoff" "$ws/results" "$ws/logs"
  if [ "$1" = log ]; then
    cat > "$ws/results/intake.json" <<JSON
{"entry_type":"service","service":{"start_cmd":"sleep 300","ready_signal":{"type":"log","pattern":"SERVER READY"},"stop_cmd":"","port":0,"output_path":"out.txt"}}
JSON
  else
    cat > "$ws/results/intake.json" <<JSON
{"entry_type":"service","service":{"start_cmd":"python3 -m http.server $2 --bind 127.0.0.1","ready_signal":{"type":"http","url":"http://127.0.0.1:$2/","expect_status":200},"stop_cmd":"","port":$2,"output_path":"out.txt"}}
JSON
  fi
  echo "$ws"
}

# T2.1 start 写 PID + sentinel + 进程活
WS=$(mkws log)
bash "$LC" start "$WS" >/dev/null 2>&1
PID=$(head -1 "$WS/.cache/backend.pid" 2>/dev/null)
{ [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; } && ok "start: 进程活+PID登记" || bad "start: 进程没起/没登记"
[ -f "$WS"/.cache/handoff/service-*.json ] && ok "start: 写了 sentinel" || bad "start: 没写 sentinel"

# T2.2 wait-ready(log 型):pattern 出现→exit 0
echo "xxx SERVER READY yyy" >> "$WS/logs/backend.log"
bash "$LC" wait-ready "$WS" 5 >/dev/null 2>&1 && ok "wait-ready(log): 命中→0" || bad "wait-ready(log): 命中没返回 0"

# T2.3 stop:进程死 + sentinel stopped
bash "$LC" stop "$WS" >/dev/null 2>&1
kill -0 "$PID" 2>/dev/null && bad "stop: 进程还活" || ok "stop: 进程已死"
grep -q '"status": *"stopped"' "$WS"/.cache/handoff/service-*.json 2>/dev/null && ok "stop: sentinel=stopped" || bad "stop: sentinel 没标 stopped"
rm -rf "$WS"

# T2.4 wait-ready 超时:pattern 不出现→exit 1
WS=$(mkws log); bash "$LC" start "$WS" >/dev/null 2>&1
if bash "$LC" wait-ready "$WS" 2 >/dev/null 2>&1; then bad "wait-ready: 该超时却返回 0"; else ok "wait-ready: 超时返回非 0"; fi
bash "$LC" stop "$WS" >/dev/null 2>&1; rm -rf "$WS"

# T2.5 wait-ready(http 型):真起 http.server 健康检查
PORT=$(( (RANDOM % 2000) + 23000 ))
WS=$(mkws http "$PORT"); export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
bash "$LC" start "$WS" >/dev/null 2>&1
bash "$LC" wait-ready "$WS" 10 >/dev/null 2>&1 && ok "wait-ready(http): 200→0" || bad "wait-ready(http): 健康检查没过"
bash "$LC" stop "$WS" >/dev/null 2>&1; rm -rf "$WS"

echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `chmod +x tests/service-lifecycle/run-tests.sh && bash tests/service-lifecycle/run-tests.sh`
Expected: FAIL(`service-lifecycle.sh` 不存在,所有断言失败)

- [ ] **Step 3: 写 `scripts/service-lifecycle.sh`**

```bash
#!/usr/bin/env bash
# 服务型项目生命周期机械动作:start / wait-ready / stop。
# 读 <workspace>/results/intake.json 的 .service。被 run-and-repair / verify SubAgent 调。
# ephemeral within-run:不跨 cron;sentinel 仅供孤儿回收(reconcile-sentinels.sh)。
set -u
ACTION="${1:-}"; WS="${2:-}"; EXTRA="${3:-}"
[ -z "$WS" ] && { echo "usage: service-lifecycle.sh <start|wait-ready|stop> <workspace> [timeout]" >&2; exit 2; }
INTAKE="$WS/results/intake.json"
LOG="$WS/logs/backend.log"
PIDFILE="$WS/.cache/backend.pid"
mkdir -p "$WS/.cache/handoff" "$WS/logs"
SENT="$WS/.cache/handoff/service-${AI_HARNESS_RUN_ID:-$RUN_ID}.json"

svc(){ jq -r ".service.$1 // empty" "$INTAKE" 2>/dev/null; }

case "$ACTION" in
  start)
    START_CMD=$(svc start_cmd)
    [ -z "$START_CMD" ] && { echo "no start_cmd in intake.json" >&2; exit 2; }
    nohup bash -c "$START_CMD" > "$LOG" 2>&1 &
    BPID=$!
    echo "$BPID" > "$PIDFILE"
    # 登记 launcher 派生子进程(若 start_cmd 是 wrapper)
    sleep 1
    pgrep -P "$BPID" >> "$PIDFILE" 2>/dev/null || true
    cat > "$SENT" <<JSON
{"phase":"service","status":"running","pid":$BPID,"run_id":"${AI_HARNESS_RUN_ID:-$RUN_ID}","workspace":"$WS","started_at":"$(date -Iseconds)","log_path":"$LOG"}
JSON
    echo "$BPID"
    ;;
  wait-ready)
    TIMEOUT="${EXTRA:-300}"; TYPE=$(svc 'ready_signal.type'); DEADLINE=$(( $(date +%s) + TIMEOUT ))
    INTERVAL=3
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if [ "$TYPE" = http ]; then
        URL=$(svc 'ready_signal.url'); WANT=$(svc 'ready_signal.expect_status'); WANT="${WANT:-200}"
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$URL" 2>/dev/null || echo 000)
        [ "$CODE" = "$WANT" ] && { echo "ready(http $CODE)"; exit 0; }
      else
        PAT=$(svc 'ready_signal.pattern')
        grep -qE "$PAT" "$LOG" 2>/dev/null && { echo "ready(log)"; exit 0; }
      fi
      # backend 崩了就别再等
      BPID=$(head -1 "$PIDFILE" 2>/dev/null)
      if [ -n "$BPID" ]; then
        ST=$(awk '{print $3}' "/proc/$BPID/stat" 2>/dev/null)
        { [ -z "$ST" ] || [ "$ST" = Z ]; } && { echo "backend died before ready" >&2; exit 3; }
      fi
      sleep "$INTERVAL"; [ "$INTERVAL" -lt 15 ] && INTERVAL=$((INTERVAL+3))   # R4.6 动态间隔(≤60s)
    done
    echo "wait-ready timeout after ${TIMEOUT}s" >&2; exit 1
    ;;
  stop)
    STOP_CMD=$(svc stop_cmd)
    [ -n "$STOP_CMD" ] && bash -c "$STOP_CMD" >> "$LOG" 2>&1 || true
    if [ -f "$PIDFILE" ]; then
      while read -r pid; do
        [ -z "$pid" ] && continue
        ST=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
        { [ -z "$ST" ] || [ "$ST" = Z ]; } && continue   # 已死/僵尸(kill -0 会误判活)
        kill "$pid" 2>/dev/null || true
      done < "$PIDFILE"
      sleep 2
      while read -r pid; do
        [ -z "$pid" ] && continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      done < "$PIDFILE"
      rm -f "$PIDFILE"
    fi
    [ -f "$SENT" ] && { tmp=$(mktemp); jq '.status="stopped" | .stopped_at="'"$(date -Iseconds)"'"' "$SENT" > "$tmp" 2>/dev/null && mv "$tmp" "$SENT" || true; }
    echo stopped
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `chmod +x scripts/service-lifecycle.sh && bash tests/service-lifecycle/run-tests.sh`
Expected: `== PASS=7 FAIL=0 ==`(5 个测试场景共 7 条断言:start 2 + wait-ready-log 1 + stop 2 + timeout 1 + wait-ready-http 1)

- [ ] **Step 5: bash -n + commit**

```bash
bash -n scripts/service-lifecycle.sh && echo OK
git add scripts/service-lifecycle.sh tests/service-lifecycle/run-tests.sh
git commit -m "[skill] service-lifecycle.sh — 服务 start/wait-ready/stop 机械动作 + fixture

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: intake — entry_type 检测 + service descriptor(F13)

**Files:**
- Modify: `.claude/skills/intake/SKILL.md`(第 4 步「推断 entry_script」前插「第 3.5 步 entry_type 判定」;return schema 加 entry_type/service;ChangeLog)

- [ ] **Step 1: 在第 4 步前插入「### 3.5 判定 entry_type(F13)」**

在 `### 4. 推断 entry_script` 那行**之前**插入:

````markdown
### 3.5 判定 entry_type(F13)

```bash
ET=script
if ls "$WORKSPACE/repo"/{run_backend.sh,server.py,app.py,api.py} >/dev/null 2>&1 \
   || grep -rqiE "vllm serve|uvicorn|fastapi|flask run|\.launch\(|\.serve\(|gradio" \
        "$WORKSPACE/repo" --include="*.py" --include="*.md" --include="*.sh" 2>/dev/null; then
  ET=service
fi
echo "entry_type=$ET" | tee -a "$LOG"
```

`service` 时,从 README quickstart「启动服务 / 发请求」段 + 启动脚本 + config 抽出 descriptor(best-effort,全包,标 confidence):

- `start_cmd`:启动后端的命令,把选定 GPU(`gpu_picks[0]`)按项目的传法注入(`--gpus N` / `CUDA_VISIBLE_DEVICES=N` / config);传法不明在 `warnings` 标注
- `ready_signal`:优先找 health/任意 GET 端点 → `{"type":"http","url":"http://127.0.0.1:<port>/health","expect_status":200}`;没有则退 log 型 → `{"type":"log","pattern":"Uvicorn running|Application startup complete|Running on http"}`
- `port`:从启动命令/config/README 抽;抽不到填 0 并 `warnings`
- `infer_cmd`:从 README 的请求示例构造(curl / 项目自带 client),**必须**把结果写到 `output_path`(curl 加 `-o <output_path>`)
- `output_path`:推理产物相对 `repo/` 的路径
- `stop_cmd`:项目有停止命令则填,无则留空(run/cleanup 直接杀 PID)
- `confidence`:README 给全=high;靠框架默认推=medium/low

连 `start_cmd` 都推不出 → `blocked: ["service_descriptor_incomplete"]`(走现有失败处理→paused_for_human)。

> ⚠️ `app.py` 不一定是服务(可能是 CLI)。判定后**读 app.py 头部确认**有 server/launch 语义(`uvicorn.run`/`app.run`/`.launch(`/`serve`)再定 service;只是 argparse CLI 的 `app.py` 仍按 script。
````

- [ ] **Step 2: return schema 加 entry_type + service**

把 return schema(`## 返回 schema` 段)与第 8 步落盘 JSON 都加上:

```json
  "entry_type": "script",
  "service": null,
```
service 项目时 `entry_type:"service"` + `service` 填 spec § 1 的对象。第 7 步 `jq` 更新 state 的 `--argjson result` 里也带上 `entry_type`/`service`(run/verify 从 `intake_result` 读)。

- [ ] **Step 3: 自检 + commit**

```bash
# 检测块语法
bash -n <<'EOF' && echo OK
ET=script
if ls "$WS/repo"/{run_backend.sh,server.py,app.py,api.py} >/dev/null 2>&1 || grep -rqiE "vllm serve|uvicorn" "$WS/repo" 2>/dev/null; then ET=service; fi
EOF
# 示例 descriptor 是合法 JSON
echo '{"entry_type":"service","service":{"start_cmd":"x","ready_signal":{"type":"http","url":"u","expect_status":200},"port":8001,"infer_cmd":"c","output_path":"o","stop_cmd":"","confidence":"high"}}' | jq -e . >/dev/null && echo "JSON ok"
git add .claude/skills/intake/SKILL.md
git commit -m "[skill] intake F13 — entry_type 检测 + service descriptor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(ChangeLog 条目在 commit 前加到 intake SKILL 末尾 ChangeLog 段:变更类型 schema+流程 / 影响范围 3.5 步+return schema / 动机 F1 服务型 / 证据 fix 路径。)

---

## Task 4: run-and-repair — service 分支(F1 + F4)

**Files:**
- Modify: `.claude/skills/run-and-repair/SKILL.md`(第 1 步前加 entry_type 分流;新增「服务路径」段;run.json 加字段;反模式;ChangeLog)

- [ ] **Step 1: 第 0.7 步后、第 1 步前加分流 + 服务路径段**

插入:

````markdown
## 第 0.8 步:entry_type 分流

```bash
ET=$(jq -r '.intake_result.entry_type // "script"' "$WORKSPACE/state.json" 2>/dev/null)
echo "entry_type=$ET" | tee -a "$LOG"
```
`ET=script` → 走第 1 步起的现有路径(零变化)。`ET=service` → 走下面「服务路径」,跳过第 1 步常规试跑。

## 服务路径(entry_type=service,F1+F4)

复用机械脚本 `scripts/service-lifecycle.sh`(start/wait-ready/stop),infer 与修复留给你(LLM)。**铁律:无论成功/失败/超时,return 前必须 `stop`。**

```bash
export AI_HARNESS_RUN_ID="${AI_HARNESS_RUN_ID:-$RUN_ID}"
export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost   # F2,localhost 不被 Privoxy 拦
LC=/root/ai-auto-harness/scripts/service-lifecycle.sh

# 1) 起服务(写 .cache/backend.pid + sentinel)
bash "$LC" start "$WORKSPACE" | tee -a "$LOG"

# 2) 等就绪(超时按 estimated_params_b 分级,复用 Q5;服务加载占大头给足)
PARAMS_B=$(jq -r '.estimated_params_b // 0' "$WORKSPACE/state.json" 2>/dev/null)
RTO=$(python3 -c "p=float('${PARAMS_B:-0}' or 0); print(900 if p<=1 else 1200 if p<=3 else 1800 if p<=10 else 3600 if p<=30 else 5400)" 2>/dev/null || echo 1800)
bash "$LC" wait-ready "$WORKSPACE" "$RTO" | tee -a "$LOG"; READY=$?
```

- `wait-ready` 非 0(超时/backend 崩):看 `logs/backend.log` 根因。可修(端口冲突 F9 port_conflict→改 env 重起、缺依赖→装)则修(算修复轮)后重起服务;改不动或超 R3 预算 → **`stop` 后 `paused_for_human`**(reason=`service_startup_over_budget`),**绝不** paused_in_progress。
- `READY=0` → 发推理请求:

```bash
INFER=$(jq -r '.intake_result.service.infer_cmd' "$WORKSPACE/state.json")
OUT=$(jq -r '.intake_result.service.output_path' "$WORKSPACE/state.json")
cd "$WORKSPACE/repo" && eval "$INFER" 2>&1 | tee -a "$LOG"
```
- 请求错(4xx/5xx / 连接拒绝 / payload 不合法)= **普通修复轮**:看返回改 payload/endpoint/header,重发(计入 3 轮)。
- 验产物:`$OUT` 存在 + 大小/格式合理(同 script 成功判定,用 domain knowledge)。

```bash
# 3) 必停(放在所有分支的出口)
bash "$LC" stop "$WORKSPACE" | tee -a "$LOG"
```

**降级**:ready 达成但 infer 修复预算内始终不通 → `stop` 后 run.json 记 `ready_achieved:true, infer_succeeded:false`,passed 交给 verify(它会标 L0)。
````

- [ ] **Step 2: run.json 加字段**

`## 返回前落盘 results JSON` 的模板与 `## 返回 schema` 加:
```json
  "entry_type": "<script|service>",
  "ready_achieved": <bool|null>,
  "infer_succeeded": <bool|null>,
  "backend_log_tail": "<service 时 backend.log 末 50 行;script 时 null>",
```

- [ ] **Step 3: 反模式 + ChangeLog**

反模式段加:
```markdown
- ❌ **service 路径 return 前没 stop** — backend 占 GPU 孤儿(ephemeral 铁律:成功/失败/超时都 stop)
- ❌ **service 起不来就 paused_in_progress** — 决策 3 不留跨 cron 服务;超预算=stop+paused_for_human
- ❌ **手 kill 服务进程不走 service-lifecycle.sh stop** — 漏 sentinel 标记,孤儿回收会误判
```
ChangeLog 条目(变更类型 流程+schema+反模式 / 影响范围 第 0.8 步+服务路径段+run.json+反模式 / 证据 fix)。

- [ ] **Step 4: 自检 + commit**

```bash
bash -n <<'EOF' && echo OK
ET=$(jq -r '.intake_result.entry_type // "script"' s.json 2>/dev/null)
export no_proxy=127.0.0.1,localhost; LC=x
bash "$LC" start "$WS"; RTO=1800; bash "$LC" wait-ready "$WS" "$RTO"; READY=$?
INFER=$(jq -r '.x' s 2>/dev/null); eval "echo $INFER"; bash "$LC" stop "$WS"
EOF
grep -q "return 前没 stop" .claude/skills/run-and-repair/SKILL.md && echo "反模式 ok"
git add .claude/skills/run-and-repair/SKILL.md
git commit -m "[skill] run-and-repair F1+F4 — service 分支(start/wait-ready/infer/必停)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: verify — service 分支 + verify_level L0/L1(F11)

**Files:**
- Modify: `.claude/skills/verify/SKILL.md`(第 1 步前加 entry_type 分流;新增服务验证段;verify_level 语义;evidence 字段;反模式;ChangeLog)

- [ ] **Step 1: 第 0 步后加分流 + 服务验证段**

插入(verify 只有 Read+Bash,全用 bash;允许读 intake.json 的 service descriptor —— 是输入不是 run_result):

````markdown
## 第 0.6 步:entry_type 分流

```bash
ET=$(jq -r '.intake_result.entry_type // "script"' "$WORKSPACE/state.json" 2>/dev/null)
```
`script` → 走现有第 1-4 步。`service` → 走「服务验证」(独立重跑,不读 run_result)。

## 服务验证(entry_type=service,F11)

```bash
export AI_HARNESS_RUN_ID="${AI_HARNESS_RUN_ID:-$RUN_ID}"
export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
LC=/root/ai-auto-harness/scripts/service-lifecycle.sh
bash "$LC" start "$WORKSPACE" 2>&1 | tee -a "$LOG"
bash "$LC" wait-ready "$WORKSPACE" 1800 2>&1 | tee -a "$LOG"; READY=$?
# infer + 验产物 + GPU 利用
if [ "$READY" -eq 0 ]; then
  INFER=$(jq -r '.intake_result.service.infer_cmd' "$WORKSPACE/state.json")
  ( cd "$WORKSPACE/repo" && eval "$INFER" ) 2>&1 | tee -a "$LOG"
  nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader | head -3 | tee -a "$LOG"
fi
bash "$LC" stop "$WORKSPACE" 2>&1 | tee -a "$LOG"   # verify 也必停
```

判定 → 写进现有 7 字段(不新增顶层字段):
- start_cmd 起不来 / ready 始终不达成 → `passed=false, failed_at="startup"`
- ready 成、infer 失败/产物不合理 → `passed=false, failed_at="smoke_test", verify_level="L0"`(就绪但没真跑通=降级档)
- infer 产物合理 + GPU(mem>1GB & 至少一次 util>10%)→ `passed=true, verify_level="L1"`
- `evidence` 加:`"ready_signal_met": <bool>, "infer_status": "<http code 或 exit>", "output_files": [...]`

**verify_level 语义对齐**:service 的 L0=仅就绪、L1=真往返,与 script 的 L0=存在性/L1=内容级**同向**(L1 总是"更强证据"),下游 `jq -r '.verify_level'` 无需区分 entry_type。
````

- [ ] **Step 2: 反模式 + ChangeLog**

反模式加:`❌ service verify 后没 stop backend`、`❌ ready 成就判 passed(没发 infer 就 L1)`。ChangeLog 条目(影响范围 第 0.6 步+服务验证段+evidence+verify_level)。

- [ ] **Step 3: 自检 + commit**

```bash
bash -n <<'EOF' && echo OK
ET=$(jq -r '.intake_result.entry_type // "script"' s 2>/dev/null); LC=x
bash "$LC" start "$WS"; bash "$LC" wait-ready "$WS" 1800; READY=$?
[ "$READY" -eq 0 ] && { INFER=$(jq -r .x s); ( cd "$WS/repo" && eval "$INFER" ); }
bash "$LC" stop "$WS"
EOF
git add .claude/skills/verify/SKILL.md
git commit -m "[skill] verify F11 — service 独立验证 + verify_level L0/L1

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: cleanup — 杀本 workspace 登记 PID(F12)

**Files:**
- Modify: `.claude/skills/cleanup-deployed-workspace/SKILL.md`(第 2 步「白名单删」**之前**加「第 1.5 步 杀后台」;反模式;ChangeLog)

- [ ] **Step 1: 第 1 步(4 道防护)后、第 2 步前加「第 1.5 步」**

````markdown
### 第 1.5 步:杀本 workspace 登记的后台进程(F12)

service 型部署留下的 backend 进程,whitelist rm 前先杀(R1:只杀本 `$WORKSPACE/.cache/*.pid` 登记的,绝不碰未登记/训练/别 workspace):

```bash
STOP_CMD=$(jq -r '.intake_result.service.stop_cmd // empty' "$WORKSPACE/state.json" 2>/dev/null)
[ -n "$STOP_CMD" ] && ( cd "$WORKSPACE/repo" 2>/dev/null && bash -c "$STOP_CMD" ) >> "$LOG" 2>&1 || true
for pidfile in "$WORKSPACE"/.cache/*.pid; do
  [ -f "$pidfile" ] || continue
  while read -r pid; do
    [ -z "$pid" ] && continue
    st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    { [ -z "$st" ] || [ "$st" = Z ]; } && continue   # 已死/僵尸(kill -0 误判活)
    echo "kill backend pid=$pid" >> "$LOG"
    kill "$pid" 2>/dev/null; sleep 1; kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  done < "$pidfile"
done
```
注:cleanup 在 verify 没过时可能被 G4 跳过 → 失败路径孤儿由 `reconcile-sentinels.sh`(T7)兜底。
````

- [ ] **Step 2: 反模式 + ChangeLog**

反模式加:`❌ 杀 .cache/*.pid 之外的 PID(R1)`、`❌ kill -0 判活(僵尸误判,查 /proc/<pid>/stat)`。ChangeLog 条目。

- [ ] **Step 3: 自检 + commit**

```bash
bash -n <<'EOF' && echo OK
for pidfile in "$WS"/.cache/*.pid; do [ -f "$pidfile" ] || continue
  while read -r pid; do [ -z "$pid" ] && continue
    st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    { [ -z "$st" ] || [ "$st" = Z ]; } && continue
    kill "$pid" 2>/dev/null; done < "$pidfile"; done
EOF
git add .claude/skills/cleanup-deployed-workspace/SKILL.md
git commit -m "[skill] cleanup F12 — 杀本 workspace 登记的后台进程

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: reconcile-sentinels.sh — 孤儿服务回收(F14 安全网)

**Files:**
- Modify: `scripts/reconcile-sentinels.sh`(加 service sentinel 孤儿回收段)
- Test: `tests/reconcile-service/run-tests.sh`(新)

- [ ] **Step 1: 写 fixture 测试(先失败)**

Create `tests/reconcile-service/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -u
HARNESS_ROOT="${HARNESS_ROOT:-/root/ai-auto-harness}"
RS="$HARNESS_ROOT/scripts/reconcile-sentinels.sh"
PASS=0; FAIL=0; ok(){ echo "ok: $1"; PASS=$((PASS+1)); }; bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# 隔离一个假 workspace 根(reconcile 应只扫 workspace/*/.cache/handoff)
TROOT=$(mktemp -d); WS="$TROOT/workspace/svc-test"; mkdir -p "$WS/.cache/handoff"

# 孤儿:status=running 且 PID 活
sleep 600 & ORPHAN=$!; echo "$ORPHAN" > "$WS/.cache/backend.pid"
cat > "$WS/.cache/handoff/service-old.json" <<JSON
{"phase":"service","status":"running","pid":$ORPHAN,"run_id":"old","workspace":"$WS"}
JSON

AI_HARNESS_WORKSPACE_GLOB="$TROOT/workspace" bash "$RS" >/dev/null 2>&1 || true
kill -0 "$ORPHAN" 2>/dev/null && { bad "孤儿 PID 没被杀"; kill -9 "$ORPHAN" 2>/dev/null; } || ok "孤儿 PID 被杀"
grep -q '"status": *"stopped"' "$WS/.cache/handoff/service-old.json" && ok "sentinel 标 stopped" || bad "sentinel 没标 stopped"

# R1:未登记在任何 .cache/*.pid 的外部 PID,即使被 sentinel 引用也不杀
sleep 600 & EXT=$!
cat > "$WS/.cache/handoff/service-ext.json" <<JSON
{"phase":"service","status":"running","pid":$EXT,"run_id":"old","workspace":"$WS"}
JSON
# 注意:不把 EXT 写进 backend.pid(模拟外部进程)
AI_HARNESS_WORKSPACE_GLOB="$TROOT/workspace" bash "$RS" >/dev/null 2>&1 || true
kill -0 "$EXT" 2>/dev/null && ok "外部未登记 PID 未被杀(R1)" || bad "误杀了未登记 PID(违反 R1)"
kill -9 "$EXT" 2>/dev/null || true; rm -rf "$TROOT"

echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑,确认失败**

Run: `chmod +x tests/reconcile-service/run-tests.sh && bash tests/reconcile-service/run-tests.sh`
Expected: FAIL(reconcile 还没有孤儿回收逻辑,孤儿 PID 不被杀)

- [ ] **Step 3: 在 `scripts/reconcile-sentinels.sh` 加孤儿回收段**

先 `Read scripts/reconcile-sentinels.sh` 找到它遍历 sentinel 的主循环;在末尾(或合适位置)加(`AI_HARNESS_WORKSPACE_GLOB` 缺省 `/root/ai-auto-harness/workspace`):

```bash
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
      kill "$spid" 2>/dev/null; sleep 1; kill -0 "$spid" 2>/dev/null && kill -9 "$spid" 2>/dev/null || true
    fi
  fi
  tmp=$(mktemp); jq '.status="stopped" | .reconciled_at="'"$(date -Iseconds)"'"' "$sent" > "$tmp" 2>/dev/null && mv "$tmp" "$sent" || true
done
```

- [ ] **Step 4: 跑,确认通过**

Run: `bash tests/reconcile-service/run-tests.sh`
Expected: `== PASS=3 FAIL=0 ==`(孤儿杀 / sentinel stopped / R1 外部不杀)

- [ ] **Step 5: bash -n + commit**

```bash
bash -n scripts/reconcile-sentinels.sh && echo OK
git add scripts/reconcile-sentinels.sh tests/reconcile-service/run-tests.sh
git commit -m "[skill] reconcile-sentinels — service 孤儿回收安全网(F14,R1 守卫)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: 治理收尾 — 状态/索引/回填

**Files:**
- Modify: `docs/framework-issues-cc-complete.md`(F1/F4/F11/F12/F13/F14 标 [已修-CC])
- Modify: `docs/superpowers/fixes/README.md`(加本 fix 一行 + 计数 +1)
- Modify: `docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md`(勾状态 + 回填 hash)
- Modify: `docs/superpowers/plans/2026-ai-auto-harness-master.md`("最后更新" + fix 计数)

- [ ] **Step 1: framework 文档标状态**

`framework-issues-cc-complete.md`:F1 标题 `[待CC] P0`→`[已修-CC] P0`;F4/F11/F12/F13/F14 同理标 `[已修-CC]`;优先级表(六)对应行改 ✅已修。

- [ ] **Step 2: fixes/README 索引 + 计数**

加一行(取下一个 fix 编号,当前最大 43 → #44):
```markdown
| 44 | **P0** | 平台学会部署「服务型」项目:起后端→等就绪→调API→验产物→停服务(不只单脚本) | [service-type-inference](2026-06-16-service-type-inference-fix.md) | (待回填) | 全平台(CC) |
```
更新「总计/已闭环/P0」计数(+1)。

- [ ] **Step 3: master plan**

`2026-ai-auto-harness-master.md` "最后更新" 追加一句(F1 服务型架构簇落地:helper+四阶段+孤儿回收);fix 计数 43→44。

- [ ] **Step 4: commit + 回填 hash**

```bash
cd /root/ai-auto-harness
git add docs/framework-issues-cc-complete.md docs/superpowers/fixes/README.md docs/superpowers/plans/2026-ai-auto-harness-master.md docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md
git commit -m "[fix] 服务型推理支持 — F1 簇落地治理(状态/索引/master)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
H=$(git rev-parse --short HEAD)
# 回填 fix.md 与 README 的 (待回填) → $H
sed -i "s/(待回填)/\`$H\`/" docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md
sed -i "s#service-type-inference](2026-06-16-service-type-inference-fix.md) | (待回填)#service-type-inference](2026-06-16-service-type-inference-fix.md) | \`$H\`#" docs/superpowers/fixes/README.md
git add docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md docs/superpowers/fixes/README.md
git commit -m "[fix] #44 回填 commit hash $H

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: 全量自测回归**

```bash
bash tests/service-lifecycle/run-tests.sh && bash tests/reconcile-service/run-tests.sh && echo "ALL GREEN"
git status --short && echo "(clean)"
```
Expected: 两套 fixture 全 PASS,工作树干净。

---

## 验证(对照 spec「成功标准」)

| spec 项 | 覆盖任务 |
|---|---|
| script 路径零回归 | T3/T4/T5 都以 `entry_type` 缺省=script 分流,现有路径不进新代码 |
| 服务往返 L1 | T2(helper)+T4(run)+T5(verify);实战留 fix.md 待办 |
| 必停(无 GPU 残留) | T2 stop + T4/T5 必停纪律 + 反模式 |
| 孤儿回收 | T7 fixture(孤儿杀 + sentinel stopped) |
| 降级 L0 | T5 verify_level 映射(ready 成 infer 不成→L0) |
| R1(不碰未登记 PID) | T7 fixture(外部 PID 未被杀)+ T6 R1 自检 |

## 不做(同 spec)
跨 cron 保活 / 多服务编排 / Hermes 同步 / 流式推理 / api_skeleton。
