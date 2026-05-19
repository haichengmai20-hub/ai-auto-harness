# Phase 0 ai-daily-scan MCP Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ai-daily-scan` so AI Auto Harness can read candidate findings and write deployment outcomes through MCP-compatible interfaces.

**Architecture:** `ai-daily-scan` remains the discovery system. This phase adds machine-readable finding fields, JSONL persistence, outcome reading, and a small MCP server.

**Tech Stack:** Python, pytest, MCP stdio server, JSONL state files.

**Reference:** [Master Plan](2026-05-19-ai-auto-harness-master.md)

---

## Files

- Modify: `/root/ai-daily-scan/pyproject.toml`
- Modify: `/root/ai-daily-scan/src/schemas.py`
- Modify: `/root/ai-daily-scan/src/tools.py`
- Create: `/root/ai-daily-scan/src/findings_writer.py`
- Create: `/root/ai-daily-scan/src/outcomes_reader.py`
- Modify: `/root/ai-daily-scan/src/run_daily.py`
- Create: `/root/ai-daily-scan/mcp_server.py`
- Create: `/root/ai-daily-scan/tests/test_findings_writer.py`
- Create: `/root/ai-daily-scan/tests/test_outcomes_reader.py`
- Create: `/root/ai-daily-scan/tests/test_mcp_server.py`

## Development Guidance

Keep this phase isolated to `ai-daily-scan`. Do not create Claude Code skills here.

Add these fields to each finding:

- `next_action`
- `hf_repos`
- `estimated_weight_size_gb`
- `estimated_params_b`

Use append-only JSONL for findings and outcomes. The downstream harness should be able to resume by reading files rather than relying on in-memory state.

## Test Setup

Run from:

```bash
cd /root/ai-daily-scan
```

Install test dependencies if the repo does not already have them:

```bash
python -m pip install -e '.[dev]'
```

If extras are not configured, install only what tests require:

```bash
python -m pip install pytest mcp
```

## Tasks

### Task 0.1: Branch And Dependencies

- [ ] Create a working branch.
- [ ] Add the MCP dependency using the repo's dependency style.
- [ ] Run the existing test suite before code changes.

Validation:

```bash
python -m pytest -q
```

Expected: existing tests pass or any pre-existing failures are recorded before edits.

### Task 0.2: Extend AnalystReport Schema

- [ ] Add the four harness fields to the report schema.
- [ ] Keep defaults conservative: empty lists for repos, `0` for unknown sizes, explicit enum for `next_action`.
- [ ] Add schema tests for defaults and serialization.

Validation:

```bash
python -m pytest tests/test_findings_writer.py -q
```

Expected: schema-derived writer tests can serialize all required fields.

### Task 0.3: Update Analyst Prompt

- [ ] Update the deep analyst prompt to always emit the four new fields.
- [ ] Include examples for self-host, API-only, skip, and human-review cases.
- [ ] Keep text guidance separate from machine-readable enum rules.

Validation:

```bash
python -m pytest tests/test_findings_writer.py -q
```

Expected: prompt-related tests or snapshot checks pass.

### Task 0.4: Write Findings JSONL

- [ ] Implement `findings_writer.py`.
- [ ] Write one JSON object per candidate.
- [ ] Include source report path and scan timestamp.
- [ ] Make the writer idempotent for one run by using stable slugs or a run id.

Validation:

```bash
python -m pytest tests/test_findings_writer.py -q
```

Expected: JSONL file is created and contains the harness fields.

### Task 0.5: Read Outcomes JSONL

- [ ] Implement `outcomes_reader.py`.
- [ ] Read `state/outcomes.jsonl`.
- [ ] Return latest outcome per slug.
- [ ] Tolerate missing file by returning an empty mapping.

Validation:

```bash
python -m pytest tests/test_outcomes_reader.py -q
```

Expected: duplicate slug handling returns the newest outcome.

### Task 0.6: Integrate Writer Into Daily Run

- [ ] Call the findings writer near the end of `run_daily.py`.
- [ ] Keep existing human-readable reports unchanged.
- [ ] Write machine-readable findings into `state/findings.jsonl`.

Validation:

```bash
python -m src.run_daily
test -s state/findings.jsonl
```

Expected: daily run produces both report output and JSONL findings.

### Task 0.7: MCP Server Tools

- [ ] Create `mcp_server.py`.
- [ ] Add `scan_today`.
- [ ] Add `get_recent_findings`.
- [ ] Add `record_outcome`.
- [ ] Add `analyze_project`.
- [ ] Keep each tool thin and backed by the JSONL helpers.

Validation:

```bash
python -m pytest tests/test_mcp_server.py -q
```

Expected: mocked MCP tool calls return deterministic JSON.

### Task 0.8: End-To-End Phase Test

- [ ] Run all tests.
- [ ] Run one daily scan in a safe mode if available.
- [ ] Confirm `state/findings.jsonl` and `state/outcomes.jsonl` contracts.

Validation:

```bash
python -m pytest -q
python -m json.tool state/findings.jsonl >/tmp/findings.pretty 2>/tmp/findings.err || true
```

Expected: tests pass; if JSONL cannot be passed directly to `json.tool`, inspect one line with `head -1 state/findings.jsonl`.

## Commit

```bash
cd /root/ai-daily-scan
git add pyproject.toml src tests mcp_server.py
git commit -m "ai-auto: add findings JSONL and MCP bridge"
```

## Phase Acceptance

- [ ] New fields exist in report schema.
- [ ] Findings JSONL is generated.
- [ ] Outcomes JSONL can be read.
- [ ] MCP tools are covered by tests.
- [ ] `ai-auto-harness` can consume candidates without scraping markdown.

