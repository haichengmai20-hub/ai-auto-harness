# Phase 2 Fetch Install Run Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the heavy execution stages: weight fetching, dependency installation, runtime repair, and one deploy-to-run integration test.

**Architecture:** Fetch, install, and run are separate agent/skill boundaries. Each stage writes state and logs so a later cron run can resume or diagnose the project.

**Tech Stack:** Claude Code skills/agents, Hugging Face CLI, Python venv, pip, CUDA/Torch probes, bash logs, JSON state.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---

## Files

- Modify: `/root/ai-auto-harness/.claude/skills/ai-auto/daily-auto.md`
- Create: `/root/ai-auto-harness/.claude/agents/fetch-agent.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/fetch-weights.md`
- Create: `/root/ai-auto-harness/memory/lessons/torch-sm12.md`
- Create: `/root/ai-auto-harness/memory/lessons/hf-gated.md`
- Create: `/root/ai-auto-harness/memory/lessons/flash-attn-build.md`
- Create: `/root/ai-auto-harness/.claude/agents/install-agent.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/install-env.md`
- Create: `/root/ai-auto-harness/.claude/agents/runner-agent.md`
- Create: `/root/ai-auto-harness/.claude/skills/ai-auto/run-and-repair.md`

## Development Guidance

This phase starts touching large downloads and GPU runtime. Preserve project isolation:

- `HF_HOME=$WORKSPACE/.cache/huggingface`
- `HUGGINGFACE_HUB_CACHE=$WORKSPACE/.cache/huggingface/hub`
- `TRANSFORMERS_CACHE=$WORKSPACE/.cache/huggingface/transformers`
- `TORCH_HOME=$WORKSPACE/.cache/torch`
- `PIP_CACHE_DIR=$WORKSPACE/.cache/pip`
- `XDG_CACHE_HOME=$WORKSPACE/.cache/xdg`

Never use global cleanup to fix a single project. If a project is dirty, mark that workspace dirty and continue with another workspace.

## Test Setup

Run from:

```bash
cd /root/ai-auto-harness
```

Before a real model run:

```bash
df -h /root
nvidia-smi
```

Expected: disk and at least one GPU are available for the chosen candidate.

## Tasks

### Task 2.1: Resume-Aware Daily Dispatch

- [ ] Update `daily-auto.md` so it reads `workspace/<slug>/state.json`.
- [ ] Dispatch based on `phase`.
- [ ] Advance phase only after stage success.
- [ ] Preserve `paused_for_human` and `paused_in_progress` states.

Validation:

```bash
grep -n "phase" .claude/skills/ai-auto/daily-auto.md
```

Expected: phase transitions are explicit.

### Task 2.2: Fetch Agent And Skill

- [ ] Create `fetch-agent.md`.
- [ ] Create `fetch-weights.md`.
- [ ] Document background download behavior.
- [ ] Document resume behavior.
- [ ] Document gated repo handling.
- [ ] Require progress logging.

Validation:

```bash
sed -n '1,160p' .claude/skills/ai-auto/fetch-weights.md
```

Expected: the skill requires project-local HF cache and writes progress.

### Task 2.3: Seed Lessons

- [ ] Create `memory/lessons/torch-sm12.md`.
- [ ] Create `memory/lessons/hf-gated.md`.
- [ ] Create `memory/lessons/flash-attn-build.md`.
- [ ] Keep lessons short enough for agents to read before repair.

Validation:

```bash
find memory/lessons -maxdepth 1 -type f -print | sort
```

Expected: all three seed lessons exist.

### Task 2.4: Install Agent And Skill

- [ ] Create `install-agent.md`.
- [ ] Create `install-env.md`.
- [ ] Define venv creation.
- [ ] Define dependency install order.
- [ ] Define Torch CUDA architecture probe.
- [ ] Define `pip check` verification.

Validation:

```bash
grep -n "torch.cuda.get_arch_list\\|pip check\\|venv" .claude/skills/ai-auto/install-env.md
```

Expected: install verification is built into the skill.

### Task 2.5: Runner Agent And Repair Skill

- [ ] Create `runner-agent.md`.
- [ ] Create `run-and-repair.md`.
- [ ] Define max repair attempts.
- [ ] Define required observation loop.
- [ ] Define decisions log.
- [ ] Define when to request human intervention.

Validation:

```bash
grep -n "最多\\|max\\|decisions\\|request-human" .claude/skills/ai-auto/run-and-repair.md
```

Expected: repair loop has a hard stop and traceable decisions.

### Task 2.6: Integration Test With One Candidate

- [ ] Choose one candidate that fits current disk/GPU limits.
- [ ] Run `/auto-daily` until it reaches fetch/install/run.
- [ ] Inspect state and logs after each stage.
- [ ] Do not force a full large model run if disk or GPU is not available; record the blocker.

Validation:

```bash
find workspace -maxdepth 3 -type f \\( -name state.json -o -name '*.log' \\) -print 2>/dev/null | sort | head -50
```

Expected: workspace contains stage state and logs.

## Commit

```bash
cd /root/ai-auto-harness
git add .claude memory
git commit -m "ai-auto: add fetch install and run-repair stages"
```

## Phase Acceptance

- [ ] Fetch skill can resume or pause safely.
- [ ] Install skill records environment verification.
- [ ] Run-and-repair has a bounded loop and trace log.
- [ ] One candidate reaches at least `running`, `verifying`, or a well-explained human-blocked state.

