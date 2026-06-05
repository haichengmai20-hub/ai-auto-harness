---
name: auto-deploy
description: 手动跑单项目部署 — /auto-deploy <github_url> 触发,跳过 scan pick 直接对该 URL 走 5 阶段流水线
allowed-tools: [Read, Write, Bash, Task, mcp__ai_daily_scan__*]
---

# auto-deploy

`/auto-deploy <github_url>` 触发本 skill。**手动单项目场景**,不走 scan pick。

参数会在 `$ARGUMENTS` 里(单个 github URL,可能含尾部 query string)。

## 🔴 主 agent 的角色定位(违反 = 架构退化成单 agent 烂泥)

你(主 agent / orchestrator)**只做** 4 件事:

1. **路由决策**:先做 workspace 接续预检,再走 30B / gated / 新项目三分支
2. **状态机推进**:读 `state.json`,选下一个 phase
3. **`Task()` dispatch SubAgent**:`intake-agent` / `fetch-agent` / `install-agent` / `runner-agent` / `verify-agent`
4. **结果聚合 + 写报告**

**你不做**(违反就是单 agent 烂泥):
- ❌ 自己 `Bash(git clone ...)` — 那是 intake-agent 的事
- ❌ 自己 `Bash(hf download ...)` 或 `python -c "snapshot_download(...)"` — 那是 fetch-agent
- ❌ 自己 `Bash(pip install ...)` — 那是 install-agent
- ❌ 自己 `Bash(python -m flux ...)` 跑 entry_script — 那是 runner-agent
- ❌ 在一个 phase 里"顺手"做下一 phase 的事(比如 fetch 里启 pip)— SubAgent 隔离边界要硬

**为什么强制**:run2 试跑暴露的核心问题就是主 agent 全程不调 Task(),48 次 Bash 把 5 个 phase 揉成一团,在同一 context 里做"先装还是先下"的拍脑袋决策,结果 kill 掉自己的下载、又抢别 run 的带宽、最后空转 1h。**SubAgent 隔离强制串行 + context 单一职责 = 不会做这种烂决策**。

**运行时硬拦截**:PostToolUse hook 会在 `bash_count > 10 && task_called == 0` 时注入 R9 强警告,`>20` 时提示立即停止内联。不要把 hook 当兜底;第一阶段就应该 Task dispatch。

## 工作流

### 任务 0:初始化(同 auto-daily Task 0)

```bash
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"
mkdir -p "runs/$RUN_ID"
echo "$RUN_ID" > "runs/.current_run_id"
echo "{\"started_at\":\"$(date -Iseconds)\",\"run_id\":\"$RUN_ID\",\"trigger\":\"/auto-deploy\",\"url\":\"$ARGUMENTS\"}" > "runs/$RUN_ID/meta.json"
```

### 任务 0.5:重复 URL / 既有 workspace 预检

这一步必须在 `analyze_project` 和任何 `state.json` 写入之前执行。重复 launch 同一项目时,非终态 workspace 只能接续,不能覆盖。

```bash
url="$ARGUMENTS"
repo=$(basename "$url" .git)
SLUG=$(echo "$repo" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
WORKSPACE="workspace/$SLUG"

if [ -f "$WORKSPACE/state.json" ]; then
    PHASE=$(jq -r '.phase // "null"' "$WORKSPACE/state.json")
    if [ "$PHASE" = "done" ] || [ "$PHASE" = "archived" ]; then
        echo "$SLUG 之前已完成/归档;默认不重跑,不覆盖旧 state。"
        exit 0
    elif [ "$PHASE" = "paused_for_human" ]; then
        echo "$SLUG 等人手处理,见 pending_human/$SLUG.md;不要覆盖 state.json。"
        exit 0
    else
        echo "$SLUG 在 phase=$PHASE,本次 /auto-deploy 必须接续既有 state。"
        RESUME_EXISTING=1
    fi
else
    RESUME_EXISTING=0
fi
```

