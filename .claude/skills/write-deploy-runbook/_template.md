<!--
runbook 模板(填空式生成 — runbook-agent 启动时 cat 本文件,把 {{ }} 占位符替换成实际值)

🔴 硬约束(违反 = 重写):
  1. **节编号严禁改** — 1=AI prompt / 2=前置要求 / 3=5 Stage / 4=已知踩坑 / 5=成本 / 6=trace / 7=失败 case。
     validate-runbook.sh 用 `^## N\.` 抓节,错号 = 验收脚本误判。
  2. **Stage 标题硬编码,严禁自由发挥** — 必须逐字保持:
     Stage 1: clone   /   Stage 2: 拉权重   /   Stage 3: 装环境   /   Stage 4: 推理   /   Stage 5: 验证
     L1 实测出现过"腅环境"错字,所以这里写死。
  3. **{{STAGE_2_CMD}} 占位符填命令时,必须用 `hf download`,严禁 `huggingface-cli download`**(R7)。
  4. **任何 pip 命令严禁 `--no-cache-dir`**(R6,launch_worker 已 env 隔离 cache)。

占位符约定:
  {{SLUG}}                     — 项目 slug,如 song-generation
  {{DATE}}                     — YYYY-MM-DD
  {{GITHUB_URL}}               — 完整 github URL
  {{HF_REPOS_LIST}}            — yaml list,如 [lglg666/SongGen-Runtime, lglg666/SongGen-v2-large]
  {{STATUS}}                   — success | incomplete_verify_failed | paused_at_<phase> | blocked_<reason>
  {{DURATION_MIN}}             — int
  {{TURNS}}                    — int
  {{TOTAL_COST_USD}}           — float
  {{GPU_REQUIRED_GB}}          — int
  {{DISK_REQUIRED_GB}}         — int
  {{NEEDS_HF_TOKEN}}           — true / false
  {{AUDIO_OUTPUT_SEC}}         — float 或留空
  {{RUN_ID}}                   — 用于 trace 指针
  {{STAGE_<N>_CMD}}            — 该 stage 实际跑过的命令(已脱敏,Stage 2 必须 `hf download` 不是 `huggingface-cli`)
  {{STAGE_<N>_SUCCESS}}        — 该 stage 成功标志命令
  {{STAGE_<N>_DURATION}}       — 该 stage 预计耗时(从 ndjson 估)
  {{TRAP_<N>_*}}               — 第 N 个踩坑的 4 字段(SYMPTOM/TRIGGER/ROOT_CAUSE/FIX/VERIFY)
  {{TRAP_COUNT}}               — 踩坑总数

如果某 stage / 踩坑实际没发生,该段整体删除(不要留空段)。
-->

---
slug: {{SLUG}}
github: {{GITHUB_URL}}
hf_repos:
{{HF_REPOS_LIST}}
date: {{DATE}}
status: {{STATUS}}
duration_min: {{DURATION_MIN}}
turns: {{TURNS}}
total_cost_usd: {{TOTAL_COST_USD}}
gpu_required_gb: {{GPU_REQUIRED_GB}}
disk_required_gb: {{DISK_REQUIRED_GB}}
needs_hf_token: {{NEEDS_HF_TOKEN}}
audio_output_sec: {{AUDIO_OUTPUT_SEC}}
---

# 部署 Runbook — {{SLUG}}

> 本 runbook 由 ai-auto-harness 在 {{DATE}} 跑完 {{SLUG}} 部署后自动抽取,记录了**实际跑过的命令**和**踩到的坑**。  
> 适合人或其他 AI 复用 — 整段复制下面"给 AI 的部署 prompt"给 Claude / ChatGPT 就能开跑。

---

## 1. 给 AI 的部署 prompt(复制下面整段)

> ⚠️ **如果你是 AI,请严格按下方 prompt 执行,不要试错。**

---

你将按照下方 runbook 部署 **{{SLUG}}** 项目。

