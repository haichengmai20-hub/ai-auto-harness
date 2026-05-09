# Layer 4 测试指南（自组织：规划与协作）

本目录对应 CC1 清单中的 Layer 4（4.1 到 4.8）。

## 一次性前置条件

1. 进入仓库根目录并确保可运行 harness。
2. 新开一个干净会话，先执行 /clear，避免历史上下文干扰。
3. 建议先不要在真实业务目录执行破坏性命令，优先使用本目录中的沙箱和脚本。
4. 如果要测 4.7 worktree，请确认当前仓库是 git 工作区。

## 4.1 /plan 计划模式

### 指令模板
给我做一个三步任务：
- 第一步读取 test-harness 目录结构
- 第二步输出一个简短总结
- 第三步把总结写入 test-harness/test/layer4/plan_result.md
先进入 plan 模式，给出计划并等待我确认，不要直接执行。

### 通过标准
- 先输出计划而不是直接执行。
- 等你回复“确认执行”后才开始动手。

## 4.2 TodoWrite 待办清单

### 指令模板
请把“准备环境、执行命令、验证结果、收尾清理”维护成 todo 清单，任务进行时持续更新状态。

### 通过标准
- 清单项完整。
- 状态随执行过程发生变化（未开始、进行中、已完成）。

## 4.3 TaskCreate 后台任务

### 前置脚本
使用 task_scripts/sleep_10.sh

### 指令模板
在后台运行 test-harness/test/layer4/task_scripts/sleep_10.sh，并返回任务 id。

### 通过标准
- 成功创建后台任务。
- 能返回任务 id 或等价标识。

## 4.4 TaskList/Get 查看任务

### 指令模板
列出当前后台任务，并查看刚才第一个任务的输出。

### 通过标准
- 能看到任务状态（运行中/完成/失败）。
- 能读到任务输出内容。

## 4.5 TaskStop 停止任务

### 指令模板
停止刚才创建的后台任务。

### 通过标准
- 任务状态变为已停止或等价终止状态。
- 后续查询不再继续增长输出。

## 4.6 AgentTool 派发子 Agent

### 前置任务卡
- agent_tasks/task_a.md
- agent_tasks/task_b.md

### 严格前置条件（必须先做）
1. 新开会话并先执行 /clear。
2. 先在主线程创建统一起跑时间（barrier），建议为当前时间 + 15 秒。
3. barrier 文件路径固定为：/tmp/layer4_parallel_barrier_epoch.txt
4. 主线程必须在同一轮 assistant 回复中发起两个 AgentTool，不允许先等 A 返回再发 B。
5. 两个子任务都必须 run_in_background=true。

建议先执行的准备命令：

```bash
date -d '+15 seconds' +%s > /tmp/layer4_parallel_barrier_epoch.txt && cat /tmp/layer4_parallel_barrier_epoch.txt
```

### 指令模板
请在同一轮中一次性发起两个后台子 agent（禁止串行发起）：
- 子任务 A：严格按 test-harness/test/layer4/agent_tasks/task_a.md 执行，run_in_background=true
- 子任务 B：严格按 test-harness/test/layer4/agent_tasks/task_b.md 执行，run_in_background=true

要求：
1. 两个子 agent 都要先回显“读取到的任务卡标题第一行”。
2. 两个子 agent 都要按任务卡中的固定输出格式返回结果。
3. 主 agent 最后输出汇总，格式为：
	- 并行状态：并行/非并行
	- 子任务 A 结论：通过/失败
	- 子任务 B 结论：通过/失败
	- 总结：一句话

### 严格并行验证法（推荐）
为避免“看起来像串行”的错觉，4.6 统一按下面规则判定：

1. 两个子任务都必须输出：
	- start_epoch
	- end_epoch
	- duration_sec
2. 两个子任务都必须输出 barrier_epoch，并且值一致。
3. 两个子任务都必须执行固定工作段 sleep 20 秒（非 1-2 秒短任务）。
4. 使用重叠公式判断并行：
	- 若 `A.start_epoch < B.end_epoch` 且 `B.start_epoch < A.end_epoch`，则存在时间重叠，判定并行。
5. 计算总耗时交叉验证：
	- `wall_time = max(A.end, B.end) - min(A.start, B.start)`
	- 若 `wall_time < A.duration + B.duration - 5`（允许 5 秒误差），可进一步证明并行。
	- 若 `wall_time >= A.duration + B.duration - 5`，高概率是串行或伪并行。

建议在主 agent 汇总中补充：
- overlap_check: PASS/FAIL
- wall_time_sec: <数值>
- parallel_confidence: HIGH/MEDIUM/LOW
- same_barrier_check: PASS/FAIL
- single_turn_dispatch_check: PASS/FAIL

### 通过标准
- 至少出现并行子任务行为。
- A/B 均读取到正确任务卡（标题匹配）。
- A/B 均按固定格式返回结果并有汇总。
- overlap_check 为 PASS。
- same_barrier_check 为 PASS。
- single_turn_dispatch_check 为 PASS。

## 4.7 Worktree 隔离分支

### 安全前置
使用目录 worktree_sandbox，避免污染主目录。

### 指令模板
在当前仓库创建一个新的 worktree，分支名 l4-worktree-test，路径放到 test-harness/test/layer4/worktree_sandbox/l4-worktree-test。

### 通过标准
- worktree 创建成功。
- 新路径可见且和主工作区互不覆盖。

## 4.8 ScheduleCron 定时任务

### 前置脚本
使用 task_scripts/hourly_probe.sh

### 指令模板
注册一个每小时执行一次的定时任务，命令为 test-harness/test/layer4/task_scripts/hourly_probe.sh。

### 通过标准
- 成功返回任务注册信息（表达式、任务标识、命令）。
- 可查询到该定时任务存在。

### 备注
如果当前环境禁用了 cron 能力，标记为 N/A 并记录限制原因。

## 结果记录模板

| 编号 | 输入指令 | 预期 | 实际 | 结论 | 备注 |
|------|----------|------|------|------|------|
| 4.1 | /plan 流程 | 先计划后执行 |  |  |  |
| 4.2 | TodoWrite | 清单持续更新 |  |  |  |
| 4.3 | 后台 sleep 任务 | 创建成功 |  |  |  |
| 4.4 | 查询任务与输出 | 状态和输出可见 |  |  |  |
| 4.5 | 停止任务 | 成功停止 |  |  |  |
| 4.6 | 子 agent 并行 | A/B 有结果并汇总 |  |  |  |
| 4.7 | 创建 worktree | 新 worktree 独立可见 |  |  |  |
| 4.8 | 注册 cron | 注册成功可查询 |  |  |  |
