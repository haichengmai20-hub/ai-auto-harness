# AI Auto Harness Master Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`. Execute one phase plan at a time. Do not try to run the original full implementation plan in one session.

**Goal:** Build and validate AI Auto Harness as a cron-driven Claude Code platform for finding, deploying, repairing, verifying, and reporting AI projects.

**Architecture:** This master file is the execution index. Each phase plan owns one milestone, has its own development guidance, and has its own test setup. The original long plan remains a reference runbook, not the primary execution unit.

**Tech Stack:** Claude Code skills/agents/hooks, TypeScript/Bun for the Claude Code base, Python for `ai-daily-scan` MCP integration, bash for cron and operational probes.

**Reference Spec:** [2026-05-19-ai-auto-harness-design.md](../specs/2026-05-19-ai-auto-harness-design.md)

**Original Full Runbook:** [2026-05-19-ai-auto-harness-implementation.md](2026-05-19-ai-auto-harness-implementation.md)

---

## 📍 当前状态（活索引 — 每次工作后更新此节）

- **最后更新**：2026-05-27
- **版本**：v1.1（Phase 5 进行中）
- **一句话**：Phase −1~4 平台全部 ✅；Phase 5（runbook+cleanup）实现 + L1 测试 ✅，主流程串联（Task 5-13）⬜ pending
- **真实战绩**：3 个项目跑通（SongGeneration / OmniVoice / Hunyuan3D-2）
- **git**：本地 main 领先 upstream 19 commits，**未 push**
- **工作树**：干净（仅 `2026-05-26-roledrop-judge-pilot.md` 故意留 untracked，属外来工作线，不入本库）
- **下一步候选**：① push 到 Gitea ② cleanup runs/.cache 决策(见待办) ③ Phase 5 Task 5-13 串联 ④ 修 verify.json passed=null

---

## 🗂️ 记录规则（本项目如何记录进度 / 问题 / 方案 — 不新建文件，用好现成 4 个面）

| 要记什么 | 用哪个现成文件 | 纪律 |
|---|---|---|
| **进度**（做到哪了） | `git log` + 本文件「当前状态」节 + 下方 Phase Milestones 表 | 每个工作 session 结束必 commit（`ai-auto: <做了什么>`）；phase 状态变化时更新本文件 |
| **问题 + 修改方案** | `../retros/<date>-<topic>-retro.md` | 每轮测试/排查写一份 retro，用「问题 → 修复实施记录（回填 commit hash）」闭环格式 |
| **未解决 / 阻塞 / 待决策** | `../../../pending_human/<slug>.md` | 遇到卡点或需人决策即写（如 cleanup runs/.cache 的 A/B/C/D） |
| **跨项目踩坑** | `../../../memory/lessons/*.md` | 通用技术经验沉淀（torch-sm12 / hf-gated / flash-attn-build） |
| **设计** | `../specs/*.md` | 大改动先写 spec（或 addendum 引用原 spec） |

**每-session 仪式（3 步，防止记录滞后于现实）**：
1. 结束前 `git commit`（哪怕 WIP）—— git log 是零成本的权威进度记录
2. 若 phase 状态变了 → 更新本文件「当前状态」+ Milestones 表
3. 若发现新问题/卡点 → 追加 retro 或写 pending_human

---

## ✅ 已完成（设计 / 功能 / 事情）

### 已完成的设计
- **v1.0 主设计**：`../specs/2026-05-19-ai-auto-harness-design.md`（5 阶段流水线 + SubAgent 隔离 + 跨 cron 接续 + 失败兜底）
- **v1.1 硬约束 R1-R9**：`../../../.claude/CLAUDE.md`（workspace 隔离 / 禁 sleep loop / 串行带宽 / 用 hf / 主 agent 不亲自 bash 等）
- **Phase 5 设计**：`../specs/2026-05-25-runbook-and-cleanup-addendum.md`（runbook + cleanup，引用原 spec 不动它）

### 已有的功能（18 skill + 基础设施）
- **主流程 SubAgent（5+入口）**：`auto-daily`（主 agent）/ `auto-deploy`（手动单项目入口）/ `intake` / `fetch-weights` / `install-env` / `run-and-repair` / `verify`
- **失败兜底（2）**：`api-skeleton`（>30B / gated 无 token 走 API 骨架）/ `request-human-intervention`（写 pending_human）
- **报告 + 记忆（3）**：`write-recommendation`（日报）/ `verifier-corrector`（事实核验）/ `coverage-gaps`（盲区追踪）
- **运维（4）**：`auto-status` / `auto-recover` / `cost-analysis` / `preflight-gpu-disk`
- **Phase 5 新增（2）**：`write-deploy-runbook`（runbook-agent）/ `cleanup-deployed-workspace`（cleanup-agent）
- **基础设施**：claude-haha fork / `cron/{daily,launch_worker}.sh`（trap + PID + --append-system-prompt）/ PostToolUse python hook（R1/R4/R6/R9 实时违规检测）/ `state.json` 跨 cron 接续 / MCP 接 ai-daily-scan / `memory/lessons/`

### 已做的事情（按 commit）
| 阶段 | commit | 日期 |
|---|---|---|
| Phase −1~4 平台搭建 | `84763ae`→`4d8f88c` | 5/19-5/20 |
| baseline 对比修复 + e2e guide | `8dbe1d5`/`2c287e3` | 5/21 |
| v1.1 硬约束加固（R1-R9 + hook + cron + 6 skill） | `43e453e` | 5/26 提交 |
| Phase 5 实现（runbook + cleanup skill） | `9ee6fb3` | 5/26 提交 |
| Phase 5 测试与回溯（retro + 防护测试 + validate 脚本） | `42bdc5c` | 5/26 提交 |
| 回填进度记录（retro 闭环 + checkbox） | `d2f55eb` | 5/26 提交 |
- **Phase 5 L1 测试**：✅ 通过（$4.27 / 42 turns，runbook + cleanup dry_run 都对），retro 见 `../retros/2026-05-25-phase5-l1-test-retro.md`
- **G1-G4 防护测试**：✅ 5/5 PASS（`../../../pending_human/guard-test-report-2026-05-26.md`）
- **retro 15 条**：14 完全落地 + S-1 部分缓解（详见 retro §六 修复实施记录）

