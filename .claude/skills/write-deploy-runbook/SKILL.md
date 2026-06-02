---
name: write-deploy-runbook
description: 从本次部署的 trace 抽 AI 友好的 markdown 部署 runbook,保存到 reports/runbooks/<slug>-<date>.md,让人或其他 AI 30-60min 复现本次部署
allowed-tools: [Read, Bash, Write]
agent: runbook-agent
---

# write-deploy-runbook

## 落盘约定(必读)

- **runbook 文件**:`reports/runbooks/<slug>-<YYYY-MM-DD>.md` — AI 可消费的部署手册
- **日志**:`$WORKSPACE/logs/runbook.log` — 抽取过程的 bash stdout/stderr
- **结果**:`$WORKSPACE/results/runbook.json` — return schema
- **决策**:`runs/$RUN_ID/decisions.md` — append 一行(类似 verify-agent 的模式)

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results" reports/runbooks
LOG="$WORKSPACE/logs/runbook.log"
echo "==== runbook start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=runbook slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "run_id": "<from 主 agent>",
  "verify_passed": true,
  "verify_result": { "passed": true, "failed_at": null, "evidence": {...}, ... },
  "github_url": "https://github.com/.../...",
  "force_status": null
}
```

`force_status` 可选,用于失败 case 主 agent 显式指定 `paused_at_<phase>` / `blocked_<reason>` 时使用。默认从 `verify_result` 自动推导。

## 你的工作 = "模板 + LLM 双层抽取"

不要纯 LLM 自由写 runbook(每次结构都不一样,AI 消费不稳定)。
不要纯模板硬填(死板,丢失 trace 里的关键洞察)。

**节编号与 `_template.md` 严格一致**(P3-2 修正,以前混乱):

| 节 | 内容 | 抽取方式 |
|---|---|---|
| (frontmatter, YAML) | slug / github / status / 资源需求 | 纯字段映射,从 state.json + results/ 抽 |
| **1. 给 AI 的部署 prompt** | 整段可复制 prompt,含 5 stage | LLM 按模板生成,必须含 5 stage,每 stage 必含命令+成功标志+预计耗时 |
| **2. 前置要求** | GPU/磁盘/token/python 阈值表 | 纯映射 |
| **3. 5 Stage 完整指令** | 每 stage 命令+成功标志+耗时 | LLM 从 `logs/<phase>.log` 提取实际跑过的命令,套模板渲染 |
| **4. 已知踩坑 → 修复速查** | 4 字段块 × N | LLM 从 fixes.log + decisions.md 抽 error → fix 二元结构 |
| **5. 成本/耗时摘要** | 总耗时/turns/cost | 纯映射(ndjson result event) |
| **6. 完整 trace 指针** | workspace/runs/ndjson 路径 | 纯字符串 |
| **7. 失败 case 标记** | 仅 status ≠ success 时渲染 | LLM 按 status 选模板分支 |

**严禁**自创节编号或调换顺序 — 后续脚本 (`validate-runbook.sh`) 靠 `^## N\.` 抓节。

## 工作流(分 5 步)

### 第 0 步:读取 _template.md

```bash
TEMPLATE=$(cat /root/ai-auto-harness/.claude/skills/write-deploy-runbook/_template.md)
```

把模板放到自己的上下文里,后面填空式生成,不让自己自由发挥。

### 第 1 步:聚合数据源(纯 bash + jq)

```bash
SLUG="$1"        # 从主 agent 传入
WORKSPACE="$2"
RUN_ID="$3"

# 抽 frontmatter 字段
STATE_JSON="$WORKSPACE/state.json"
INTAKE_JSON="$WORKSPACE/results/intake.json"
FETCH_JSON="$WORKSPACE/results/fetch.json"     # 或 fetch-weights.json,看实际
INSTALL_JSON="$WORKSPACE/results/install.json"  # 或 install-env.json
RUN_JSON="$WORKSPACE/results/run.json"          # 或 run-and-repair.json
VERIFY_JSON="$WORKSPACE/results/verify.json"
NDJSON="runs/$RUN_ID/harness.stdout.ndjson"
FIXES_LOG="$WORKSPACE/logs/fixes.log"
DECISIONS_MD="runs/$RUN_ID/decisions.md"

# 检查关键文件存在(缺失就降级)
for f in "$STATE_JSON" "$NDJSON"; do
    if [ ! -f "$f" ]; then
        echo "WARN: $f 缺失,部分字段无法填" >> "$LOG"
    fi
done

# P3-1: fixes.log 缺失时的降级 — 第 4 步抽踩坑必须知道走哪条路径
if [ ! -f "$FIXES_LOG" ]; then
    echo "WARN: fixes.log 缺失,第 4 步将从 results/run-and-repair.json 的 .repairs[] + results/install.json 的 .fixes_applied[] 数组降级抽取" >> "$LOG"
    FIXES_SOURCE="results_json_fallback"
else
    FIXES_SOURCE="fixes_log"
fi
```

