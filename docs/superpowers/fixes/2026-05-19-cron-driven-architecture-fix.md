# Cron-driven 架构立项 — 5 阶段 SubAgent 流水线 + state.json 接续

## 元信息

- **Fix ID**: `2026-05-19-cron-driven-architecture-fix`
- **创建日期**: 2026-05-19(回填于 2026-05-28)
- **级别**: P0(架构立项,所有后续 fix 的根基)
- **状态**: 已闭环
- **负责人 / session**: 用户 + 5/19 立项 session

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | **N/A 仅平台架构立项**(尚无具体项目部署) |
| **触发 run_id** | N/A |
| **触发时间** | 2026-05-19(立项日) |
| **触发阶段** | 架构 / 立项(pre-deployment) |
| **workspace 路径** | N/A |
| **runs 路径** | N/A |

---

## 现象

> 立项 fix — 不是问题修复而是**架构决策记录**,放在 fix 体系是为了后续所有架构 fix 都有源头可追。

- 决策 1: AI 项目自动发现 → 部署 → 验证 → 回填 — 这条长链路要怎么实现?
- 决策 2: 单 session 跑完是否可行?— 否(长任务 + token 上限 + cron 周期触发更稳)
- 决策 3: 各阶段是否要拆 SubAgent?— 是(context 隔离 + 职责单一)
- 决策 4: 跨 cron run 接续怎么做?— state.json + phase 状态机
- 决策 5: 失败兜底?— pending_human + paused_in_progress(可接续) + blocked(资源不足)

---

## 影响

- **影响范围**: 整个 ai-auto-harness 项目架构
- **影响下游**: 所有 SubAgent / 所有 cron 机制 / 所有 fix
- **严重程度**: P0 — 立项决定一切

---

## 根因(决策动机)

> 不是 bug 性"根因",而是为何选这个架构。

- 选 cron-driven(非长 session)的理由:
  - Claude Code session 长 = token 烧得快 + 上下文容易乱
  - cron 周期触发 = 自然节奏 + 每次小 context 跑 + 跨 run 接续
- 选 5 阶段 SubAgent 流水线(intake / fetch-weights / install-env / run-and-repair / verify)的理由:
  - 每阶段职责单一 → context 不重叠 → SubAgent 内集中精力
  - 每阶段产物落 `workspace/<slug>/results/<phase>.json` + `logs/<phase>.log` → 跨 run 可接续
  - SubAgent 5(verify)**禁止读** state.json 的 run_result(独立判定原则) → 防自我证明
- 选 state.json 接续的理由:
  - 单一信息源 → monitor / 主 agent / 接手 AI 都看同一份
  - phase 状态机(`scanning|intake|fetch|install|run|verify|done|paused_*|blocked_*`)清晰

---

## 修复方案(架构落地)

### 设计层(立项时一次性写完)

- [x] `docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md`:5 阶段流水线 + SubAgent 隔离 + 跨 cron 接续 + 失败兜底
- [x] `docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`:实施计划(后改为参考 runbook,执行单元拆到 phase plan)
- [x] 6 个 phase plan(phase -1 ~ phase 4)

### 实现层

- [x] `.claude/skills/auto-daily/` 主 agent skill(`/auto-daily` 命令入口)
- [x] 5 个 SubAgent skill(intake/fetch-weights/install-env/run-and-repair/verify)
- [x] `cron/{daily,launch_worker}.sh`(cron 触发入口)
- [x] `.claude/CLAUDE.md` 项目上下文 + 落盘约定

---

## 验证步骤

1. Phase -1 ~ phase 4 全部 ✅(checkbox 在各 phase plan)
2. SongGen e2e 试跑 2 次 验证整体流水线(虽然暴露 R1-R9 缺失,但架构本身验证通过)

---

## 修复结果

- **状态**: ✅ 立项完成,架构持续演进(v1.0 → v1.1 → Phase 5)
- **commit hash**: `84763ae`("初始设计文档 + 实施计划 + 平台 .gitignore")

---

## 证据指针

- 主 spec: `docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md`
- 实施 plan: `docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`
- 主 agent skill: `.claude/skills/auto-daily/SKILL.md`
- 5 SubAgent skill: `.claude/skills/{intake,fetch-weights,install-env,run-and-repair,verify}/SKILL.md`
- 状态机: `state.json` schema(在 spec 内)

---

## 关联

- **后续 fix**(所有 fix 的根)— 全部 fix 都基于此架构

---

## 后续动作

- [x] **持续演进**:v1.1 加固 + Phase 5 runbook/cleanup 都是基于此架构的增量
- [ ] **架构核心 spec 是否需要 ChangeLog 章节** → 是(本 session 后续动作:为 design.md 加 ChangeLog)