`RESUME_EXISTING=1` 时跳过任务 1-3 的新项目分析/过滤/初始化,直接进任务 4,从 `state.phase` 对应阶段 dispatch。任何非终态 workspace 都不能 `cat > "$WORKSPACE/state.json"` 覆盖,否则会丢跨 worker 接续进度。

### 任务 1:ad-hoc 分析

若 `RESUME_EXISTING=1`,跳过任务 1-3,不要重新分析、不要重新 gating、不要改写旧 state;直接进任务 4 的 phase dispatch。

调 MCP 跑一次 analyst:

```python
finding = mcp__ai_daily_scan__analyze_project(url=$ARGUMENTS)
```

期望拿到 AnalystReport(含 6 个新字段 next_action / hf_repos / gated_repos / params_b / size_gb / github_url).

若分析失败(返回 `{"error": ...}`)→ 写报告记录失败 → 退出。

### 任务 2:30B 阈值过滤

```python
if finding["estimated_params_b"] > 30:
    # 走 api-skeleton,跳过 deploy 流水线
    dispatch api-skeleton skill with:
        slug = <从 url 推断,如 url 的最后一段 lower-cased>
        github_url = $ARGUMENTS
        hf_repos = finding["hf_repos"]
        scan_finding = finding
        reason = "model_too_large"
    write report + record_outcome status="api_route"
    return
```

若 ≤ 30B → 进任务 3.

### 任务 3:Gated 探测

```bash
if [ -z "$HF_TOKEN" ] && [ "${#finding[gated_repos][@]}" -gt 0 ]; then
    # gated 且无 token
    走 api-skeleton with reason="gated_no_token"
    return
fi
```

### 任务 4:走 5 阶段流水线

```python
# 跟 auto-daily 任务 3 一模一样,只是输入项目固定为 ad-hoc 这个
SLUG = <slug,从 github_url 抽,小写 + - 替换>
WORKSPACE = f"workspace/{SLUG}"

# 仅新项目写初始 state.json;接续项目绝不覆盖旧 state
if RESUME_EXISTING == 0:
    state = {
        "slug": SLUG,
        "github_url": $ARGUMENTS,
        "hf_repos": finding["hf_repos"],
        "estimated_params_b": finding["estimated_params_b"],
        "estimated_weight_size_gb": finding["estimated_weight_size_gb"],
        "gated_repos": finding["gated_repos"],
        "scenario_hits": finding["scenario_hits"],
        "phase": "intake",
        "phases_done": [],
        "started_at": now(),
        "trigger": "/auto-deploy"
    }
    Write WORKSPACE/state.json with state
else:
    state = Read WORKSPACE/state.json
    # dispatch 输入优先从既有 state 取:github_url / hf_repos / *_result / phase

github_url = state.get("github_url", $ARGUMENTS)
hf_repos = state.get("hf_repos", finding["hf_repos"] if RESUME_EXISTING == 0 else [])
gated_repos = state.get("gated_repos", finding["gated_repos"] if RESUME_EXISTING == 0 else [])
estimated_weight_size_gb = state.get("estimated_weight_size_gb", finding["estimated_weight_size_gb"] if RESUME_EXISTING == 0 else None)

# 走 phase dispatch 逻辑 — 必须用 Task() 工具,严禁主 agent 自己 bash
# 每个 phase 一次 Task() 调用,prompt 里只传该 phase 必需的输入

# Phase 1: intake
Task(
    subagent_type="intake-agent",
    description="intake <slug>",
    prompt=f"""
slug: {SLUG}
github_url: {github_url}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}
hf_repos: {hf_repos}
gated_repos: {gated_repos}
estimated_weight_size_gb: {estimated_weight_size_gb}

按 intake skill 跑完,return intake.json schema。
"""
)
# → 读 workspace/<slug>/results/intake.json,确认 status,更新 state.json phases_done

# Phase 2: fetch-weights (必须等 intake done)
if intake_result.status == "done":
    Task(
        subagent_type="fetch-agent",
        description=f"fetch weights for {SLUG}",
        prompt=f"""
slug: {SLUG}
hf_repos: {hf_repos}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}

按 fetch-weights skill 跑完(用 hf download + HF_TOKEN + HF_XET_HIGH_PERFORMANCE=1;
hf download 默认断点续传,不加 --resume-download)。
绝不启动 pip install 或动其他 workspace。
"""
    )

# Phase 3: install-env (必须等 fetch-weights done)
if fetch_result.status == "done":
    Task(subagent_type="install-agent", ...)

# Phase 4: run-and-repair
if install_result.deps_ok:
    Task(subagent_type="runner-agent", ...)

# Phase 5: verify (独立判定,不读 run 的修复历史)
if run_result.status == "done":
    Task(subagent_type="verify-agent", ...)

# 任一 blocked / paused_for_human / paused_in_progress → 跳到任务 5(写报告)
# verify 跑完(无论 pass/fail)→ 进入任务 4.5 → 任务 4.6 → 任务 5
```

