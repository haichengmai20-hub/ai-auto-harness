# Phase 1 Harness Skeleton And Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Claude Code fork into an AI Auto Harness workspace with project context, permissions, hooks, commands, and a first working intake flow.

**Architecture:** This phase builds the harness shell only. It does not fetch large weights or run models. The result should clone/read one candidate and advance its state to the fetch phase.

**Tech Stack:** Claude Code project config, skills, agents, hooks, bash, JSON state files.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---

## Files

- Modify: `/root/ai-auto-harness/.gitignore`
- Create: `/root/ai-auto-harness/.claude/CLAUDE.md`
- Create: `/root/ai-auto-harness/.claude/settings.json`
- Create: `/root/ai-auto-harness/.claude/hooks/session-start.sh`
- Create: `/root/ai-auto-harness/.claude/hooks/post-tool-use.sh`
- Create: `/root/ai-auto-harness/.claude/hooks/session-end.sh`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/daily-auto.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/intake.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/preflight-gpu-disk.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/request-human-intervention.md`
- Create: `/root/ai-auto-harness/.claude/agents/intake-agent.md`
- Create: `/root/ai-auto-harness/.claude/commands/auto-daily.md`
- Create: `/root/ai-auto-harness/.claude/commands/auto-status.md`
- Create: `/root/ai-auto-harness/cron/daily.sh`
- Create: `/root/ai-auto-harness/cron/crontab.example`

## Development Guidance

Keep runtime data out of git:

- `workspace/`
- `runs/`
- `memory/`
- `pending_human/`
- `state/`
- `reports/`

The intake flow should:

1. Read one candidate from MCP or a JSONL fixture.
2. Create `workspace/<slug>`.
3. Clone the repo.
4. Read README and docs.
5. Infer entry script and resource needs.
6. Write `workspace/<slug>/state.json`.

Do not install dependencies or download weights in this phase.

## Test Setup

Run from:

```bash
cd /root/ai-auto-harness
```

Useful probes:

```bash
git status --short
test -f .claude/CLAUDE.md
test -x .claude/hooks/session-start.sh
```

Use a small fixture candidate if live MCP is not ready.

## Tasks

### Task 1.1: Git And Ignore Setup

- [ ] Ensure `origin` points to the company Gitea repo.
- [ ] Ensure `upstream` points to the Claude Code source base.
- [ ] Keep the current branch as `main`.
- [ ] Append runtime directories to `.gitignore`.

Validation:

```bash
git remote -v
git status --short
grep -n "workspace/" .gitignore
```

Expected: runtime folders are ignored and remotes are correct.

### Task 1.2: Project Context

- [ ] Create `.claude/CLAUDE.md`.
- [ ] Document hard constraints: no blind deletes, isolate workspaces, write state before long actions.
- [ ] Document the five-stage agent pipeline.

Validation:

```bash
sed -n '1,120p' .claude/CLAUDE.md
```

Expected: context is readable and gives the agent enough project-specific constraints.

### Task 1.3: Settings And Permissions

- [ ] Create `.claude/settings.json`.
- [ ] Register the `ai-daily-scan` MCP server command.
- [ ] Configure hooks.
- [ ] Keep permissions narrow enough for safe automation.

Validation:

```bash
python -m json.tool .claude/settings.json >/tmp/ai-auto-settings.json
```

Expected: valid JSON.

### Task 1.4: Session Hooks

- [ ] Create `session-start.sh` to create a run id and run directory.
- [ ] Create `post-tool-use.sh` to append tool events into `runs/<run-id>/transcript.jsonl`.
- [ ] Create `session-end.sh` to summarize and clean old runs.
- [ ] Mark scripts executable.

Validation:

```bash
chmod +x .claude/hooks/*.sh
bash -n .claude/hooks/session-start.sh
bash -n .claude/hooks/post-tool-use.sh
bash -n .claude/hooks/session-end.sh
```

Expected: all hook scripts parse successfully.

### Task 1.5: Daily Auto And Intake Skills

- [ ] Create `daily-auto.md`.
- [ ] Create `intake.md`.
- [ ] Create `preflight-gpu-disk.md`.
- [ ] Create `request-human-intervention.md`.
- [ ] Create `intake-agent.md`.
- [ ] Ensure intake writes `state.json` with `phase="fetching"` when successful.

Validation:

```bash
find .claude/skills/ai-auto -maxdepth 1 -type f -print | sort
find .claude/agents -maxdepth 1 -type f -print | sort
```

Expected: the intake skill and agent exist and are readable.

### Task 1.6: Commands And Cron Skeleton

- [ ] Create `/auto-daily`.
- [ ] Create `/auto-status`.
- [ ] Create `cron/daily.sh`.
- [ ] Create `cron/crontab.example`.
- [ ] Keep cron disabled until Phase 3.

Validation:

```bash
bash -n cron/daily.sh
sed -n '1,80p' .claude/commands/auto-status.md
```

Expected: command docs exist and cron script parses.

### Task 1.7: Intake End-To-End Test

- [ ] Prepare one small candidate finding.
- [ ] Run `/auto-daily` in a controlled session.
- [ ] Confirm workspace and state are created.

Validation:

```bash
find workspace -maxdepth 2 -name state.json -print 2>/dev/null
```

Expected: at least one `state.json` exists with `phase` set to `fetching` or `paused_for_human`.

## Commit

```bash
cd /root/ai-auto-harness
git add .gitignore .claude cron
git commit -m "ai-auto: add harness skeleton and intake flow"
```

## Phase Acceptance

- [ ] Claude project context exists.
- [ ] Hooks parse.
- [ ] Commands exist.
- [ ] Intake can create a candidate workspace.
- [ ] No model weights or dependency environments were created in this phase.

