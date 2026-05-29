# Roledrop Judge Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare and run a stratified DeepSeek/Qwen judge pilot for the RM v6.3 single-turn roledrop attack subset before deciding whether to full judge.

**Architecture:** Keep raw sampling outputs immutable. Build a clean canonical candidate directory, derive a stratified pilot120 shard, run v6.3 roledrop judge schema smoke, then run the same pilot through DeepSeek and local Qwen judges and compare agreement/audit quality.

**Tech Stack:** Bash, Python JSONL processing, `judge_candidates_llm_openai.py`, local vLLM Qwen endpoint, DeepSeek OpenAI-compatible API.

---

### Task 1: Clean And QA Candidate Inputs

**Files:**
- Read: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_subset_single_turn_1500_v1/candidates.*.jsonl`
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_subset_single_turn_1500_v1_clean/candidates.*.jsonl`
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_subset_single_turn_1500_v1_clean/qa_clean_summary.json`

- [ ] **Step 1: Load each source JSONL and keep one valid row per prompt**

Use Python JSON parsing. A valid row has a non-empty `response` and no `error` / `error_message` / `finish_reason == "error"`.

- [ ] **Step 2: Write canonical files**

Write six candidate files with exactly `1500` rows each. Preserve source rows without changing prompt text or responses.

- [ ] **Step 3: Write QA summary**

Report rows, unique prompt IDs, duplicate removals, empty/error removals, finish reasons, valid intersection, and valid union.

### Task 2: Build Stratified Pilot120

**Files:**
- Read: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/roledrop_attack_single_turn_prompts_subset_1500.jsonl`
- Read: cleaned candidate files from Task 1
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/prompts.jsonl`
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/candidates.*.jsonl`
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/qa_pilot120_summary.json`

- [ ] **Step 1: Select prompt IDs**

Stratify across `(attack_category, attack_language, split)` and preserve character coverage. Ensure all six attack categories and seven attack languages are represented.

- [ ] **Step 2: Slice candidates**

For each of six cleaned sources, write only the selected `120` prompt IDs.

- [ ] **Step 3: QA pilot shard**

Verify six files x `120` rows, prompt ID intersection `120`, no empty responses, no errors.

### Task 3: Local Schema Smoke

**Files:**
- Run: `/root/hanjiaqi/LlamaFactory/chatjoy/GRPO_Training_Package/rm_v6_finegrained/smoke_v63_judge_schema.py`

- [ ] **Step 1: Run smoke**

Command:

```bash
PYTHONPYCACHEPREFIX=/tmp/chatjoy_pycache \
python /root/hanjiaqi/LlamaFactory/chatjoy/GRPO_Training_Package/rm_v6_finegrained/smoke_v63_judge_schema.py
```

Expected: exit `0` and confirms v6.3 roledrop prompt/schema behavior.

### Task 4: Judge Pilot

**Files:**
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/judged_deepseek_v63_attack_pilot120.jsonl`
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/judged_qwen3_6_35b_a3b_v63_attack_pilot120.jsonl`
- Create audit files beside each judged file.

- [ ] **Step 1: DeepSeek judge**

Run `judge_candidates_llm_openai.py` with `--rubric-version v6.3`, `--roledrop-mode`, `--min-candidates 6`, `--max-candidates 6`, `--limit 120`, `--resume`.

- [ ] **Step 2: Qwen judge**

Run the same pilot through the local Qwen OpenAI-compatible endpoint with `--disable-thinking`, `--no-response-format`, and `--no-rationale`.

### Task 5: Compare Judges And Decide Full Judge

**Files:**
- Create: `/root/hanjiaqi/LlamaFactory/chatjoy/data/runs/rm_v6_3_roledrop/attack_judge_pilot120_v1/judge_compare_report.json`

- [ ] **Step 1: Compare**

Compute judged row count, audit count, top-1 agreement, top-3 overlap, pairwise agreement, Spearman rank correlation, and category/language agreement breakdowns.

- [ ] **Step 2: Decide**

Recommend one of: proceed to full subset1500 double judge, tune rubric/prompt, or run a larger pilot before full judge.
