# AI Auto Harness Master Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`. Execute one phase plan at a time. Do not try to run the original full implementation plan in one session.

**Goal:** Build and validate AI Auto Harness as a cron-driven Claude Code platform for finding, deploying, repairing, verifying, and reporting AI projects.

**Architecture:** This master file is the execution index. Each phase plan owns one milestone, has its own development guidance, and has its own test setup. The original long plan remains a reference runbook, not the primary execution unit.

**Tech Stack:** Claude Code skills/agents/hooks, TypeScript/Bun for the Claude Code base, Python for `ai-daily-scan` MCP integration, bash for cron and operational probes.

**Reference Spec:** [2026-05-19-ai-auto-harness-design.md](../specs/2026-05-19-ai-auto-harness-design.md)

**Original Full Runbook:** [2026-05-19-ai-auto-harness-implementation.md](2026-05-19-ai-auto-harness-implementation.md)

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

| Phase | Milestone | Primary Validation |
|---|---|---|
| -1 | Disk and Claude Code runtime risks understood | `df -h /root`, R2/R3 findings files |
| 0 | `ai-daily-scan` can emit findings and serve MCP tools | `pytest`, MCP smoke call |
| 1 | `ai-auto-harness` skeleton can intake one candidate | `/auto-daily` reaches `state.phase=fetching` |
| 2 | Candidate can fetch weights, install env, and run/repair | workspace has fetch/install/run artifacts |
| 3 | MVP can verify, report, and record outcomes | report + `outcomes.jsonl` written |
| 4 | Lessons, migration notice, and docs are complete | skill docs + README updates committed |

## Stop Conditions

Stop the phase and ask for review when any of these happen:

- Disk free falls below 100GB.
- A gated model requires manual license acceptance.
- A command wants to delete project workspaces, model weights, or Git history.
- A Claude Code behavior differs from the assumption in the design spec.
- A phase requires changing more than one repo in a single task without a test boundary.

