---
description: AI Auto Harness 每日工作流入口 — cron 在 10:30 触发
---

调用 `daily-auto` skill(`.claude/skills/ai-auto/daily-auto.md`)。

按 daily-auto 的 4 个任务执行:
1. 接续扫(workspace/*/state.json)
2. 项目选择(接续优先 OR scan_today → 过滤排序)
3. 部署流水线(按 state.phase 串行 dispatch 5 阶段 SubAgent)
4. 写报告 + MCP record_outcome 回填
