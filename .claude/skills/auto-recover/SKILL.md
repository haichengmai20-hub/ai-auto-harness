---
name: auto-recover
description: 强制扫接续 — 忽略 scan,只把 in_progress 项目跑完;用于"今天不挑新项目,只跑昨天没跑完的"
allowed-tools: [Read, Write, Bash, Task]
---

# auto-recover

`/auto-recover` 触发本 skill。

**典型场景**:
- 昨天 cron 跑到 fetching 50% 时被 cron 时间预算截断(state.paused_in_progress=true)
- 你想现在补一下,把它跑完
- 但**不想**今天又挑新项目(避免冲突)

## 与 /auto-daily 的差异

| 维度 | /auto-daily | /auto-recover |
|---|---|---|
| 接续 in_progress | 优先,但若无则 pick 新项目 | **只**接续,绝不 pick 新项目 |
| 调用 scan | 是(若无 in_progress 时) | **从不**调 |
| 适用场景 | cron 每日触发 | 手动补救 / 调试 |

## 工作流

### 任务 0:初始化(同 auto-daily)

```bash
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"
RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"
mkdir -p "runs/$RUN_ID"
echo "$RUN_ID" > "runs/.current_run_id"
echo "{\"started_at\":\"$(date -Iseconds)\",\"run_id\":\"$RUN_ID\",\"trigger\":\"/auto-recover\"}" > "runs/$RUN_ID/meta.json"
```

### 任务 1:扫 in_progress

```bash
in_progress=$(find workspace -maxdepth 2 -name state.json -exec jq -c 'select(.phase != "done" and .phase != "paused_for_human") | {slug, phase, started_at}' {} \; 2>/dev/null)
```

**如果没有 in_progress**:
```
echo "无 in_progress 项目可接续"
echo "提示:用 /auto-daily 触发常规流程(挑新项目)"
echo "     或 /auto-deploy <url> 手动指定项目"
退出(state.phase 已经 done 的不再动)
```

**如果有 in_progress**:选最早 `started_at` 的接续(同 /auto-daily 任务 2 的"接续"分支).

### 任务 2:dispatch 接续阶段 SubAgent

读项目 state.json 决定 phase → 派对应 SubAgent(同 /auto-daily 任务 3 完整 phase dispatch 逻辑).

特别处理:

- `paused_in_progress=true` 的项目(fetch-weights 中途暂停):
  → dispatch `fetch-weights` SubAgent(它会读 state.fetch_state 自动 resume)
- `paused_for_human` 的项目:
  → **不接续**(等人手处理 → 删 pending_human/<slug>.md 后才能重新跑)
  → 跳过这个项目,看下一个

### 任务 3:写报告 + 回填

同 /auto-daily 任务 4 调 write-recommendation skill。

## 重置 paused_for_human 的协议

人手处理完一个项目要 unpause:

```bash
# 1. 处理完该项目的问题(配 HF_TOKEN / 释放 GPU / 等等)
# 2. 删 pending_human 文件
rm /root/ai-auto-harness/pending_human/<slug>.md
# 3. 调 /auto-recover 重新尝试(状态会从 state.phase 之前的阶段继续)
```

主 agent 接续 paused_for_human 项目时的逻辑(已在 daily-auto 体现):

```bash
if [ ! -f "pending_human/$SLUG.md" ] && [ "$PHASE" = "paused_for_human" ]; then
    # 人手处理完了(文件删了),重置 state.phase 到 paused_for_human 之前的阶段
    PREV_PHASE=<从 state.phases_done 最后一项推断,见下>
    jq --arg p "$PREV_PHASE" '.phase = $p
        | .resumed_from_paused_for_human_at = "'$(date -Iseconds)'"
        | .pending_human = null' \
       "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
fi
```

`PREV_PHASE` 计算:phases_done 倒数第一项就是上次成功完成的阶段,下一项就是要重试的:

```
phases_done = ["intake"] → resume from "fetching"
phases_done = ["intake", "fetch-weights"] → resume from "installing"
phases_done = ["intake", "fetch-weights", "install-env"] → resume from "running"
```

## 反模式

- ❌ 不要在 /auto-recover 里调 scan_today()(它的语义就是"不挑新项目")
- ❌ 不要强行 unpause(必须人手先删 pending_human/<slug>.md 才进入 unpause 流程)
- ❌ 不要并行接续多个 in_progress(MVP N=1 串行,选最早的一个)
