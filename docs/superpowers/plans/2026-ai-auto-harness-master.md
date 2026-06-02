# AI Auto Harness Master Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`. Execute one phase plan at a time. Do not try to run the original full implementation plan in one session.

**Goal:** Build and validate AI Auto Harness as a cron-driven Claude Code platform for finding, deploying, repairing, verifying, and reporting AI projects.

**Architecture:** This master file is the execution index. Each phase plan owns one milestone, has its own development guidance, and has its own test setup. The original long plan remains a reference runbook, not the primary execution unit.

**Tech Stack:** Claude Code skills/agents/hooks, TypeScript/Bun for the Claude Code base, Python for `ai-daily-scan` MCP integration, bash for cron and operational probes.

**Reference Spec:** [2026-05-19-ai-auto-harness-design.md](../specs/2026-05-19-ai-auto-harness-design.md)

**Original Full Runbook:** [2026-05-19-ai-auto-harness-implementation.md](2026-05-19-ai-auto-harness-implementation.md)

---

## 📍 当前状态（活索引 — 每次工作后更新此节）

- **最后更新**：2026-06-02（ControlFoley e2e retro:P0 hook run-id 修复 + P2 fetch hf 1.x 现代化）
- **版本**：v1.1（Phase 5 进行中）
- **一句话**：Phase −1~4 平台全部 ✅;Phase 5(runbook+cleanup)实现 + L1 测试 + T5-T7 主流程串联 ✅;**P0 hook 真因修复**(SessionStart 覆盖 run-id 致 R1/R4/R6/R9 实时约束自上线起失效,已修 + 加事后纪律审计器)✅;P2 fetch hf 1.x 现代化 ✅
- **真实战绩**：3 个项目跑通（SongGeneration / OmniVoice / Hunyuan3D-2）;ControlFoley e2e 全流程跑通并产出 19 条 retro
- **git**：本地 main 领先 upstream,**未 push**
- **工作树**：本任务相关已 commit;遗留无关改动 `src/utils/model/*` + `monitor-ride-along/` skill 属外来工作线(非本任务,未动)
- **下一步候选**：① 端到端重跑 e2e 验证 hook 落点 + discipline-report(P0 修复实战确认) ② P1 MCP scan 真调用改造(跨 ai-daily-scan 仓库) ③ P9 架构级状态机/非法转换检测 ④ push 到 Gitea ⑤ 清理历史孤儿 `runs/<时间戳-pid>/` 目录

---

## 🌐 全局索引（spec / plan / fix 三栏 — 接手 AI 从这里入手）

### 当前生效 Spec

| 文件 | 一句话 | 状态 |
|---|---|---|
| [specs/2026-05-19-ai-auto-harness-design.md](../specs/2026-05-19-ai-auto-harness-design.md) | v1.0 主设计 — 5 阶段流水线 + SubAgent 隔离 + 跨 cron 接续 | 生效 |
| [specs/2026-05-25-runbook-and-cleanup-addendum.md](../specs/2026-05-25-runbook-and-cleanup-addendum.md) | Phase 5 增量 — runbook + cleanup,引原 spec 不动正文 | 生效 |
| [specs/2026-05-27-spec-plan-governance.md](../specs/2026-05-27-spec-plan-governance.md) | spec/plan 管控规则 + ChangeLog 触发条件 | 生效 |
| [specs/2026-05-27-fix-records-governance.md](../specs/2026-05-27-fix-records-governance.md) | fix 记录规则 + 模板 + 闭环流程 | 生效 |

### 当前生效 Plan

| 文件 | 一句话 | 状态 |
|---|---|---|
| **本文件**(Master Plan) | 活索引 — 每 session 更新 | 生效 |
| [plans/2026-05-19-phase--1-preflight-risk.md](2026-05-19-phase--1-preflight-risk.md) | Phase -1 风险预审 | ✅ 完成 |
| [plans/2026-05-19-phase-0-ai-daily-scan-mcp.md](2026-05-19-phase-0-ai-daily-scan-mcp.md) | Phase 0 ai-daily-scan MCP 集成 | ✅ 完成 |
| [plans/2026-05-19-phase-1-harness-skeleton-intake.md](2026-05-19-phase-1-harness-skeleton-intake.md) | Phase 1 骨架 + intake | ✅ 完成 |
| [plans/2026-05-19-phase-2-fetch-install-run.md](2026-05-19-phase-2-fetch-install-run.md) | Phase 2 fetch/install/run | ✅ 完成 |
| [plans/2026-05-19-phase-3-verify-report-human.md](2026-05-19-phase-3-verify-report-human.md) | Phase 3 verify + report + 人介入 | ✅ 完成 |
| [plans/2026-05-19-phase-4-docs-migration.md](2026-05-19-phase-4-docs-migration.md) | Phase 4 文档 + lessons | ✅ 完成 |
| [plans/2026-05-25-phase-5-runbook-and-cleanup.md](2026-05-25-phase-5-runbook-and-cleanup.md) | Phase 5 runbook + cleanup | 🟡 实现+L1 ✅,Task 5-13 串联 ⬜ |
| [plans/2026-05-25-phase-5-task-3-and-4-l1-test-prompt.md](2026-05-25-phase-5-task-3-and-4-l1-test-prompt.md) | Phase 5 Task 3+4 L1 测试 prompt | ✅ 跑过 |
| [plans/2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md](2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md) | Phase 5 G1-G4 防护故意失败测试 prompt | ✅ 跑过(5/5 PASS) |

