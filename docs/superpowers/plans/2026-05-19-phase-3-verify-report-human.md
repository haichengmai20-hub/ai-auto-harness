# Phase 3 Verify Human Loop Reporting Implementation Plan

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

- [ ] Create `verify-agent.md` with read-only or near-read-only tools.
- [ ] Create `verify.md`.
- [ ] Define output checks for text, image, audio, and service endpoints.
- [ ] Define failure categories without repairing them.

Validation:

```bash
grep -n "只判定\\|不修复\\|output" .claude/skills/ai-auto/verify.md .claude/agents/verify-agent.md
```

Expected: verification is clearly independent from repair.

### Task 3.2: API Skeleton Skill

- [ ] Create `api-skeleton.md`.
- [ ] Define when to use it: model too large, gated, resource impossible, or API-first project.
- [ ] Define generated artifacts: `.env.example`, minimal client, README snippet, smoke command.
- [ ] Ensure it writes state as `api_skeleton_ready`.

Validation:

```bash
sed -n '1,180p' .claude/skills/ai-auto/api-skeleton.md
```

Expected: fallback path is actionable without local model weights.

### Task 3.3: Write Recommendation Skill

- [ ] Create `write-recommendation.md`.
- [ ] Define report sections: candidate, deployment result, verification result, risk, cost, recommendation.
- [ ] Define MCP outcome recording.
- [ ] Define report path under `reports/`.

Validation:

```bash
grep -n "record_outcome\\|reports/" .claude/skills/ai-auto/write-recommendation.md
```

Expected: report and outcome writeback are explicit.

### Task 3.4: Remaining Commands

- [ ] Create `/auto-deploy` for a single candidate.
- [ ] Create `/auto-recover` for resuming a paused workspace.
- [ ] Ensure `/auto-status` can show phase, last logs, and pending human items.

Validation:

```bash
find .claude/commands -maxdepth 1 -type f -print | sort
```

Expected: all operational commands exist.

### Task 3.5: L2 MVP Integration Test

- [ ] Run one candidate through intake, fetch/install/run if resources allow.
- [ ] Run verify independently.
- [ ] Generate a report.
- [ ] Record an outcome.

Validation:

```bash
find reports -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | sort | tail
find workspace -maxdepth 3 -name state.json -print 2>/dev/null
```

Expected: one report exists and the workspace state has a final or blocked status.

### Task 3.6: L3 Chaos Tests

- [ ] Simulate missing HF token.
- [ ] Simulate disk-low decision without actually filling disk.
- [ ] Simulate run failure that needs human intervention.
- [ ] Confirm pending human files are created.

Validation:

```bash
find pending_human -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | sort
```

Expected: blocked states produce clear human intervention docs.

### Task 3.7: Cron Deployment

- [ ] Enable cron only after L2/L3 tests are acceptable.
- [ ] Add crontab entry from `cron/crontab.example`.
- [ ] Run cron script manually once.

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

- [ ] Verify skill exists and is independent.
- [ ] API fallback path exists.
- [ ] Reports can be generated.
- [ ] Outcomes can be recorded.
- [ ] Cron is either configured or explicitly deferred with a reason.

