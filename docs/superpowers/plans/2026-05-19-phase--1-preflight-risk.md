# Phase -1 Preflight And Risk Validation Implementation Plan

> **✅ 完成状态(2026-05-26 回填)**:已完成 — 磁盘/Claude Code runtime 风险已验,`preflight-gpu-disk` skill + R3 wall-clock 上限落地。证据:commit `9ffae0b`(settings+hooks)+ `a266557`(preflight 子能力)。
> 下方 checkbox 为事后按 **milestone 级**完成度回填(本 phase 走 commit 驱动开发,执行时未逐步勾选);个别描述未落地子步骤的项请以 commit/handoff §2 为准。


> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate disk capacity and Claude Code runtime assumptions before platform development begins.

**Architecture:** This phase performs read-only measurement first, then writes small experiment scripts under `experiments/`. Destructive cleanup is manual-approval only.

**Tech Stack:** bash, Claude Code background shell behavior, filesystem inspection.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---

## Files

- Create: `/root/ai-auto-harness/experiments/R2-bg-shell-persistence.sh`
- Create: `/root/ai-auto-harness/experiments/R2-check.sh`
- Create: `/root/ai-auto-harness/experiments/R2-findings.md`
- Create: `/root/ai-auto-harness/experiments/R3-long-running-session.sh`
- Create: `/root/ai-auto-harness/experiments/R3-findings.md`

## Development Guidance

This phase is not application coding. It prepares the operational ground truth that later skills rely on:

- Whether long background downloads can outlive a Claude Code process.
- Whether `claude-haha --print` can survive long-running tasks.
- Whether there is enough disk for 10GB-100GB model experiments.

Keep all experiment artifacts small and committed. Do not commit runtime logs from `/tmp`.

## Test Setup

Run from:

```bash
cd /root/ai-auto-harness
```

Use these read-only probes first:

```bash
df -h /root
find /root -maxdepth 1 -name 'core.*' -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -20
du -sh /root/auto-deploy-agent/workspace/* 2>/dev/null | sort -hr | head -20
```

Expected:

- Disk free should be enough for at least one 30GB-80GB model test.
- Any cleanup recommendation is written down before deletion.

## Tasks

### Task -1.1: Disk Preflight

- [x] Record `/root` disk usage with `df -h /root`.
- [x] List large core files and large old workspaces.
- [x] If cleanup is needed, ask for explicit approval before deleting anything.
- [x] After approved cleanup, rerun `df -h /root`.
- [x] Write the result into the phase notes or commit message.

Validation command:

```bash
df -h /root
```

Expected: available space is comfortably above the next planned model download.

### Task -1.2: R2 Background Shell Persistence

- [x] Create `experiments/R2-bg-shell-persistence.sh`.
- [x] Create `experiments/R2-check.sh`.
- [x] Run the start script from a Claude Code session.
- [x] Exit or interrupt the parent session according to the experiment instructions.
- [x] Run the check script after at least 90 seconds.
- [x] Write the outcome into `experiments/R2-findings.md`.

Validation command:

```bash
bash /root/ai-auto-harness/experiments/R2-check.sh
```

Expected: the findings file says whether `setsid nohup` survives the parent Claude Code process.

### Task -1.3: R3 Long Running Print Session

- [x] Create `experiments/R3-long-running-session.sh`.
- [x] Run it with the same Claude Code binary that cron will use.
- [x] Record elapsed time and whether the process returns normally.
- [x] Write the outcome into `experiments/R3-findings.md`.

Validation command:

```bash
test -s /root/ai-auto-harness/experiments/R3-findings.md
```

Expected: file exists and contains the final decision for using `--print` in cron.

## Commit

```bash
cd /root/ai-auto-harness
git add experiments/
git commit -m "ai-auto: add preflight risk experiments"
```

## 人话版

**一句话**：出发前先检查——GPU 在不在、磁盘够不够、网络通不通，有问题就不跑。

**打比方**：像出车前检查油量、胎压、刹车，有一个不行就不上路。

---

## Phase Acceptance

- [x] Disk status is known.
- [x] R2 findings are recorded.
- [x] R3 findings are recorded.
- [x] Later phases know whether they can depend on background shells or need a safer service wrapper.

