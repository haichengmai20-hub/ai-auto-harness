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

1. **路由决策**:30B / gated / 复用 workspace 三分支
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

### 任务 1:ad-hoc 分析

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

# 写 state.json
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

# 走 phase dispatch 逻辑 — 必须用 Task() 工具,严禁主 agent 自己 bash
# 每个 phase 一次 Task() 调用,prompt 里只传该 phase 必需的输入

# Phase 1: intake
Task(
    subagent_type="intake-agent",
    description="intake <slug>",
    prompt=f"""
slug: {SLUG}
github_url: {ARGUMENTS}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}
hf_repos: {finding['hf_repos']}
gated_repos: {finding['gated_repos']}
estimated_weight_size_gb: {finding['estimated_weight_size_gb']}

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
hf_repos: {finding['hf_repos']}
workspace_path: workspace/{SLUG}
run_id: {RUN_ID}

按 fetch-weights skill 跑完(用 hf download + HF_TOKEN + HF_HUB_ENABLE_HF_TRANSFER=1)。
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

# 任一 blocked / paused_for_human / paused_in_progress → 跳到任务 5,写报告
```

**关键规则**:每个 Task() 返回后,主 agent 必须:
1. 读 `workspace/<slug>/results/<phase>.json` 确认 SubAgent 落盘
2. 更新 `workspace/<slug>/state.json`:`phases_done += ["<phase>"]`, `phase = "<next>"`,`updated_at = now()`
3. 若 SubAgent 返回 blocked / paused → 不 dispatch 下一个,直接跳到任务 5

### 任务 5:写报告 + 回填

调 **write-recommendation** skill,同 auto-daily 任务 4。

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
| 接续 | 是,扫 in_progress | **不接续**,每次都新跑(若重复 URL 会撞 workspace,需提示用户) |
| cron 触发 | 是 | 否,手动 |
| Analyst 调用 | 否(用现成 findings) | **是**(ad-hoc 跑 analyst) |

## 重复部署同一 URL 的处理

```bash
WORKSPACE="workspace/$SLUG"
if [ -d "$WORKSPACE" ] && [ -f "$WORKSPACE/state.json" ]; then
    PHASE=$(jq -r .phase "$WORKSPACE/state.json")
    if [ "$PHASE" = "done" ]; then
        # 已部署过,询问用户(或直接接受 ad-hoc 重新部署):
        echo "$SLUG 之前已部署完成"
        echo "选项:"
        echo "  1. 跳过(用 'rm -rf $WORKSPACE' 后重跑可强制)"
        echo "  2. 跳到 verify 重新验证"
        echo "  3. 用 /auto-recover 接续(若是 paused_for_human)"
        # 默认动作:报告"已部署"并退出(让用户决定)
        exit
    elif [ "$PHASE" = "paused_for_human" ]; then
        # 提示用 /auto-recover OR 检查 pending_human/<slug>.md
        echo "$SLUG 等人手处理,见 pending_human/$SLUG.md"
        exit
    else
        # 是中途状态,等价于 /auto-recover
        echo "$SLUG 在 phase=$PHASE,接续部署"
        # 跳到任务 4 的 phase dispatch
    fi
fi
```

## 反模式

- ❌ 不要无脑 rm -rf workspace/<slug>/ 重跑(可能丢已下完的权重)
- ❌ 不要直接走 5 阶段而不先调 analyze_project(没拿到 size_gb 不知道 30B 阈值)
- ❌ 不要在 analyze_project 报错时强行猜测 hf_repos(那种情况应该 raise 让用户给 URL 或手动 finding)
- ❌ **不要主 agent 自己 `Bash(git clone / hf download / pip install / python ...)`** — 用 `Task()` dispatch SubAgent。主 agent 的 Bash 仅限读 state.json / 写 meta.json / 调度类操作
- ❌ **不要在同一个 Task() 让 SubAgent 跨 phase 干活**(比如让 fetch-agent "顺手装个 pip")— phase 边界要硬
- ❌ **不要并行 dispatch 多个 SubAgent**(N=1,串行)— 带宽 / GPU 都是单一资源
