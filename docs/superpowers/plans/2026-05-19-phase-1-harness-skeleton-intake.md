# Phase 1 Harness Skeleton And Intake Implementation Plan

> **✅ 完成状态(2026-05-26 回填)**:已完成 — 证据:commit `41febcf`「Phase 1 端到端就绪」+ `a266557`。intake 经 SongGen/OmniVoice/Hunyuan3D 三次真实部署验证。
> 下方 checkbox 为事后按 **milestone 级**完成度回填(本 phase 走 commit 驱动开发,执行时未逐步勾选);个别描述未落地子步骤的项请以 commit/handoff §2 为准。


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

- [x] Ensure `origin` points to the company Gitea repo.
- [x] Ensure `upstream` points to the Claude Code source base.
- [x] Keep the current branch as `main`.
- [x] Append runtime directories to `.gitignore`.

Validation:

```bash
git remote -v
git status --short
grep -n "workspace/" .gitignore
```

Expected: runtime folders are ignored and remotes are correct.

### Task 1.2: Project Context

- [x] Create `.claude/CLAUDE.md`.
- [x] Document hard constraints: no blind deletes, isolate workspaces, write state before long actions.
- [x] Document the five-stage agent pipeline.

Validation:

```bash
sed -n '1,120p' .claude/CLAUDE.md
```

Expected: context is readable and gives the agent enough project-specific constraints.

### Task 1.3: Settings And Permissions

- [x] Create `.claude/settings.json`.
- [x] Register the `ai-daily-scan` MCP server command.
- [x] Configure hooks.
- [x] Keep permissions narrow enough for safe automation.

Validation:

```bash
python -m json.tool .claude/settings.json >/tmp/ai-auto-settings.json
```

Expected: valid JSON.

### Task 1.4: Session Hooks

- [x] Create `session-start.sh` to create a run id and run directory.
- [x] Create `post-tool-use.sh` to append tool events into `runs/<run-id>/transcript.jsonl`.
- [x] Create `session-end.sh` to summarize and clean old runs.
- [x] Mark scripts executable.

Validation:

```bash
chmod +x .claude/hooks/*.sh
bash -n .claude/hooks/session-start.sh
bash -n .claude/hooks/post-tool-use.sh
bash -n .claude/hooks/session-end.sh
```

Expected: all hook scripts parse successfully.

### Task 1.5: Daily Auto And Intake Skills

- [x] Create `daily-auto.md`.
- [x] Create `intake.md`.
- [x] Create `preflight-gpu-disk.md`.
- [x] Create `request-human-intervention.md`.
- [x] Create `intake-agent.md`.
- [x] Ensure intake writes `state.json` with `phase="fetching"` when successful.

Validation:

```bash
find .claude/skills/ai-auto -maxdepth 1 -type f -print | sort
find .claude/agents -maxdepth 1 -type f -print | sort
```

Expected: the intake skill and agent exist and are readable.

### Task 1.6: Commands And Cron Skeleton

- [x] Create `/auto-daily`.
- [x] Create `/auto-status`.
- [x] Create `cron/daily.sh`.
- [x] Create `cron/crontab.example`.
- [x] Keep cron disabled until Phase 3.

Validation:

```bash
bash -n cron/daily.sh
sed -n '1,80p' .claude/commands/auto-status.md
```

Expected: command docs exist and cron script parses.

### Task 1.7: Intake End-To-End Test

- [x] Prepare one small candidate finding.
- [x] Run `/auto-daily` in a controlled session.
- [x] Confirm workspace and state are created.

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

## 人话版

**一句话**：第一步——把代码拉下来，看看 README 怎么说，搞清楚怎么装、怎么跑。

**打比方**：像拆箱看说明书，搞清楚这个玩具怎么组装。

---

## Phase Acceptance

- [x] Claude project context exists.
- [x] Hooks parse.
- [x] Commands exist.
- [x] Intake can create a candidate workspace.
- [x] No model weights or dependency environments were created in this phase.