### Fix 索引(架构改善事实链)

> 完整 fix 目录见 [fixes/README.md](../fixes/README.md)（共 29 条）。每条 fix 含部署项目 + run_id 来源,可精确追溯。
> 注:2026-05-29 一批 fix(#15–#25)见 fixes/README.md,本表只列里程碑级;2026-06-02 ControlFoley e2e retro 4 条已补入下表顶部。

| 日期 | Fix | 部署项目 | 影响 | commit | 状态 |
|---|---|---|---|---|---|
| 2026-06-02 | [hook-runid-clobber-fix](../fixes/2026-06-02-hook-runid-clobber-fix.md) **P0** | controlfoley | SessionStart 覆盖 run-id → hook 写孤儿目录(R1/R4/R6/R9 失效真因)+ `validate-run-discipline.sh` | `3bb1280` | ✅ 已闭环 |
| 2026-06-02 | [fetch-weights-hf1.x-modernization-fix](../fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md) | controlfoley | 去 `--resume-download` + `HF_HUB_ENABLE_HF_TRANSFER`→Xet | `b0a97bf` | ✅ 已闭环 |
| 2026-06-02 | [concurrent-download-zombie-guard-fix](../fixes/2026-06-02-concurrent-download-zombie-guard-fix.md) | controlfoley | 并发 hf download 防护 + 僵尸 hf 保守审计 | `b0a97bf` | ✅ 已闭环 |
| 2026-06-02 | [runbook-cleanup-artifact-accuracy-fix](../fixes/2026-06-02-runbook-cleanup-artifact-accuracy-fix.md) | hunyuan3d-2 + omnivoice | runbook cost=null/duration + cleanup weights 白名单 | (P6/P7 收尾) | ✅ 已闭环 |
| 2026-05-27 | [verify-schema-enforcement-fix](../fixes/2026-05-27-verify-schema-enforcement-fix.md) | hunyuan3d-2 + omnivoice + song-generation-run2 | `verify/SKILL.md` + `scripts/validate-verify.sh` | (本 session) | ✅ 已闭环 |
| 2026-05-26 | [phase5-l1-retro-15-fixes](../fixes/2026-05-26-phase5-l1-retro-15-fixes.md) | song-generation-run2 (L1 test) | runbook+cleanup 两 SKILL + 2 validate 脚本 | `42bdc5c` | ✅ 已闭环(14/15) |
| 2026-05-26 | [runs-cache-cleanup-decision-fix](../fixes/2026-05-26-runs-cache-cleanup-decision-fix.md) | song-generation(run2)+ song-generation | `cleanup/SKILL.md` 第 2.5 步 | `42bdc5c` | ✅ 已闭环 |
| 2026-05-26 | [v1.1-hardening-fix](../fixes/2026-05-26-v1.1-hardening-fix.md) | song-generation(run2 + run3) | R1-R9 + PostToolUse hook + cron 防僵尸 | `43e453e` | ✅ 已闭环 |
| 2026-05-21 | [baseline-3-blockers-fix](../fixes/2026-05-21-baseline-3-blockers-fix.md) | song-generation(baseline) | R5 + R6 + R7 + preflight 必调用 | `8dbe1d5` | ✅ 已闭环 |
| 2026-05-21 | [agent-isolation-fix](../fixes/2026-05-21-agent-isolation-fix.md) | song-generation(run2) | R1 + R9 + verify 独立判定 | `43e453e` | ✅ 已闭环 |
| 2026-05-21 | [sleep-loop-discipline-fix](../fixes/2026-05-21-sleep-loop-discipline-fix.md) | song-generation(run2) | R4(5 个子规则)+ PostToolUse 检测 | `43e453e` | ✅ 已闭环 |
| 2026-05-19 | [cron-driven-architecture-fix](../fixes/2026-05-19-cron-driven-architecture-fix.md) | (架构立项,无具体 run) | 5 阶段流水线 + state.json 接续 | `84763ae` | ✅ 已闭环 |

### 相关 Retro(phase 主动复盘 — 与 fix 互补)

| 文件 | 描述 |
|---|---|
| [retros/2026-05-25-phase5-l1-test-retro.md](../retros/2026-05-25-phase5-l1-test-retro.md) | Phase 5 L1 测试 15 条改善点 → 已逐条闭环为 fix |

---

## 🗂️ 记录规则（本项目如何记录进度 / 问题 / 方案 / 架构改善）

> **2026-05-27 更新**:加入 fix 记录体系。完整规则见两份 governance 文档:[spec-plan-governance](../specs/2026-05-27-spec-plan-governance.md) + [fix-records-governance](../specs/2026-05-27-fix-records-governance.md)。

| 要记什么 | 用哪个文件 | 纪律 |
|---|---|---|
| **进度**(做到哪了) | `git log` + 本文件「当前状态」节 + 下方 Phase Milestones 表 | 每个工作 session 结束必 commit;phase 状态变化时更新本文件 |
| **架构改善**(spec/SKILL 影响) | `../fixes/<date>-<topic>-fix.md`(新建) | **先写 fix → 再改 spec/SKILL → 加 ChangeLog**(避免和开发冲突)。详见 fix-records-governance |
| **Phase 主动复盘** | `../retros/<date>-<topic>-retro.md` | phase 完成时写,改善点闭环时**生成对应 fix** |
| **未解决 / 阻塞 / 待决策** | `../../../pending_human/<slug>.md` | 遇到卡点或需人决策即写;闭环后可升级为 fix |
| **跨项目踩坑** | `../../../memory/lessons/*.md` | 通用技术经验沉淀(torch-sm12 / hf-gated / flash-attn-build);fix 多次复现可提升 |
| **项目内运行时修复** | `workspace/<slug>/logs/fixes.log` | LLM 试跑时自动 append,**不是平台 fix**(不入 fixes/) |
| **设计** | `../specs/*.md` | 大改动先写 spec(或 addendum 引用原 spec);末尾必加 ChangeLog |
| **SubAgent 规则** | `.claude/skills/*/SKILL.md` | 由 fix 驱动的硬约束改动 → 加 ChangeLog;纯实现/错字 → 仅 git commit |

**每-session 仪式(4 步,防止记录滞后于现实)**:
1. 结束前 `git commit`(哪怕 WIP)— git log 是零成本的权威进度记录
2. 若**有架构改善** → **先写 fix.md** → 再改 spec/SKILL → 被改文件加 ChangeLog 条目
3. 若 phase 状态变了 → 更新本文件「当前状态」+ Milestones 表 + Fix 索引
4. 若发现新问题/卡点 → 追加 retro 或写 pending_human

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
- **S-1 SKILL 约束根本解**：SubAgent 无法传 `--append-system-prompt`，导致 skill 规则被 LLM 自由发挥绕过。当前靠 `_template.md` 写死易错字段缓解；根本解需平台层改动，暂搁置。

### 已落地的设计决策（曾经的待决策项 — 留档供回溯）
- **cleanup `runs/<run-id>/.cache/` 处理**（实测 22GB 残留)：用户 2026-05-26 选 **A**（cleanup 同步清自己 run 的 cache，**不**递归清其他 run）→ 已在 `cleanup-deployed-workspace/SKILL.md` 第 2.5 步实现，cleanup.json 加 `run_cache_freed_bytes` / `run_cache_removed` 细分字段。commit `42bdc5c`