**降级抽取格式约定**(P3-1):
- 优先级 1:`logs/fixes.log` — 每行 `<phase> <ts> <error> -> <fix>` 直接 grep
- 优先级 2:若 fixes.log 不存在,从 `results/run-and-repair.json` 的 `.repairs[]` 和 `results/install.json` 的 `.fixes_applied[]` 数组用 jq 抽,**LLM 从 JSON 推导 4 字段**(触发条件 / 根因 / 修复 / 验证)— 不是直接 grep
- 优先级 3:两者都缺,只从 `runs/$RUN_ID/decisions.md` 抽决策记录,fragment 不完整时标 `traps_documented: 0`

### 第 2 步:生成 frontmatter + 前置要求 + 成本摘要(纯填空)

```yaml
---
slug: <SLUG>
github: <github_url from intake.json>
hf_repos: <list from intake.json>
date: <today>
status: <success | incomplete_verify_failed | paused_at_<phase> | blocked_<reason>>
duration_min: <int>
turns: <int>
total_cost_usd: <float, from ndjson result event 的 total_cost_usd>
gpu_required_gb: <from intake.json.gpu_picks 推算>
disk_required_gb: <from fetch.json.bytes_total 估算 + 50GB safety>
needs_hf_token: <bool, intake.json.gated_repos 非空 = true>
audio_output_sec: <from verify.json.evidence.audio_info.duration_seconds,若有>
---
```

`status` 推导规则:

| verify_passed | run-and-repair 是否走完 | status |
|---|---|---|
| true | yes | `success` |
| false | yes(5 stage 都跑了但 verify 失败) | `incomplete_verify_failed` |
| 任何 | no(卡在 fetch/install/run 某 stage) | `paused_at_<phase>` |
| - | 任一资源 preflight 拒(GPU/磁盘) | `blocked_<reason>` |

