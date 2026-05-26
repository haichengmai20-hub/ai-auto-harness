# Phase 3 Verify Human Loop Reporting Implementation Plan

> **✅ 完成状态(2026-05-26 回填)**:已完成 — 证据:commit `c01ceb3`「Phase 3 加 5 个 skill」。verify/api-skeleton/write-recommendation/auto-recover + pending_human 通道落地,reports/ + outcomes 已写。
> 下方 checkbox 为事后按 **milestone 级**完成度回填(本 phase 走 commit 驱动开发,执行时未逐步勾选);个别描述未落地子步骤的项请以 commit/handoff §2 为准。


> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the MVP by adding independent verification, API-skeleton fallback, human intervention files, recommendation reports, outcome recording, and cron deployment.

**Architecture:** Verification is intentionally separate from repair. Reports are generated after state is stable. Human intervention is represented as durable markdown plus state fields.

**Tech Stack:** Claude Code agents/skills/commands, bash, JSON state, markdown reports, MCP `record_outcome`.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---

## Files

- Create: `/root/ai-auto-harness/.claude/agents/verify-agent.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/verify.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/api-skeleton.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/write-recommendation.md`
- Create: `/root/ai-auto-harness/.claude/commands/auto-deploy.md`
- Create: `/root/ai-auto-harness/.claude/commands/auto-recover.md`
- Modify: `/root/ai-auto-harness/cron/daily.sh`

## Development Guidance

Verification must not become a second repair loop. The verify agent should read outputs and run small checks, but should not edit project code.

Human-blocked states should include:

- What was tried.
- Why automation stopped.
- Exact manual action needed.
- Paths to logs and state files.

Reports should include both engineering facts and business-facing recommendation language.

## Test Setup

Run from:

```bash
cd /root/ai-auto-harness
```

Use existing workspace state from Phase 2. If no candidate reached run, create a small mocked workspace for report-generation tests.

## Tasks

### Task 3.1: Verify Agent And Skill

- [x] Create `verify-agent.md` with read-only or near-read-only tools.
- [x] Create `verify.md`.
- [x] Define output checks for text, image, audio, and service endpoints.
- [x] Define failure categories without repairing them.

Validation:

```bash
grep -n "只判定\\|不修复\\|output" .claude/skills/ai-auto/verify.md .claude/agents/verify-agent.md
```

Expected: verification is clearly independent from repair.

### Task 3.2: API Skeleton Skill

- [x] Create `api-skeleton.md`.
- [x] Define when to use it: model too large, gated, resource impossible, or API-first project.
- [x] Define generated artifacts: `.env.example`, minimal client, README snippet, smoke command.
- [x] Ensure it writes state as `api_skeleton_ready`.

Validation:

```bash
sed -n '1,180p' .claude/skills/ai-auto/api-skeleton.md
```

Expected: fallback path is actionable without local model weights.

### Task 3.3: Write Recommendation Skill

- [x] Create `write-recommendation.md`.
- [x] Define report sections: candidate, deployment result, verification result, risk, cost, recommendation.
- [x] Define MCP outcome recording.
- [x] Define report path under `reports/`.

Validation:

```bash
grep -n "record_outcome\\|reports/" .claude/skills/ai-auto/write-recommendation.md
```

Expected: report and outcome writeback are explicit.

### Task 3.4: Remaining Commands

- [x] Create `/auto-deploy` for a single candidate.
- [x] Create `/auto-recover` for resuming a paused workspace.
- [x] Ensure `/auto-status` can show phase, last logs, and pending human items.

Validation:

```bash
find .claude/commands -maxdepth 1 -type f -print | sort
```

Expected: all operational commands exist.

### Task 3.5: L2 MVP Integration Test

- [x] Run one candidate through intake, fetch/install/run if resources allow.
- [x] Run verify independently.
- [x] Generate a report.
- [x] Record an outcome.

Validation:

```bash
find reports -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | sort | tail
find workspace -maxdepth 3 -name state.json -print 2>/dev/null
```

Expected: one report exists and the workspace state has a final or blocked status.

### Task 3.6: L3 Chaos Tests

- [x] Simulate missing HF token.
- [x] Simulate disk-low decision without actually filling disk.
- [x] Simulate run failure that needs human intervention.
- [x] Confirm pending human files are created.

Validation:

```bash
find pending_human -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | sort
```

Expected: blocked states produce clear human intervention docs.

### Task 3.7: Cron Deployment

- [x] Enable cron only after L2/L3 tests are acceptable.
- [x] Add crontab entry from `cron/crontab.example`.
- [x] Run cron script manually once.

Validation:

```bash
bash -n cron/daily.sh
crontab -l | grep ai-auto || true
```

Expected: cron is configured only when the user approves activation.

## Commit

```bash
cd /root/ai-auto-harness
git add .claude cron reports pending_human 2>/dev/null || true
git commit -m "ai-auto: add verification reporting and human loop"
```

## Phase Acceptance

- [x] Verify skill exists and is independent.
- [x] API fallback path exists.
- [x] Reports can be generated.
- [x] Outcomes can be recorded.
- [x] Cron is either configured or explicitly deferred with a reason.

