---
name: auto-daily
description: AI Auto Harness 顶层工作流 — 接续 / pick / dispatch 5 阶段 SubAgent / 写报告(/auto-daily 触发)
allowed-tools: [Read, Write, Bash, Task, mcp__ai_daily_scan__*]
---

# daily-auto

你是 AI Auto Harness 平台的主 agent。每天 10:30 由 cron 启动你(或被 `/auto-daily` 命令触发)。

> **运行模式说明**:cron / manual worker 统一用 `IS_SANDBOX=1 + --dangerously-skip-permissions + --output-format stream-json --verbose + --settings .claude/settings.json` 启动,保留 skills 和 SessionStart/PostToolUse/SessionEnd hooks。历史 `--bare` 会跳过 hooks/skills,已废弃。

## ⛔ R9 强制分派规则(先读)

主 agent 每个 phase 必须用 `Task()` dispatch 对应 SubAgent。主 agent 的 Bash 只允许做路由/读写 state/meta/validator 这类调度动作;严禁自己 `git clone` / `hf download` / `pip install` / `python -m ...` 跑阶段任务。PostToolUse hook 会在 Bash>10 且 Task=0 时注入强警告,但不要等 hook 提醒才改。

## 任务 0:初始化(主 agent 启动后第一件事)

```bash
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# run 目录:cron(daily.sh)启动时已注入 AI_HARNESS_RUN_DIR(此处为全局 runs/cron-<ts>,
# 因为 cron 在 launch 时还没 pick slug);复用它,后续所有 run 级写入都用 $RUN_DIR。
# 仅交互式直接跑 skill 才自造。(Fix: 2026-06-08-run-dir-into-workspace)
if [ -n "${AI_HARNESS_RUN_DIR:-}" ]; then
    RUN_DIR="$AI_HARNESS_RUN_DIR"; RUN_ID="$(basename "$RUN_DIR")"; mkdir -p "$RUN_DIR"
else
    RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"; RUN_DIR="runs/$RUN_ID"; mkdir -p "$RUN_DIR"
    echo "$RUN_ID" > "runs/.current_run_id"
fi
echo "{\"started_at\":\"$(date -Iseconds)\",\"run_id\":\"$RUN_ID\"}" > "$RUN_DIR/meta.json"
```

记住 `$RUN_DIR`,后续每步都要写到 `$RUN_DIR/`(decisions.md、SubAgent return 等)。

**任务 2 选好项目后,在 dispatch 第一个 SubAgent 前必须创建项目落盘目录**:

```bash
SLUG="<挑中的项目 slug>"
WORKSPACE="workspace/$SLUG"
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
```

这样所有 SubAgent 进来都能直接落 `$WORKSPACE/logs/<phase>.log` 和 `$WORKSPACE/results/<phase>.json`(详见根 `.claude/CLAUDE.md` 的"落盘约定"段).

**双写原则**(每个 SubAgent 返回后,主 agent 把它的 result JSON 同时写两份):

```bash
# SubAgent 返回时
SUBAGENT_RESULT='<JSON from SubAgent>'
# 写项目级(覆写,workspace 侧"最新"快照)
echo "$SUBAGENT_RESULT" > "$WORKSPACE/results/${PHASE}.json"
# 写 run 级(本次 cron 独立快照,审计)
echo "$SUBAGENT_RESULT" > "$RUN_DIR/${PHASE}.json"
```

## 工作流(顺序执行)

### 任务 1:接续与积压检查

```bash
find workspace -maxdepth 2 -name state.json -exec jq -c '{slug, phase, phases_done, updated_at, started_at}' {} \; 2>/dev/null
```

筛选 `state.phase ∉ {done, paused_for_human}` **且 `state.status != "paused_for_human"`** 的项目(in_progress)。(status 才是暂停轴 — eagle 实测 phase=fetch-weights + status=paused_for_human,只看 phase 会误接续)

也扫 `pending_human/*.md`(不重跑,但报告里要标)。

