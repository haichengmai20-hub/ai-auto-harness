# Fix 记录 — ai-auto-harness 架构改善事实链

> 这个目录记录**平台/架构/流程级**的改善 — **不**是项目部署修复。
> 完整规则见 [../specs/2026-05-27-fix-records-governance.md](../specs/2026-05-27-fix-records-governance.md)。
> 配套 [../specs/2026-05-27-spec-plan-governance.md](../specs/2026-05-27-spec-plan-governance.md)(spec/plan ChangeLog 规则)。

---

## 速查:什么时候写 fix.md(60 秒判定)

```
试跑/讨论里发现的事 →
    ├─ 单项目内 LLM 修了 requirements.txt / 装 torch?    → ❌ 不写 fix,走 workspace/<slug>/logs/fixes.log
    ├─ 看出 ai-auto-harness 平台层该改的规则/SKILL?       → ✅ 写 fix.md
    ├─ 多个项目都撞同一技术问题?                          → ✅ 写 fix.md + 提升到 memory/lessons/
    ├─ Phase 完成的复盘?                                  → ❌ 写 retro,然后逐条改善点 → 各自一份 fix.md
    └─ 当前无法解决的卡点?                                → ❌ 写 pending_human/,闭环后升级 fix
```

## 速查:fix.md 怎么写(3 步)

```
1. 复制 _template-fix.md 到 <YYYY-MM-DD>-<topic>-fix.md
2. 先填 "部署项目来源" 节(slug + run_id + 时间) ← 必填,否则后人无法追溯
3. 走 fix-records-governance §5 的 8 步闭环
```

---

## Fix 索引(按日期倒序)

> 最新更新时:同步 [../plans/2026-05-19-ai-auto-harness-master.md](../plans/2026-05-19-ai-auto-harness-master.md) 的 Fix 索引区。

| 日期 | Fix | 状态 | 部署项目 | 影响 | commit |
|---|---|---|---|---|---|
| 2026-05-27 | [verify-schema-enforcement-fix](2026-05-27-verify-schema-enforcement-fix.md) | 已闭环 | hunyuan3d-2 / omnivoice / song-generation-run2 | `verify/SKILL.md` + `scripts/validate-verify.sh` | (待补) |
| 2026-05-26 | [phase5-l1-retro-15-fixes](2026-05-26-phase5-l1-retro-15-fixes.md) | 已闭环 | song-generation-run2 (L1 test) | runbook/cleanup 两个 SKILL + scripts | `42bdc5c` |
| 2026-05-26 | [runs-cache-cleanup-decision-fix](2026-05-26-runs-cache-cleanup-decision-fix.md) | 已闭环 | song-generation-run2 / song-generation | `cleanup-deployed-workspace/SKILL.md` 第 2.5 步 | `42bdc5c` |
| 2026-05-26 | [v1.1-hardening-fix](2026-05-26-v1.1-hardening-fix.md) | 已闭环 | song-generation (run2 + run3) | R1-R9 + PostToolUse hook + cron 防僵尸 | `43e453e` |
| 2026-05-21 | [baseline-3-blockers-fix](2026-05-21-baseline-3-blockers-fix.md) | 已闭环 | song-generation | cache 隔离 / 禁并行 pip / GPU preflight → R5 R6 | `8dbe1d5` |
| 2026-05-21 | [agent-isolation-fix](2026-05-21-agent-isolation-fix.md) | 已闭环 | song-generation (run2) | 主/子 agent 严格隔离 → R1 R9 | `43e453e` |
| 2026-05-21 | [sleep-loop-discipline-fix](2026-05-21-sleep-loop-discipline-fix.md) | 已闭环 | song-generation (run2) | sleep 浪费 turn → R4 | `43e453e` |
| 2026-05-19 | [cron-driven-architecture-fix](2026-05-19-cron-driven-architecture-fix.md) | 已闭环 | (架构立项,无具体 run) | 5 阶段 SubAgent 流水线 + state.json 接续 | `84763ae` |

---

## 命名约定提醒

- 文件:`<YYYY-MM-DD>-<topic-kebab-case>-fix.md`
- **topic 是问题主题,不是项目名**
  - ✅ `2026-05-26-runs-cache-cleanup-decision-fix.md`
  - ❌ `2026-05-26-songgen-run2-fix.md`(项目名 — 那是 workspace/fixes.log 的语义)

---

## 与其他记录的边界(一图速查)

| 记录 | 位置 | 写者 | 粒度 |
|---|---|---|---|
| **Fix(本目录)** | `docs/superpowers/fixes/` | 人/AI | **平台**架构改善 |
| 项目修复日志 | `workspace/<slug>/logs/fixes.log` | LLM 试跑时 | **项目**内运行时修复(自动 append) |
| 决策记录 | `runs/<run-id>/decisions.md` | SubAgent | per-run 决策 |
| 通用踩坑 | `memory/lessons/<topic>.md` | 人 | **跨项目**通用技术 |
| Phase 复盘 | `docs/superpowers/retros/<date>-*.md` | 人 | **phase 周期**回顾 |
| 未闭环卡点 | `pending_human/<topic>.md` | SubAgent/人 | 待人决策 |
| 变更行为 | `git log` | git | 每次 commit |
