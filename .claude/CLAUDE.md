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

## 落盘约定(每个 SubAgent 必须遵守)

平台所有 SubAgent 的中间产物落盘到这两类位置:

### 项目级(跨 cron 累积,看 slug 即可找到)

```
workspace/<slug>/
├── state.json                      总状态(已有)
├── logs/                           [集中日志,跨 cron append]
│   ├── intake.log                  Stage 1: clone + 读 README + preflight 的 bash stdout/stderr
│   ├── fetch_weights.log           Stage 2: huggingface-cli download 的完整输出
│   ├── install_env.log             Stage 3: venv build + pip install 的完整输出
│   ├── run_and_repair.log          Stage 4: 每轮试跑的 stdout/stderr(多轮 append)
│   ├── verify.log                  Stage 5: smoke test 的完整输出
│   └── fixes.log                   [累积]agent 修复轨迹(每次修复 append 一行)
└── results/                        [最新阶段 result JSON,覆写]
    ├── intake.json                 同 SubAgent return,workspace 侧最新一份
    ├── fetch.json
    ├── install.json
    ├── environment.json            torch / cuda / python / sm_arch 快照
    ├── weights.json                hf_repos 下载元数据(下完时间 / 大小 / 是否 resume)
    ├── run.json                    RunResult
    └── verify.json                 VerifyState
```

### Run 级(每次 cron run 一份独立快照,审计用)

```
runs/<run-id>/
├── meta.json                       run 元数据
├── decisions.md                    主 agent + 各 SubAgent 写的关键决策
├── intake.json / fetch.json / ...  各 SubAgent 本次 run 的返回(快照,不覆写)
└── transcript.jsonl                tool_use 流(--bare 模式下 skill 自己 append 写入)
```

**双写原则**:每个 SubAgent return 时**同时写两份**:
- `workspace/<slug>/results/<phase>.json` — 覆写(最新)
- `runs/<run-id>/<phase>.json` — append(本次 run 独立快照)

日志只写 `workspace/<slug>/logs/<phase>.log`(累积 append,不覆写).

## 不要做

- 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py` — 那是 SubAgent 的事
- 不要 max_turns > 3 在 run-and-repair 阶段(写 pending_human 比硬试好)
- 不要污染全局 HF cache — 每个项目用 `HF_HOME=workspace/<slug>/.cache/huggingface`
- 不要在 verify 阶段修问题 — 只判定
