# AI Auto Harness — Project Context

你正在 `/root/ai-auto-harness/` 这个工作目录中运行。这是一个**基于 Claude Code 源码的自定义 harness**,目标是 cron-driven 地自动发现 AI 项目信号、自动部署、自动验证、产出公司视角建议。

## 硬约束(必须遵守)

| 维度 | 阈值 |
|---|---|
| GPU 单卡占用 | 已用 ≥ 25GB(31.8GB total)拒动 |
| GPU 叠加预估 | 叠加后剩余必须 ≥ 2GB |
| 磁盘 free | 拉权重前 free ≥ (估算总大小 + 50GB safety) |
| 模型规模 | self-host 目标 ≤ 30B 参数;超过走 api-skeleton |
| torch sm 兼容 | wheel 必须含 sm_12.0(5090) |
| 并发项目数 | 单次 cron run N=1 |
| 修复循环上限 | 同阶段 max 3 轮 LLM 决策后 raise pending_human |

## 工作流(主 agent / `/auto-daily`)

1. 接续扫:`workspace/*/state.json` phase ∉ {done, paused_for_human}
2. 项目选择:接续优先 OR scan_today → 按 30B/blacklist/gated 过滤
3. 部署流水线:按 state.phase 串行 dispatch 5 SubAgent
4. 写报告 + MCP `record_outcome` 回填

## 关键路径

- 设计文档:`docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md`
- 实施计划:`docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`
- 主 skill:`.claude/skills/ai-auto/daily-auto.md`
- 5 SubAgent skills:`.claude/skills/ai-auto/{intake,fetch-weights,install-env,run-and-repair,verify}.md`
- 项目工作目录:`workspace/<slug>/`
- 经验积累:`memory/lessons/*.md`

## SubAgent 隔离

每个项目部署用 5 个 SubAgent 串行,每个 SubAgent 独立 context.
SubAgent 5(verify)**禁止读** state.json 的 run_result 字段 — 独立判定原则。

## 不要做

- 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py` — 那是 SubAgent 的事
- 不要 max_turns > 3 在 run-and-repair 阶段(写 pending_human 比硬试好)
- 不要污染全局 HF cache — 每个项目用 `HF_HOME=workspace/<slug>/.cache/huggingface`
- 不要在 verify 阶段修问题 — 只判定