**关键规则**:每个 Task() 返回后,主 agent 必须:
1. 读 `workspace/<slug>/results/<phase>.json` 确认 SubAgent 落盘
2. 更新 `workspace/<slug>/state.json`:`phases_done += ["<phase>"]`, `phase = "<next>"`,`updated_at = now()`
3. 若 SubAgent 返回 blocked / paused → 不 dispatch 下一个,直接跳到任务 5(无 runbook、无 cleanup)

### 任务 4.5:写部署 runbook(verify 跑完即触发,不论 pass/fail)

`verify` SubAgent 返回后,无论 `verify_result.passed` 是 true / false,都 dispatch `runbook-agent` 抽取本次部署 runbook(失败 case 也有价值 — 给下次部署者看踩坑)。

```python
RUNBOOK_RESULT = Task(
    subagent_type="runbook-agent",
    description=f"write deploy runbook for {SLUG}",
    prompt=f"""
slug: {SLUG}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}
verify_passed: {verify_result.get("passed", False)}
verify_result: {json.dumps(verify_result)}
github_url: {ARGUMENTS}
force_status: null
"""
)
# RUNBOOK_RESULT = { "runbook_path": "reports/runbooks/<slug>-<date>.md", "status": "..." }
RUNBOOK_PATH = RUNBOOK_RESULT.get("runbook_path")
```

写完后双写落盘:`workspace/<slug>/results/runbook.json` + `runs/$RUN_ID/runbook.json`。

### 任务 4.6:cleanup workspace(仅 verify_passed=true)

```python
if verify_result.get("passed") is True:
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
    # state.phase 由 cleanup-agent 自己改成 "archived"
else:
    # verify 没过:保留 workspace 给人工 debug,不 cleanup
    CLEANUP_RESULT = None
```

**为什么 verify 失败不 cleanup**:R-Phase5-1 — workspace 是失败 case 的唯一现场,清掉就丢线索。

### 任务 5:写报告 + 回填

调 **write-recommendation** skill,同 auto-daily 任务 4。**必须把 `RUNBOOK_PATH` 透传给 write-recommendation**(让日报含部署 runbook 链接):

写报告前必须跑 artifact gate:

```bash
bash scripts/validate-artifacts.sh "$WORKSPACE"
```

若 verify passed 但 cleanup.json 缺失,先回到任务 4.6 dispatch cleanup-agent;若 runbook.json 缺失,先回到任务 4.5 dispatch runbook-agent。不要用手写 markdown 替代 `results/runbook.json`。

```python
write_recommendation_input = {
    "run_id": RUN_ID,
    "run_results": [{
        "slug": SLUG,
        "status": <derived from verify_result.passed>,
        ...其他字段同前,
        "runbook_path": RUNBOOK_PATH,        # ← 新增,可为 null
        "cleanup_result": CLEANUP_RESULT,    # ← 新增,可为 null
        ...
    }],
    ...
}
```

## slug 生成规则

从 github_url 取最后一段(repo 名),lowercase + 非字母数字字符替换为 `-`:

```bash
url="$ARGUMENTS"  # e.g. https://github.com/tencent-ailab/SongGeneration
repo=$(basename "$url" .git)  # SongGeneration
SLUG=$(echo "$repo" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
# SLUG=songgeneration
```

## 与 /auto-daily 的差异