### 待开发 / 测试的功能（Phase 5 Task 5-13，详见 `2026-05-25-phase-5-runbook-and-cleanup.md`）
- **Task 5-7**：主 agent 串联 —— `auto-deploy` / `auto-daily` 末尾接 runbook→cleanup dispatch；`write-recommendation` 接 `runbook_paths`
- **Task 8**：小项目（<5GB 权重）完整 e2e —— 验 intake→verify→runbook→cleanup→`archived`
- **Task 9**：cleanup 切 `dry_run=false`（验证 OK 后才切，真清磁盘）
- **Task 10-12**：`auto-status` / `auto-recover` / `auto-deploy` 适配 `archived` 终态
- **Task 13**：`settings.json` 加 deny 规则防 cleanup 越权

### 待做的事情
- **push 到 Gitea**（`http://192.168.1.227/maihaicheng/ai-auto-harness`，19 commits 未推）—— 外发操作，需用户确认
- ~~**修 verify.json `passed=null`**~~：✅ 2026-05-27 已处理。根因不是 null,是 LLM 自创 schema 完全缺 `passed` 字段(`status+checks` / `status+verdict` 自创格式)。修法:(1) 回填 hunyuan3d-2 + omnivoice 的 `passed:true`(基于日报已确认)(2) 强化 `verify/SKILL.md` 加 jq -e 自检 + 反模式列表(3) 新建 `scripts/validate-verify.sh` 机器拦截。Task 5-7 串联跑时会重触 verify,新落盘自然走完整 6 字段 schema

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

