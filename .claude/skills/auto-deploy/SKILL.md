---
name: auto-deploy
description: 手动跑单项目部署 — /auto-deploy <github_url> 触发,跳过 scan pick 直接对该 URL 走 5 阶段流水线
allowed-tools: [Read, Write, Bash, Task, mcp__ai_daily_scan__*]
---

# auto-deploy

`/auto-deploy <github_url>` 触发本 skill。**手动单项目场景**,不走 scan pick。

参数会在 `$ARGUMENTS` 里(单个 github URL,可能含尾部 query string)。

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

# 走 daily-auto skill 里的 phase dispatch 逻辑
按 state.phase 顺序 dispatch:
    null → intake
    fetching → fetch-weights
    installing → install-env
    running → run-and-repair
    verifying → verify

任一 blocked / paused_for_human / paused_in_progress → 跳到任务 5
```

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
