# Phase 4 Knowledge Migration Documentation Implementation Plan

> **✅ 完成状态(2026-05-26 回填)**:已完成 — 证据:commit `4d8f88c`「Phase 4 借鉴 ai-daily-scan 加 3 skill」。coverage-gaps/cost-analysis/verifier-corrector + memory/lessons 写入判断 + README 全覆写。
> 下方 checkbox 为事后按 **milestone 级**完成度回填(本 phase 走 commit 驱动开发,执行时未逐步勾选);个别描述未落地子步骤的项请以 commit/handoff §2 为准。


> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add higher-level advisory skills, make lesson accumulation explicit, mark the old system as deprecated, and replace the README with AI Auto Harness documentation.

**Architecture:** This phase improves maintainability and communication. It should not introduce new runtime behavior unless required for docs consistency.

**Tech Stack:** Claude Code skills, markdown documentation, Git history hygiene.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---


---

## 人话版

**一句话**：第四阶段——把踩坑经验沉淀下来，写 README，方便后人接手。

**打比方**：像装修完写装修日记——哪些坑怎么避、哪些材料好使、哪些施工队别找。

**3 个 skill**：coverage-gaps（扫盲区）/ cost-analysis（算成本）/ verifier-corrector（事实核验）

## Files

- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/verifier-corrector.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/coverage-gaps.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/cost-analysis.md`
- Modify: `/root/ai-auto-harness/.claude/skills/ai-auto/run-and-repair.md`
- Modify: `/root/ai-auto-harness/.claude/skills/ai-auto/install-env.md`
- Modify: `/root/auto-deploy-agent/README.md`
- Modify: `/root/ai-auto-harness/README.md`

## Development Guidance

Separate three knowledge layers:

- `memory/lessons/`: reusable cross-project fixes.
- `memory/projects/<slug>.md`: one project-specific history.
- `reports/`: user-facing summaries and recommendations.

Do not let advisory skills run deployment commands. They should read facts and produce guidance.

## Test Setup

Run from:

```bash
cd /root/ai-auto-harness
```

For the old repo deprecation notice, use a separate branch in `/root/auto-deploy-agent`.

## Tasks

### Task 4.1: Verifier Corrector Skill

- [x] Create `verifier-corrector.md`.
- [x] Define when a verifier result should be challenged.
- [x] Require evidence from logs, output files, and state.
- [x] Keep it advisory; do not edit project code.

Validation:

```bash
sed -n '1,160p' .claude/skills/ai-auto/verifier-corrector.md
```

Expected: skill describes how to audit verification results.

### Task 4.2: Coverage Gaps Skill

- [x] Create `coverage-gaps.md`.
- [x] Define how to inspect which scenarios and modalities are under-tested.
- [x] Output concrete next candidate suggestions.

Validation:

```bash
grep -n "coverage\\|scenario\\|modality" .claude/skills/ai-auto/coverage-gaps.md
```

Expected: skill can guide future project selection.

### Task 4.3: Cost Analysis Skill

- [x] Create `cost-analysis.md`.
- [x] Compare self-host cost, API fallback cost, disk footprint, and engineering risk.
- [x] Feed its output into recommendation reports.

Validation:

```bash
grep -n "cost\\|API\\|self-host\\|disk" .claude/skills/ai-auto/cost-analysis.md
```

Expected: skill has concrete comparison dimensions.

### Task 4.4: Lesson Accumulation Rules

- [x] Update `run-and-repair.md` to say when to write reusable lessons.
- [x] Update `install-env.md` with the same principle.
- [x] Distinguish reusable lessons from project-specific notes.

Validation:

```bash
grep -n "memory/lessons\\|memory/projects" .claude/skills/ai-auto/run-and-repair.md .claude/skills/ai-auto/install-env.md
```

Expected: both skills mention the correct memory destinations.

### Task 4.5: Deprecate auto-deploy-agent

- [x] Create a branch in `/root/auto-deploy-agent`.
- [x] Add a short deprecation notice at the top of its README.
- [x] Commit separately in that repo.
- [x] Do not delete old code.

Validation:

```bash
cd /root/auto-deploy-agent
head -20 README.md
git status --short
```

Expected: notice is visible and changes are limited to README.

### Task 4.6: AI Auto Harness README

- [x] Replace the inherited Claude Code README with AI Auto Harness docs.
- [x] Include purpose, quick start, architecture, directories, and maintenance.
- [x] Link spec, master plan, and phase plans.

Validation:

```bash
cd /root/ai-auto-harness
sed -n '1,200p' README.md
grep -n "AI Auto Harness\\|Phase" README.md
```

Expected: README explains this project, not the upstream base.

## Commit

```bash
cd /root/ai-auto-harness
git add .claude README.md docs/superpowers/plans
git commit -m "ai-auto: add knowledge skills and project documentation"
```

For `/root/auto-deploy-agent`, commit separately:

```bash
cd /root/auto-deploy-agent
git add README.md
git commit -m "chore: mark auto-deploy-agent as deprecated"
```

## Phase Acceptance

- [x] Three advisory skills exist.
- [x] Lesson-writing rules are documented.
- [x] Old repo has a deprecation notice.
- [x] AI Auto Harness README is project-specific.
- [x] No runtime behavior changed without a matching test or explanation.