| 维度 | /auto-daily | /auto-deploy |
|---|---|---|
| 来源 | scan findings.jsonl 自动 pick | 命令行参数 URL |
| 选项目 | 过滤 + 排序,选 1 个 | 直接用 URL |
| 接续 | 是,扫 in_progress | 固定 URL;若同 slug workspace 为非终态,**必须接续该 workspace** |
| cron 触发 | 是 | 否,手动 |
| Analyst 调用 | 否(用现成 findings) | **是**(ad-hoc 跑 analyst) |

## 重复部署同一 URL 的处理

```bash
WORKSPACE="workspace/$SLUG"
if [ -d "$WORKSPACE" ] && [ -f "$WORKSPACE/state.json" ]; then
    PHASE=$(jq -r .phase "$WORKSPACE/state.json")
    if [ "$PHASE" = "done" ] || [ "$PHASE" = "archived" ]; then
        echo "$SLUG 之前已部署完成/归档"
        echo "默认动作:跳过,不覆盖旧 state。若确认重跑,人工指定新 slug 或清理 workspace 后再跑。"
        exit
    elif [ "$PHASE" = "paused_for_human" ]; then
        # 提示用 /auto-recover OR 检查 pending_human/<slug>.md
        echo "$SLUG 等人手处理,见 pending_human/$SLUG.md"
        exit
    else
        # 是中途状态,等价于对该 slug 做 /auto-recover
        echo "$SLUG 在 phase=$PHASE,接续部署"
        # 跳到任务 4 的 phase dispatch
    fi
fi
```

## 反模式

- ❌ 不要无脑 rm -rf workspace/<slug>/ 重跑(可能丢已下完的权重)
- ❌ 新项目不要直接走 5 阶段而不先调 analyze_project(没拿到 size_gb 不知道 30B 阈值);接续项目则优先信旧 state,不重分析
- ❌ 不要在 analyze_project 报错时强行猜测 hf_repos(那种情况应该 raise 让用户给 URL 或手动 finding)
- ❌ **不要主 agent 自己 `Bash(git clone / hf download / pip install / python ...)`** — 用 `Task()` dispatch SubAgent。主 agent 的 Bash 仅限读 state.json / 写 meta.json / 调度类操作
- ❌ **不要在同一个 Task() 让 SubAgent 跨 phase 干活**(比如让 fetch-agent "顺手装个 pip")— phase 边界要硬
- ❌ **不要并行 dispatch 多个 SubAgent**(N=1,串行)— 带宽 / GPU 都是单一资源
- ❌ **不要 verify 失败时还跑 cleanup-agent** — 失败 case 的 workspace 是唯一现场,清掉就丢线索
- ❌ **不要 verify 失败就跳过 runbook-agent** — 失败 case runbook 对下次部署者(踩坑章节)同样有价值
- ❌ **不要 runbook / cleanup 跑完忘了把 `runbook_path` 透传给 write-recommendation** — 日报缺链接

## ChangeLog

- **2026-06-04** — 加 R9 hook 阈值说明 + 写报告前 artifact gate
  - 变更类型: 约束 / 流程
  - 影响范围: 主 agent 角色定位 / 任务 5
  - 动机: ControlFoley e2e 主 agent 内联 165 Bash / 0 Task,导致 verify.json/runbook.json/cleanup.json 缺失
  - 证据: [fixes/2026-06-03-r9-task-dispatch-still-bypassed-fix.md](../../../docs/superpowers/fixes/2026-06-03-r9-task-dispatch-still-bypassed-fix.md)
  - 验证: ⬜ 待验证(小型 /auto-deploy L1)
- **2026-06-04** — 收紧重复 `/auto-deploy` 的接续语义
  - 变更类型: 约束 / 流程
  - 影响范围: 任务 0.5 / 任务 1 / 任务 4 / 重复部署同一 URL
  - 动机: monitor 重复 launch 同一项目时,必须先读旧 `state.json` 接续,不能覆盖为新 intake
  - 验证: ⬜ 待验证(同 slug 非终态 fixture + /auto-deploy L1)