### 强制规则
- 每个 Stage 必须**等成功标志**出现才进下一 Stage,不许跳
- 遇到"已知踩坑"列表里的错误,**直接按修复方案改**,不要试错
- 整个流程需要 **GPU(≥ {{GPU_REQUIRED_GB}}GB free)** 和 **磁盘(≥ {{DISK_REQUIRED_GB}}GB free)**
{{#NEEDS_HF_TOKEN}}- 需要 HuggingFace token: `export HF_TOKEN=hf_xxx`(去 huggingface.co 个人设置创建){{/NEEDS_HF_TOKEN}}
- 大约耗时 **{{DURATION_MIN}} 分钟**(权重下载 + 装环境 + 推理)

### Stage 1: clone

执行:
```bash
{{STAGE_1_CMD}}
```
成功标志:
```bash
{{STAGE_1_SUCCESS}}
```
预计耗时:{{STAGE_1_DURATION}} min

### Stage 2: 拉权重

执行:
```bash
{{STAGE_2_CMD}}
```
成功标志:
```bash
{{STAGE_2_SUCCESS}}
```
预计耗时:{{STAGE_2_DURATION}} min

### Stage 3: 装环境

执行:
```bash
{{STAGE_3_CMD}}
```
成功标志:
```bash
{{STAGE_3_SUCCESS}}
```
预计耗时:{{STAGE_3_DURATION}} min

### Stage 4: 推理

执行:
```bash
{{STAGE_4_CMD}}
```
成功标志:
```bash
{{STAGE_4_SUCCESS}}
```
预计耗时:{{STAGE_4_DURATION}} min

### Stage 5: 验证

执行:
```bash
{{STAGE_5_CMD}}
```
成功标志:
```bash
{{STAGE_5_SUCCESS}}
```
预计耗时:{{STAGE_5_DURATION}} min

---

**如遇此 runbook 未列的新错误**,先 `grep <error message> ${HARNESS_ROOT}/workspace/{{SLUG}}/logs/fixes.log`,若无再问人。

---

## 2. 前置要求

| 资源 | 阈值 | 检查命令 |
|---|---|---|
| GPU 显存 free | ≥ {{GPU_REQUIRED_GB}} GB | `nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits` |
| 磁盘 free | ≥ {{DISK_REQUIRED_GB}} GB | `df -BG . \| tail -1 \| awk '{print $4}'` |
| Python | 3.10+ | `python --version` |
{{#NEEDS_HF_TOKEN}}| HF_TOKEN | 已配置 | `[ -n "$HF_TOKEN" ]` |{{/NEEDS_HF_TOKEN}}
{{#GPU_SM12_REQUIRED}}| torch sm_12.0(RTX 5090) | wheel 含 sm_120 | `python -c "import torch; assert any('120' in a for a in torch.cuda.get_arch_list())"` |{{/GPU_SM12_REQUIRED}}

---

## 3. 5 Stage 完整指令(带预计耗时和已知踩坑)

### Stage 1: clone

**执行**:
```bash
{{STAGE_1_CMD}}
```
**成功标志**: `{{STAGE_1_SUCCESS}}`
**预计耗时**: {{STAGE_1_DURATION}} min

### Stage 2: 拉权重({{DISK_REQUIRED_GB}}GB, ~{{STAGE_2_DURATION}}min @ 200MB/s)

**执行**:
```bash
{{STAGE_2_CMD}}
```
**成功标志**: `{{STAGE_2_SUCCESS}}`

### Stage 3: 装环境

**执行**:
```bash
{{STAGE_3_CMD}}
```
**成功标志**: `{{STAGE_3_SUCCESS}}`
**预计耗时**: {{STAGE_3_DURATION}} min

### Stage 4: 推理

**执行**:
```bash
{{STAGE_4_CMD}}
```
**成功标志**: `{{STAGE_4_SUCCESS}}`
**预计耗时**: {{STAGE_4_DURATION}} min

### Stage 5: 验证

**执行**:
```bash
{{STAGE_5_CMD}}
```
**成功标志**: `{{STAGE_5_SUCCESS}}`
**预计耗时**: {{STAGE_5_DURATION}} min

---

## 4. 已知踩坑 → 修复速查(共 {{TRAP_COUNT}} 个)

<!-- 每个 trap 用下面 4 字段格式,不要散文 -->

### 已知踩坑 1: {{TRAP_1_SYMPTOM}}

**触发条件**: {{TRAP_1_TRIGGER}}
**根因**: {{TRAP_1_ROOT_CAUSE}}
**修复**:
```bash
{{TRAP_1_FIX}}
```
**验证修复成功**: `{{TRAP_1_VERIFY}}`

<!-- 重复 trap 2, 3, ... 同样 4 字段 -->

---

## 5. 成本/耗时摘要

| 指标 | 值 |
|---|---|
| 总耗时 | {{DURATION_MIN}} 分钟 |
| LLM turn 数 | {{TURNS}} |
| API 成本 | ${{TOTAL_COST_USD}} USD |
| 修复轮次 | {{REPAIR_ROUNDS}} 轮 |
{{#AUDIO_OUTPUT_SEC}}| 输出音频时长 | {{AUDIO_OUTPUT_SEC}} 秒 |{{/AUDIO_OUTPUT_SEC}}

---

## 6. 完整 trace 指针(可选追溯)

- 工作区:`${HARNESS_ROOT}/workspace/{{SLUG}}/`
- 本次 run 快照:`${HARNESS_ROOT}/workspace/{{SLUG}}/runs/{{RUN_ID}}/`(legacy 全局 `runs/{{RUN_ID}}/`)
- 完整 ndjson 轨迹:`workspace/{{SLUG}}/runs/{{RUN_ID}}/harness.stdout.ndjson`
- 各 phase 落盘:`workspace/{{SLUG}}/{logs,results}/`
- 修复日志:`workspace/{{SLUG}}/logs/fixes.log`
- 决策记录:`workspace/{{SLUG}}/runs/{{RUN_ID}}/decisions.md`

---

## 7. 失败 case 标记(若 status ≠ success)

{{#STATUS_INCOMPLETE_VERIFY_FAILED}}
⚠️ **本次部署 5 stage 都跑了,但 verify 未过**(`failed_at: {{VERIFY_FAILED_AT}}`)。
- evidence:`{{VERIFY_EVIDENCE_SUMMARY}}`
- 重跑此 runbook 时,**特别注意 Stage 5 末尾的判定**,可能需调 batch_size / GPU 配置
- 详见 `${HARNESS_ROOT}/pending_human/{{SLUG}}.md`(若存在)
{{/STATUS_INCOMPLETE_VERIFY_FAILED}}

{{#STATUS_PAUSED_AT_PHASE}}
⚠️ **本次部署卡在 {{PAUSED_PHASE}} 阶段**,未到达后续 stage。
- 后续 Stage {{PAUSED_STAGE_NUM}}-5 命令**未经实战验证**,使用风险自负
- 详见 `${HARNESS_ROOT}/pending_human/{{SLUG}}.md`
{{/STATUS_PAUSED_AT_PHASE}}

{{#STATUS_BLOCKED}}
⚠️ **本次部署被 preflight 拒绝**(reason: {{BLOCKED_REASON}})。
- 资源不足或 gated repo 没 token
- 解决资源问题后,可走 Stage 1 重启
{{/STATUS_BLOCKED}}

---

<!--
END OF TEMPLATE.
runbook-agent 在写入 reports/runbooks/<slug>-<date>.md 时:
1. 替换全部 {{...}} 占位符
2. 删除未发生分支的 {{#flag}}...{{/flag}} 块
3. 末尾不留这条 HTML 注释
-->