**outcome 补回填(2026-06-10 外部 review #20 采纳)**:若 `state/outcomes-pending.jsonl` 存在且非空 — 这是上次 run record_outcome MCP 调用失败的本地暂存 — 逐行重试 `mcp__ai_daily_scan__record_outcome(...)`,成功的行从文件移除(全部成功则删文件)。不补回填,scan 会重复推荐已处理过的项目。

### 任务 2:项目选择

**有 in_progress** → 选最早 `started_at` 的接续(直接跳到任务 3,从 `state.phase` 对应阶段开始)

**无 in_progress** → 调 `mcp__ai_daily_scan__scan_today()` 拿 findings.jsonl 路径,Read 这个文件按 JSONL 逐行解析。然后按规则过滤+排序:

**过滤**:
- `estimated_params_b ≤ 30`(否则改 `next_action=try_api_pilot`,见末尾"特例")
- 不在 `state/blacklist.jsonl`(未过期)
- 不在 `pending_human/`(即 `pending_human/<slug>.md` 不存在)
- `gated_repos` 为空 OR `$HF_TOKEN` 已配置
- 在 ai-daily-scan/state/outcomes.jsonl 中 30 天内 status=passed 的 slug 跳过

**排序**:
- `confidence=high` 优先
- 然后 `len(scenario_hits)` 多 优先
- tie-break:`scan_ts` 新优先

**选 1 个**。

### 任务 3:部署流水线(具体执行)

读项目 `workspace/<slug>/state.json` 决定从哪个阶段开始(若新项目,state.json 还没建,从 intake 开始):

| state.phase | dispatch SubAgent skill | 完成后 state.phase ← |
|---|---|---|
| `null`(新项目) | `intake` | `fetching` |
| `fetching` | `fetch-weights` | `installing` |
| `installing` | `install-env` | `running` |
| `running` | `run-and-repair` | `verifying` |
| `verifying` | `verify` | `runbook_pending` |
| `runbook_pending` | `runbook-agent`(write-deploy-runbook) | `cleanup_pending`(若 verify_passed)或 `done`(verify 失败) |
| `cleanup_pending` | `cleanup-agent`(cleanup-deployed-workspace) | `archived` |
| `archived` | — | (终态,等价 done) |

**执行循环**(伪代码,每一步你都用对应的 Task 工具实际跑):

```
WORKSPACE="workspace/$SLUG"
while True:
    if not exists(f"{WORKSPACE}/state.json"):
        PHASE = "null"  # 新项目
    else:
        PHASE = jq -r '.phase' "$WORKSPACE/state.json"

    if PHASE in ["done", "archived", "paused_for_human"]:
        break  # 完成或卡住,进任务 4

    # 选 SubAgent
    SKILL = {"null": "intake", "fetching": "fetch-weights",
             "installing": "install-env", "running": "run-and-repair",
             "verifying": "verify",
             "runbook_pending": "runbook-agent",
             "cleanup_pending": "cleanup-agent"}[PHASE]

    # 注:verifying → 下一步是 runbook_pending(不直接 done)。runbook 跑完才决定走
    #     cleanup_pending(verify_passed) 或 done(verify 失败,保留 workspace)。
    NEXT_PHASE = {"null": "fetching", "fetching": "installing",
                  "installing": "running", "running": "verifying",
                  "verifying": "runbook_pending",
                  "runbook_pending": "cleanup_pending_or_done",  # 见下面 RUNBOOK 后处理
                  "cleanup_pending": "archived"}[PHASE]

    # 用 Task 工具 dispatch SubAgent(传入 slug + 必要上下文)
    # 🔴 关键:每个 phase 的 Task() prompt 必须显式传入路径模板等关键参数,
    # 不靠 SubAgent 自己去 SKILL.md 里找(Fix: 2026-06-08-fetch-dest-path-not-injected-fix)
    if SKILL == "fetch-weights":
        RESULT = Task(
            subagent_type="fetch-agent",
            description=f"fetch weights for {SLUG}",
            prompt=f"""
slug: {SLUG}
hf_repos: {state.get('hf_repos', [])}
workspace_path: {WORKSPACE}
run_id: {RUN_ID}

🔴 关键路径参数(必须使用,禁止自拼):
dest_path_template: $WORKSPACE/.cache/hf_models/$REPO
  → 每个 repo 的下载目标 = {WORKSPACE}/.cache/hf_models/<org>/<repo>
  → 例如 google/magenta-realtime-2 → {WORKSPACE}/.cache/hf_models/google/magenta-realtime-2
sentinel_dir: $WORKSPACE/.cache/handoff
log_path: $WORKSPACE/logs/fetch_weights.log

🔴 下载环境变量(每个 bash 必须 re-export):
HF_HUB_DISABLE_XET=1
HF_HUB_DOWNLOAD_CONCURRENCY=2
HF_HOME=$WORKSPACE/.cache/huggingface
--token "$HF_TOKEN" 显式传

🔴 硬约束:
- 用 hf download(不是 huggingface-cli),默认断点续传(不加 --resume-download)
- 每个 repo 串行,起前 pgrep -f "hf download.*$REPO" 防并发
- 绝不启动 pip install 或动其他 workspace
"""
        )
    else:
        RESULT = Task(subagent_type=SKILL, input={
            "slug": SLUG,
            "workspace_path": WORKSPACE,
            ...其他从 state.intake_result/fetch_result/... 传
        })

    # 写 SubAgent return 到 $RUN_DIR/(= ${AI_HARNESS_RUN_DIR:-runs/$RUN_ID},见任务 0)
    Write(f"{RUN_DIR}/{SKILL}.json", json.dumps(RESULT))

    # 检查阻塞
    if RESULT.get("blocked") or RESULT.get("paused_for_human"):
        break  # 进任务 4

    if RESULT.get("paused_in_progress"):
        # fetch-weights 跨 cron 接续场景 — state.phase 不变,等下次 cron
        break  # 进任务 4(报告写"in progress")

    # runbook 跑完的分支决策(verify 失败时不进 cleanup,保留 workspace)
    if SKILL == "runbook-agent":
        verify_passed = (state.verify_result or {}).get("passed", False) is True
        NEXT_PHASE = "cleanup_pending" if verify_passed else "done"
        RUNBOOK_PATH = RESULT.get("runbook_path")  # 透传给任务 4 用

    # 更新 state.json:phase 切到 NEXT_PHASE,phases_done append
    jq --arg p "$NEXT_PHASE" --arg s "$SKILL" --arg t "$(date -Iseconds)" \
       '.phase = $p | .phases_done += [$s] | .updated_at = $t | .{$SKILL}_result = '"$(echo $RESULT)"'' \
       "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"

    # 继续下一轮
```

**关键 dispatch prompt(runbook-agent + cleanup-agent)**:

```python
# Phase: runbook_pending
RUNBOOK_RESULT = Task(
    subagent_type="runbook-agent",
    description=f"write deploy runbook for {SLUG}",
    prompt=f"""
slug: {SLUG}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}
verify_passed: {verify_result.get("passed", False)}
verify_result: {json.dumps(verify_result)}
github_url: {state["github_url"]}
force_status: null
"""
)
RUNBOOK_PATH = RUNBOOK_RESULT.get("runbook_path")

# Phase: cleanup_pending(仅 verify_passed=true 才进来)
CLEANUP_RESULT = Task(
    subagent_type="cleanup-agent",
    description=f"cleanup workspace for {SLUG}",
    prompt=f"""
slug: {SLUG}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}
verify_passed: true
runbook_path: {RUNBOOK_PATH}
dry_run: false
force_cleanup_incomplete: false
"""
)
```

任一 SubAgent 返回 `blocked=true`、`paused_for_human` 或 `paused_in_progress` → 跳到任务 4 写报告。

### 任务 3 跨 cron 接续(关键)

- 单次 cron run 只能跑约 30-60 分钟内完成的事(--print 模式不适合超长)
- 长任务(主要是 fetch-weights 拉几十 GB 权重)可能跨 cron:
  - SubAgent 2 启动 background bash 拉权重
  - 写 state.fetch_state.bg_shells(含 PID)
  - 若快到 cron 结束(50 分钟)还没拉完 → 返回 `paused_in_progress: true`
  - state.phase 仍是 `fetching`
  - **下次 cron** 主 agent 任务 1 扫到这个 in_progress → 任务 2 不挑新项目 → 任务 3 重新 dispatch fetch-weights(SubAgent 自己 resume)

### 特例:模型 > 30B 或不能 self-host

- 任务 2 过滤时 `estimated_params_b > 30` 的项目改走 api_pilot
- 跳过 intake,直接 dispatch **api-skeleton skill**
- 产出 `workspace/<slug>/api_skeleton/{client.py, smoke_test.py, .env.example, 使用指导.md}`
- state.phase=done(api_route),outcomes status=api_route

### 任务 4:写报告 + 回填

- 写报告前先跑 artifact gate(若 workspace 已进入 verify/runbook/cleanup 后段):
  ```bash
  bash scripts/validate-artifacts.sh "$WORKSPACE"
  ```
  - 若 verify failed 且无 cleanup.json: 合法
  - 若 verify passed 但 cleanup.json 缺失: 先 dispatch `cleanup-agent`,不要直接写 passed 报告
  - 若 runbook.json 缺失: 先 dispatch `runbook-agent`,不要手写 RUNBOOK.md 替代 schema
- 调 **write-recommendation skill** 写 `reports/<YYYY-MM-DD>.md`(覆写,因单天可能多次 cron 重跑)
  - 输入 `run_results[i]` 必须含 `runbook_path`(可为 null)+ `cleanup_result`(可为 null)— 让日报渲染部署手册链接
- 调 `mcp__ai_daily_scan__record_outcome(slug, status, ...)` 回填给 scan

## 硬约束

- N=1 单项目串行,**不并行** dispatch SubAgent
- 任一阶段 SubAgent 返回 `paused_for_human` → 立刻跳到任务 4
- 接续模式下**不挑新项目**
- 你不亲自跑 git/pip/python — 那些是 SubAgent 的事

## 反模式

- 不要主 agent 自己 git clone / pip install — 都交给 SubAgent
- 不要并行 dispatch 多个 SubAgent(初版 N=1)
- 不要 max_turns > 3 在 SubAgent 失败时硬试
- 不要 verify 失败时还跑 cleanup-agent — workspace 是失败 case 的唯一现场
- 不要 verify 失败就跳过 runbook-agent — 失败 runbook 的踩坑章节对下次有价值
- 不要忘了把 runbook_path 透传给 write-recommendation — 日报缺链接

## ChangeLog

- **2026-06-04** — 修正文档漂移并加入 R9/artifact gate
  - 变更类型: 约束 / 流程
  - 影响范围: 运行模式说明 / R9 分派规则 / 任务 4 写报告前检查
  - 动机: `--bare` 说明已过期;ControlFoley 实测 165 Bash 0 Task 导致 verify/runbook/cleanup artifacts 缺失
  - 证据: [fixes/2026-06-03-r9-task-dispatch-still-bypassed-fix.md](../../../docs/superpowers/fixes/2026-06-03-r9-task-dispatch-still-bypassed-fix.md) + [fixes/2026-06-03-scan-to-deploy-never-e2e-verified-fix.md](../../../docs/superpowers/fixes/2026-06-03-scan-to-deploy-never-e2e-verified-fix.md)
  - 验证: ⬜ 待验证(L1 scan→pick→intake + artifact validator)
- **2026-06-08** — fetch-agent Task() prompt 显式注入 DEST 路径模板 + 下载环境变量
  - 变更类型: 约束 / 流程
  - 影响范围: 任务 3 fetch-weights dispatch prompt
  - 动机: magenta-realtime 实测 5 个 hf download 拼出 3 种不同 --local-dir,根因是 Task() prompt 未传 DEST,SubAgent 自拼
  - 证据: [fixes/2026-06-08-fetch-dest-path-not-injected-fix.md](../../../docs/superpowers/fixes/2026-06-08-fetch-dest-path-not-injected-fix.md)
  - 验证: ⬜ 待验证(重跑 magenta-realtime fetch 阶段)
- **2026-06-10** — 任务 1 筛选加 status 轴 + outcomes-pending 重试
  - 变更类型: 硬约束(筛选语义修正)+ 流程
  - 影响范围: 任务 1 接续与积压检查
  - 动机: eagle 实测 phase=fetch-weights + status=paused_for_human,旧筛选只看 phase 会误接续再撞一次 gated 403;record_outcome MCP 失败时结果静默丢失,scan 重复推荐
  - 证据: [fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md](../../../docs/superpowers/fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md)
