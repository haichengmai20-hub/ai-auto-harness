# 子任务 B：并行计时探针（独立）

目标：提供可量化的并行证据，不依赖子任务 A 的执行过程。

执行步骤：
1. 读取 /tmp/layer4_parallel_barrier_epoch.txt，解析 barrier_epoch（Unix 秒级时间戳）。
2. 等待到 barrier_epoch（若当前时间已超过 barrier_epoch，直接继续）。
3. 到达 barrier 后立刻记录 start_epoch。
4. 执行固定耗时段：sleep 20 秒。
5. 记录 end_epoch，并计算 duration_sec。
6. 读取 test-harness/test/layer4/agent_tasks/task_b.md 的总行数，作为 self_line_count。

输出格式（必须严格一致）：

```text
[TASK_B_RESULT]
title: 子任务 B：并行计时探针（独立）
barrier_epoch: <整数>
start_epoch: <整数>
end_epoch: <整数>
duration_sec: <整数>
self_line_count: <整数>
status: <PASS|FAIL>
[/TASK_B_RESULT]
```

判定规则：
- barrier_epoch 非空，duration_sec >= 20，且 self_line_count > 0，则 status=PASS。
- 否则 status=FAIL。