### 真实部署战绩（3 个不同模态项目跑通）
| 项目 | 类型 | 状态 | 产物 |
|---|---|---|---|
| SongGeneration | 4B 音乐生成 | ✅ done | 81.7s FLAC（run2+run3 resume 接续验证跨 cron 机制） |
| OmniVoice | 600+ 语言 TTS | ✅ done | `reports/2026-05-25-omnivoice.md` |
| Hunyuan3D-2 | 文/图 → 3D | ✅ done | `reports/2026-05-26-hunyuan3d-2.md` |

---

## ⬜ 待办（设计 / 功能 / 事情）

### 待完成的设计 / 计划（需决策才能动）
- **cleanup 不覆盖 `runs/<run-id>/.cache/`**（实测 22GB 残留）→ 待在 **A**(清自己 run cache) / **B**(清所有 done run) / **C**(独立 skill) / **D**(文档化周清) 中决策。建议先写进 `pending_human/`。
- **S-1 SKILL 约束根本解**：SubAgent 无法传 `--append-system-prompt`，导致 skill 规则被 LLM 自由发挥绕过。当前靠 `_template.md` 写死易错字段缓解；根本解需平台层改动，暂搁置。

### 待开发 / 测试的功能（Phase 5 Task 5-13，详见 `2026-05-25-phase-5-runbook-and-cleanup.md`）
- **Task 5-7**：主 agent 串联 —— `auto-deploy` / `auto-daily` 末尾接 runbook→cleanup dispatch；`write-recommendation` 接 `runbook_paths`
- **Task 8**：小项目（<5GB 权重）完整 e2e —— 验 intake→verify→runbook→cleanup→`archived`
- **Task 9**：cleanup 切 `dry_run=false`（验证 OK 后才切，真清磁盘）
- **Task 10-12**：`auto-status` / `auto-recover` / `auto-deploy` 适配 `archived` 终态
- **Task 13**：`settings.json` 加 deny 规则防 cleanup 越权

### 待做的事情
- **push 到 Gitea**（`http://192.168.1.227/maihaicheng/ai-auto-harness`，19 commits 未推）—— 外发操作，需用户确认
- **修 verify.json `passed=null`**：hunyuan3d-2 / omnivoice 日报写"已验证成功"，但 `results/verify.json.passed` 是 null，下游（auto-status / cleanup G4）会误判 —— 查 verify SubAgent 落盘逻辑

---

## Execution Order

Run these phase plans in order:

1. [Phase -1: Preflight And Risk Validation](2026-05-19-phase--1-preflight-risk.md)
2. [Phase 0: ai-daily-scan MCP Integration](2026-05-19-phase-0-ai-daily-scan-mcp.md)
3. [Phase 1: Harness Skeleton And Intake](2026-05-19-phase-1-harness-skeleton-intake.md)
4. [Phase 2: Fetch, Install, Run, Repair](2026-05-19-phase-2-fetch-install-run.md)
5. [Phase 3: Verify, Human Loop, Reporting](2026-05-19-phase-3-verify-report-human.md)
6. [Phase 4: Knowledge, Migration, Documentation](2026-05-19-phase-4-docs-migration.md)

## Execution Rules

- Finish and test the current phase before starting the next one.
- Keep commits phase-scoped. Prefer one commit per completed task when the task produces a coherent change.
- Do not perform destructive cleanup commands unless the phase plan explicitly marks them as manual approval steps and the user approves.
- For every phase, update the phase checklist only after the command output has been inspected.
- If a phase uncovers a design issue, update the phase plan before coding through it.

## Phase Milestones

| Phase | Milestone | 状态 | 证据（commit / 产物） |
|---|---|---|---|
| -1 | Disk and Claude Code runtime risks understood | ✅ | `9ffae0b`（settings+hooks）+ `preflight-gpu-disk` skill + R3 wall-clock |
| 0 | `ai-daily-scan` can emit findings and serve MCP tools | ✅ | harness 调 `mcp__ai_daily_scan__*`，经 3 次部署验证（ai-daily-scan 侧 pytest 以该仓为准） |
| 1 | `ai-auto-harness` skeleton can intake one candidate | ✅ | `41febcf`「Phase 1 端到端就绪」 |
| 2 | Candidate can fetch weights, install env, and run/repair | ✅ | `1b1a2a6` + 3 项目 fetch/install/run 跑通 |
| 3 | MVP can verify, report, and record outcomes | ✅ | `c01ceb3` + `reports/` + outcomes |
| 4 | Lessons, migration notice, and docs are complete | ✅ | `4d8f88c` + README 全覆写 + `memory/lessons/` |
| 5 | Deploy runbook 沉淀 + workspace cleanup | 🟡 实现+L1 ✅，串联(Task 5-13) ⬜ | `9ee6fb3`/`42bdc5c`；详见 `2026-05-25-phase-5-runbook-and-cleanup.md` |

## Stop Conditions

Stop the phase and ask for review when any of these happen:

- Disk free falls below 100GB.
- A gated model requires manual license acceptance.
- A command wants to delete project workspaces, model weights, or Git history.
- A Claude Code behavior differs from the assumption in the design spec.
- A phase requires changing more than one repo in a single task without a test boundary.