**`total_cost_usd` 填写规则**(Fix #22: 交互式 session 无 cost 数据):
- 优先从 `runs/$RUN_ID/harness.stdout.ndjson` 的 `result` 事件取 `total_cost_usd`
- 若 ndjson 不存在(交互式 session),从 `runs/$RUN_ID/trajectory.json` 的 result 事件取
- 若两者都没有(纯交互式 session 无 cost 追踪),**写 `null`**(不是 0.0) — 0.0 暗示"免费"而实际是"数据不可用"
- **严禁**写 `0.0` 表示"数据不可用" — `0.0` 只在确实 $0 成本时使用

**`duration_min` 填写规则**(Fix: duration 预估严重不准):
- 优先从 `state.json.started_at` 和 `state.json.updated_at` 计算实际耗时(分钟)
- 若 `started_at` 不存在,从 `runs/$RUN_ID/meta.json.started_at` 取
- 若 `updated_at` 不存在,用当前时间减 `started_at`
- **严禁**写 AI prompt 节里的"预计耗时"(那是给复用者的预估,不是本次实际耗时)
- 实际耗时和 AI prompt 里的"预计耗时"是两个不同概念,不要混淆

### 第 3 步:生成 5 stage 指令(LLM 抽取,套模板)

读 5 个 phase 的 log + results,转成 stage 指令。每 stage 必须含:

- **执行命令**(从 logs/<phase>.log 抽实际跑过的成功命令,不是失败的)
- **成功标志**(用 grep / python -c assert / ls 之一)
- **预计耗时**(分钟数,从 ndjson timestamp 或 result event 推算)
- **已知踩坑**(若该 stage 有 fix,append "已知踩坑 N:" 块)

每 stage 抽取规则:

| Phase | 抽 entry_script | 抽 成功标志 | 抽 已知踩坑 |
|---|---|---|---|
| intake | `git clone <github>`(从 logs/intake.log) | `ls -la <repo>` 列举关键文件 | 若有 preflight 失败重试,记 |
| fetch-weights | **`hf download <repo> --local-dir <path>`**(从 results/fetch.json.weights_done。**R7 硬规则**:若 trace 里看到 `huggingface-cli download`,必须替换为 `hf download` — 老命令已 deprecated) | `du -sh <path>` 至少 X GB | gated repo / resume / hf vs huggingface-cli |
| install-env | `pip install -r requirements.txt + 修复`(从 results/install.json.fixes_applied) | `python -c "import torch; assert ..."` | sm_120 / numpy / setuptools 冲突 |
| run-and-repair | 最后一次成功的 `python <entry>`(从 results/run.json.invoked_command) | `ls output/` 看到输出文件 | flash_attn / torchcodec / third_party symlink |
| verify | smoke test 命令(从 results/verify.json.evidence) | GPU util > 10% + 输出文件存在 | (verify 不修问题,通常无踩坑) |

### 第 4 步:生成"已知错误速查"(LLM 抽 fixes.log)

`fixes.log` 每行一条修复记录,格式约定:`<phase> <timestamp> <error> -> <fix>`(或类似)。

**P3-3 筛选规则(决定哪些踩坑该写入 runbook)**:
- ✅ **写入**:**有实际修复命令的踩坑** — 即 `repair` 数组里 `applied_command` 非空,或 fixes.log 行里 `-> <fix>` 段非空。这类踩坑后人按 runbook 跑会再撞,必须列。
- ⚠️ **写入但标 "未修复"**:**被 skip 的冲突** — install.json 里 `omegaconf/hydra` 之类版本冲突 LLM 决定 skip,没有修复命令。这类要写一条 trap 但 `修复` 字段写 `⚠️ 未修复,需人工判断` 并把上下文(冲突双方版本)写到 `根因`。
- ❌ **不写**:**只是 INFO/WARN 日志,没有 error→fix 二元结构的内容**,如"找到 X 文件,跳过 Y 阶段"。

把每条筛选后的踩坑转成下面的 4 字段块(严格按格式,不许散文):

```markdown
### 已知踩坑 N: <一句话现象>

**触发条件**: <grep-able 的 error message 或前置情况>
**根因**: <一句话>
**修复**:
\`\`\`bash
<复制可执行的命令>
\`\`\`
**验证修复成功**: <grep / python -c assert / ls 之一>
```

例(SongGen 实际):

```markdown
### 已知踩坑 1: torch 安装后 sm_120 不在 arch_list

**触发条件**: `python -c "import torch; print(torch.cuda.get_arch_list())"` 输出不含 `sm_120` 或 `compute_120`
**根因**: requirements.txt pin 了 `torch==2.6.0+cu126`,该 wheel 未编 sm_12 内核(RTX 5090)
**修复**:
\`\`\`bash
sed -i -E "/^(torch|torchvision|torchaudio)([=<>!~]|$)/d" requirements.txt
pip install --pre --index-url https://download.pytorch.org/whl/nightly/cu128 torch torchvision torchaudio
\`\`\`
**验证修复成功**: `python -c "import torch; assert any('120' in a for a in torch.cuda.get_arch_list())"`
```

### 第 5 步:生成"给 AI 的部署 prompt"(节 1,核心)

这是整份 runbook 最有价值的一节:**一段可以整体复制给 Claude / ChatGPT 让它按 runbook 执行的中文 prompt**。

模板见 `_template.md` 第 1 节(`## 1. 给 AI 的部署 prompt`),要确保:
- 标明强制规则(每 stage 等成功标志才进下一)
- 列出前置(GPU / 磁盘 / token)
- 5 stage 的命令 + 成功标志 + 已知踩坑全部嵌入
- Stage 标题逐字复制(P3-4 防错字):`Stage 1: clone` / `Stage 2: 拉权重` / `Stage 3: 装环境` / `Stage 4: 推理` / `Stage 5: 验证` — **严禁自由发挥(曾出现过"腅环境"错字)**
- 末尾标注"如遇此 runbook 未列的新错误,先 grep `fixes.log` 再问人"

### 第 6 步:写 runbook 文件

```bash
RUNBOOK_PATH="reports/runbooks/${SLUG}-$(date +%Y-%m-%d).md"
cat > "$RUNBOOK_PATH" <<RUNBOOK
<填好的完整 7 节内容>
RUNBOOK

echo "wrote runbook: $RUNBOOK_PATH" >> "$LOG"
```

### 第 7 步:敏感信息 + 反模式扫描(硬性最后一步)

写完后 grep 几次,确保**没泄露**也**没残留 deprecated 命令**:

```bash
# A) 敏感信息(任一返回非空 = 出错)
grep -E "hf_[a-zA-Z0-9]{30,}" "$RUNBOOK_PATH"      # HF_TOKEN 真实值
grep -E "sk-ant-[a-zA-Z0-9_-]{20,}" "$RUNBOOK_PATH" # Anthropic key
grep -F "/root/ai-auto-harness/" "$RUNBOOK_PATH"   # 绝对路径

# B) R 规则违反(P3-5: 命中 = 必须替换,因为 runbook 是给后人执行的脚本,留 deprecated 命令等于继承错误)
grep -E "huggingface-cli\s+(download|upload|login)" "$RUNBOOK_PATH"  # R7 违反: 老命令已 deprecated,必须改 hf
grep -E "pip\s+install\s+.*--no-cache-dir" "$RUNBOOK_PATH"           # R6 违反: launch_worker 已 env 隔离,加了反而每次重下

# C) 若有任一命中,raise + 重写时按下表替换为占位符或正确命令:
#   HF_xxx              → ${HF_TOKEN}
#   sk-ant-...          → ${ANTHROPIC_API_KEY}
#   /root/ai-auto-harness/ → ${HARNESS_ROOT}/
#   huggingface-cli download → hf download
#   huggingface-cli upload   → hf upload
#   huggingface-cli login    → hf login
#   pip install --no-cache-dir → pip install   (直接删掉 --no-cache-dir flag)
```

通过 → 进第 8 步;不通过 → 修后重 grep,直到通过。

### 第 8 步:写 results/runbook.json + 返回

```bash
cat > "$WORKSPACE/results/runbook.json" <<JSON
{
  "slug": "$SLUG",
  "runbook_path": "$RUNBOOK_PATH",
  "runbook_bytes": $(wc -c < "$RUNBOOK_PATH"),
  "status": "<success|incomplete_verify_failed|paused_at_X|blocked_Y>",
  "ai_prompt_word_count": <int, 从 节 2 字数>,
  "stage_count": 5,
  "traps_documented": <int, 已知踩坑 N 的最大 N>,
  "completed_at": "$(date -Iseconds)"
}
JSON

echo "- $(date -Iseconds) by runbook-agent: wrote $RUNBOOK_PATH ($status, $traps_documented traps)" >> "runs/$RUN_ID/decisions.md"
echo "==== runbook end at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_END   phase=runbook slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

## 返回 schema

```json
{
  "slug": "song-generation",
  "runbook_path": "reports/runbooks/song-generation-2026-05-25.md",
  "runbook_bytes": 8234,
  "status": "success",
  "ai_prompt_word_count": 1234,
  "stage_count": 5,
  "traps_documented": 7,
  "completed_at": "2026-05-25T14:34:00+08:00"
}
```

**主 agent** 把这个 return 用于:
1. 写 `runs/$RUN_ID/runbook.json`(本次快照)
2. 更新 `state.json.runbook_path = <path>`
3. 传给 `write-recommendation` 的 `runbook_paths` 参数,日报里加链接
4. 传给 `cleanup-agent` 做 G3 防护(verify runbook 已写)

## 失败 case 的处理

主 agent 即使 verify_passed=false 也会 dispatch 你,这时:

| 输入 verify_passed | 输入 verify_result.failed_at | runbook status | 内容差异 |
|---|---|---|---|
| true | (null) | `success` | 完整 5 stage |
| false | "startup" / "smoke_test" / "gpu_utilization" | `incomplete_verify_failed` | 完整 5 stage,Stage 5 标 ⚠️ + 引 verify_result.evidence |
| false | (没到 verify,主 agent 显式传 force_status="paused_at_X") | `paused_at_<phase>` | 只到该 phase,后续标 "⚠️ 未到达,见 pending_human/<slug>.md" |
| false | (没到任何 phase,资源 preflight 拒) | `blocked_<reason>` | 只到 intake,主要说"为什么没跑成" |

理由:就算没跑通,记下"踩到 stage 3 装环境就崩了"对后人也有 ROI。

## 🔴 反模式(L1 实测出现过的真实问题,**严禁重演**)

> S-1 强化:以下每条都是 phase5 L1 测试里 LLM "自由发挥"撞过的坑,违反 = 直接 raise + 重写。

- ❌ **写 deprecated 命令** — `huggingface-cli download` 必须改 `hf download`(R7,L1 实测被违反)。`pip install --no-cache-dir` 必须删掉 `--no-cache-dir`(R6,launch_worker 已 env 隔离 cache)。第 7 步必扫,命中即重写
- ❌ **Stage 标题自由发挥** — 必须逐字复制:`Stage 1: clone` / `Stage 2: 拉权重` / `Stage 3: 装环境` / `Stage 4: 推理` / `Stage 5: 验证`。L1 实测出现过"腅环境"错字,**直接判失败**
- ❌ **节编号混乱** — 必须与 `_template.md` 一致:1=AI prompt / 2=前置 / 3=5 stage / 4=已知踩坑 / 5=成本 / 6=trace / 7=失败 case。`validate-runbook.sh` 靠 `^## N\.` 抓节,错号会让验收脚本误判
- ❌ **纯 LLM 自由写**整份 — 必须先 `cat _template.md` 套骨架,只在占位符里填空
- ❌ **散文式写"已知踩坑"** — 必须 4 字段结构(触发条件/根因/修复/验证),不许讲故事
- ❌ **泄露敏感信息** — HF_TOKEN / ANTHROPIC_API_KEY / 绝对路径 `/root/ai-auto-harness/`,第 7 步必扫,命中即重写为占位符
- ❌ **"凑"5 stage** — 若实际没跑到 run-and-repair,Stage 4-5 标 ⚠️ 而不是编命令
- ❌ **主动改 state.json** — 主 agent 负责更新 `state.json.runbook_path`,你不动
- ❌ **触动 workspace 其他文件** — 你只写 `reports/runbooks/<slug>-<date>.md` + `logs/runbook.log` + `results/runbook.json`,其他**只读不写**

## 我做错了什么?常见诱惑

- ❌ "fixes.log 里某条修复看起来很冗长,我简化一下表述" — **不**.原文照转更准确,你只把它套成 4 字段结构,不要主观重写
- ❌ "intake / fetch 都没踩坑,我可以不写这两个 stage" — **不**.每个 stage 都要有命令 + 成功标志,即使没踩坑
- ❌ "我看 verify_passed=true,fixes.log 里有的修复应该不重要" — **不**.该项目下次跑同样会撞那些坑,必须列
- ❌ "trace 里看到的命令是 `huggingface-cli`,我就如实记录" — **不**.runbook 是给后人执行的脚本,留 deprecated 命令等于继承错误。**事实优先级**:R 规则 > trace 实录

## ChangeLog

- **2026-06-02** — frontmatter `total_cost_usd` / `duration_min` 填写规则
  - 变更类型: schema 约束
  - 影响范围: 第 2 步 frontmatter 填写规则段
  - 动机: hunyuan3d-2 runbook 写 `total_cost_usd: 0.0`(误导成免费)+ `duration_min: 1469`(混用预估值,P6-1/P6-3)
  - 证据: [fixes/2026-06-02-runbook-cleanup-artifact-accuracy-fix.md](../../../docs/superpowers/fixes/2026-06-02-runbook-cleanup-artifact-accuracy-fix.md)
  - 规则: cost 取不到写 `null` 不写 `0.0`;duration 唯一来源 `state.json` 时间戳,严禁用 AI prompt 节"预计耗时"
