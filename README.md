# AI Auto Harness

> 让 LLM Agent **自主完成**:每天从全网发现 AI 新项目 → 自动部署验证 → 出公司视角建议

一句话:**把"研发同学每天看新 AI 项目 + 写技术调研 + 跑 demo"的事 cron 化**.

---

## 这是什么

一个 **cron 驱动的自动化平台**,每天早上 10:30 自动跑一遍:

1. 从全网 AI 项目源(GitHub trending / HuggingFace / 论文)挑出当日值得关注的开源 AI 项目
2. 按公司 7 条业务线("AI 聊天"/"图像生成"/"视频生成"/"音乐音频"/...)关联打分
3. 挑 1 个最值得跑的项目,**真的**把它部署起来(`git clone` + 拉权重 + 装环境 + 跑出来 + 看输出)
4. 跑不起来 → LLM 自己读错误日志、改代码、改配置,自主修 3 轮
5. 改不了 → 写一份"需要人手做啥"的中文 markdown 文件,等人处理
6. 模型太大跑不动 → 自动生成调用其 API 的最小骨架代码 + 中文使用指导
7. 跑完写一份**今日 AI 项目部署报告**(公司视角建议:试点哪个产品、月度成本估算、双路对比)

**不需要人值守**,失败不会"硬试到爆",**也不会偷偷动你正在跑的训练**(严格的 GPU/磁盘 preflight).

---

## 为什么有这个项目

### 痛点

公司 AI 业务发展快,每天有几十个值得关注的新项目.研发同学的"日常调研"流程是这样:

```
看 HN/X/HuggingFace → 找到几个候选 → 手动 git clone →
装环境踩坑(torch 不对/flash-attn 编不过/HF gated 401) →
拉权重(15GB+ 等几十分钟,中途 SSH 断了就死) →
跑起来再踩坑(CUDA OOM/NaN 输出) →
看输出是否合理(主观判断,容易看走眼) →
写一段建议给老板
```

这套流程**每个项目要花半天到两天**,而且每个工程师踩的坑都不一样(同样 sm_12 / flash-attn 问题被反复解决).

### 之前的方案为什么不够

**方案 A**:`ai-daily-scan`(Python)— 已经做得很好,产报告 + 公司视角建议。但**只看不跑**,推荐的项目最终是否真能跑起来全靠人去验证.

**方案 B**:`auto-deploy-agent`(Python)— 试过手写 5 轮 while 循环 + Rule-based decider 让 agent 跑通项目。**Flux 部署实验**暴露了 8 类痛点(详见下):

| # | Flux 痛点 | Python rule-based 卡在哪 |
|---|---|---|
| 1 | 权重下载在 run 阶段(用尽 timeout) | env_deploy 不预拉权重 |
| 2 | HF cache 不隔离,污染全局 | env_deploy 没强制 HF_HOME |
| 3 | entry_script 提取不准 | 规则匹配 setup.py / cli.py 不够灵活 |
| 4 | 长下载无进度反馈 | subprocess.run 阻塞 |
| 5 | **HF Gated Repo 认证** 🔴 | 完全没处理 |
| 6 | 300s timeout 太短 | 硬编码 timeout |
| 7 | exit_code=-15 误判为 crash | RuleRunDecider 规则有限 |
| 8 | RuleRunDecider 对超时无修复方案 | 规则模式天花板低 |

**核心问题**:规则枚举永远赶不上现场出错的方式.LLM 看现场上下文判断"在下载还是真在跑还是死了"恰好擅长.

### 这平台的核心思路

> **把"看→想→干→验"的 5 轮循环交给 Claude Code 的 agent loop 天然承担**,人写的部分只有:
>   - skill prompt(教 LLM 各阶段该看什么、该决策什么)
>   - 资源 preflight 硬规则(GPU/磁盘/30B,有"不许踩"的红线)
>   - 失败兜底通道(3 轮收敛不了写文件等人)
>   - 跨 cron 接续机制(长下载不必一次跑完)

---

## 🏗️ 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│ cron@10:30  ─→  ./bin/claude-haha --bare ... --print "/auto-daily"     
│                              │                                │
│                              ▼                                │
│              ┌────  daily-auto skill(主 agent)  ────┐         │
│              │                                       │         │
│              │  ① 接续检查(workspace/*/state.json)  │         │
│              │  ② 项目选择(in_progress 优先 / MCP   │         │
│              │     scan_today → 30B/blacklist 过滤)  │         │
│              │  ③ 5 阶段 SubAgent 串行              │         │
│              │  ④ 写报告 + MCP record_outcome 回填   │         │
│              └───────────────┬───────────────────────┘         │
│                              │                                │
│        ┌─────────────────────┼─────────────────────────┐      │
│        ▼      ▼      ▼       ▼          ▼              ▼      │
│     intake fetch install run-and-repair verify   api-skeleton │
│     (1)    (2)   (3)    (4)            (5)      (失败转骨架)   │
│                                                                │
│   人介入通道:任一阶段 3 轮搞不定 → pending_human/<slug>.md     │
│                                                                │
│   产出:                                                       │
│   - reports/<date>.md      公司视角日报(人读)                 │
│   - workspace/<slug>/      项目部署成果(代码+权重+输出)        │
│   - memory/lessons/        跨项目复用经验(LLM 自主积累)         │
│   - runs/<run-id>/         本次 cron 跑的完整 trace(审计)     │
└──────────────────────────────────────────────────────────────┘
                              ▲
                              │ MCP (stdio)
                              ▼
       ┌──────────────────────────────────────────────────────┐
       │ ai-daily-scan(Python,上游)                            │
       │ 7 个子 Agent 每天 9:00 跑流水线,产 findings.jsonl     │
       │ 含公司业务线关联 + 双路成本估算 + 事实核验             │
       └──────────────────────────────────────────────────────┘
```

### 上下游关系

```
┌────────────────────┐  MCP    ┌────────────────────────┐
│  ai-daily-scan     │ ──→─→─→ │   ai-auto-harness      │
│  (Python,你的 GH)   │  stdio  │   (本项目,公司 Gitea)  │
│                    │         │                        │
│  - 9:00 cron 跑    │  ←──←── │  - 10:30 cron 跑       │
│  - 多源 scan       │ MCP     │  - 5 阶段 SubAgent 流水│
│  - 7 子 Agent 分析  │ record  │  - 真部署 + 自主修复    │
│  - 出 findings + 报告 │ _outcome│  - 写日报回填给 scan   │
└────────────────────┘         └────────────────────────┘

[已 deprecated] auto-deploy-agent — Python prompt 经验已迁移到本平台的 lessons
```

---

## 5 个核心设计机制(为什么这么做)

### 1. SubAgent 隔离(避免上下文污染)

**问题**:一个项目部署涉及"读 README + 拉 15GB 权重 + 装环境 + 跑模型 + 修 3 轮失败" — 全在主 agent 一个 200K context 里跑会爆.

**做法**:每个阶段一个 SubAgent(CC `Task` 工具 dispatch),独立 200K context,跑完只返回简短结果给主 agent.

```
主 agent(60K)  ←→  SubAgent A 干 30 分钟,只返回 5 行 JSON 给主
                    ↘ SubAgent B(100K,装环境踩坑)
                     ↘ SubAgent C(120K,跑+修)
```

主 agent 自己 context 永远控制在 60K 以内.

### 2. state.json + 跨 cron 接续

**问题**:拉 15GB 权重要 30 分钟,某些项目装环境要 20 分钟,加 run 一共可能 1 小时+.`claude-haha --print` 模式单次跑撑不到这么久.

**做法**:每个项目工作目录有 `state.json` 记录当前阶段(`intake → fetching → installing → running → verifying → done`)和进度.

- 长任务(主要是 fetch-weights 拉权重)用 `setsid nohup ... &` 启动 background bash,落 PID
- 距离 cron 周期结束 50 分钟时,**不 kill bg shell**,只更 `state.paused_in_progress = true` 让任务在后台继续
- 下次 cron 进来,主 agent 第一步扫 `workspace/*/state.json` → 发现 `phase=fetching` → 重新 dispatch fetch-weights SubAgent,它读 state 自动 resume

```
day-1 cron@10:30 → fetch 跑到 50% (15GB 中 7.5GB) → 50min 时间预算到 → 写 state + bg 继续
day-1 cron@11:30 (主 session 结束)         bg 仍在 disowned 状态后台拉
day-2 cron@10:30 → 主 agent 扫 state.phase=fetching → 接续 fetch SubAgent → resume 已下到 80%
```

### 3. LLM 自主修复(替代 rule-based)

**问题**:run-and-repair 看到错误怎么修?Python rule-based decider 写不完所有情况(参见上面 Flux 8 痛点).

**做法**:`CC agent loop` 本身就是一个 while(true) — 每一轮 ToolUse 自然就是"观察→决策→执行→验收".写好 skill prompt 教 LLM:

```
每轮必做:
  1. 观察:tail run.log + nvidia-smi + ls workspace + 看 exit code
  2. 决策(LLM 判断):
     - exit 0 + 预期文件存在 → 成功
     - "CUDA out of memory" → 减 batch / 量化
     - exit=-15 (SIGTERM) → 超时被杀,看是不是在下载
     - exit=137 (OOMKill) → 内存不足
     - 输出 NaN + 5090 → sm_12 wheel 问题(读 memory/lessons/torch-sm12.md)
     - ... 8 种常见模式映射
  3. 执行修复:Edit 代码 / pip 装/卸 / 改环境变量
  4. 验收:重跑 → 回到第 1 步
```

**3 轮硬上限** — 不收敛就调 `request-human-intervention` skill,不要 Python 时代"硬试 5 轮浪费 token"的坏习惯.

### 4. HF cache 隔离 + 资源 preflight

**问题**:多个项目同时跑,HF cache 混到 `~/.cache/huggingface` 会互相污染;不做 GPU/磁盘预检会偷偷动用户的训练.

**做法**(写到 skill prompt 里强制执行):

```bash
# 每个项目工作目录前 export 3 个 env(任何 bash 调用前必须做)
export HF_HOME=$WORKSPACE/.cache/huggingface
export HF_HUB_CACHE=$WORKSPACE/.cache/hf_hub
export TRANSFORMERS_CACHE=$WORKSPACE/.cache/transformers
```

```python
# 资源 preflight 硬规则(intake 阶段必跑)
- 单卡 used ≥ 25GB → 拒动(留 7GB 给训练做 buffer)
- 叠加预估后剩余 < 2GB → 拒动
- 磁盘 free < (估算权重大小 + 50GB safety) → 拒动 + 提示清理
- 模型激活参数 > 30B → 不 self-host,改走 api-skeleton 生成调用骨架
```

**结果**:你训练时跑 cron,大概率所有 GPU 都过不了 preflight → agent 优雅地写 pending_human 跳过本日,**不会乱动 GPU**.

### 5. Human-in-the-loop 通道(失败兜底)

**问题**:agent 不是万能,遇到 HF gated repo 没 token / 资源短期不可恢复 / 修复 3 轮收敛不了 等,必须有个"求救"通道,而不是默默崩溃.

**做法**:任何 SubAgent 都可调 `request-human-intervention` skill,写一份**中文 markdown** 到 `pending_human/<slug>.md`:

```markdown
# flux-schnell — 需要人手介入

**原因类别**:auth_missing
**当前阶段**:fetching

## 我尝试过什么
- 探测到 hf_repos 中 black-forest-labs/FLUX.1-schnell 是 gated
- 检查 $HF_TOKEN 不存在
- 试 huggingface-cli download README.md --quiet → 401

## 建议人手做的事
- 去 https://huggingface.co/black-forest-labs/FLUX.1-schnell 同意 license
- 去 https://huggingface.co/settings/tokens 创建 read token
- 把 token 加到 .env: HF_TOKEN=hf_xxx
- **删除本文件** → 下次 cron 会重新尝试

## 上下文
- workspace: workspace/flux-schnell/
- trace: runs/2026-05-19-1030-<pid>/
```

下一次 cron 主 agent 进来:
- 先扫 `pending_human/`,文件还在 → 在今日报告里继续标"等人"
- 文件被删 → 把 state.phase 重置到 paused 之前的阶段,从那继续

**人就是这个系统的最后一道保险** — agent 不知道怎么修时不要硬试,留对人友好的提示.

---

## 5 阶段 SubAgent 详细流程

### Stage 1:`intake` — 准备工作

| 输入 | 主 agent 选好的 finding(github_url + hf_repos + 估算大小) |
|---|---|
| 做什么 | `git clone --depth=1` + 读 README/setup/req → 推断 entry_script → 跑 preflight(GPU/磁盘/gated/30B) |
| 输出 | `{entry_script, hf_deps, gpu_picks, blocked}` |
| 失败处理 | blocked 非空 → 写 pending_human(磁盘满 / gated 无 token / 模型 > 30B 等) |
| 工具限制 | 只 Read + Write + Bash + Grep,**不能 Edit**(intake 不改代码) |

### Stage 2:`fetch-weights` — 拉权重(可跨 cron)

| 输入 | hf_deps + workspace_path |
|---|---|
| 做什么 | `setsid nohup huggingface-cli download` 启动 background → 周期 poll 进度 → 卡死判定(30min 无增长 → kill 重启) → 时间预算到了不 kill 让 bg 继续 |
| 输出 | `{weights_done, paused_in_progress, bytes_total}` |
| 关键 | 强制 HF cache 隔离;支持 `--resume-download` 接续 |

### Stage 3:`install-env` — 装环境

| 输入 | workspace_path + entry_script + requirements_files |
|---|---|
| 做什么 | 建 venv → pip install → **torch sm_12 检测**(5090 必做)→ 不通过装 nightly cu124 → 常见 build issue 修复(flash-attn / bitsandbytes / nvcc) |
| 输出 | `{venv_path, deps_ok, fixes_applied}` |
| 关键 | 优先读 `memory/lessons/{torch-sm12,flash-attn-build}.md` 找已有经验;3 次重装上限 |

### Stage 4:`run-and-repair` — 跑 + 修(核心)

| 输入 | workspace_path + venv_path + entry_script + gpu_picks |
|---|---|
| 做什么 | 试跑 entry_script(长任务 background)→ 观察(stderr/nvidia-smi/文件)→ LLM 决策(8 类错误模式映射)→ 修复 → 验收 |
| 输出 | `RunResult{passed, error_class, repair_count, gpu_snapshot, fixes_applied}` |
| 关键 | **CC agent loop 本身就是 repair loop**;3 轮硬上限,不收敛即 raise pending_human |

### Stage 5:`verify` — 独立判定

| 输入 | workspace_path + venv_path + entry_script(**不传 run_result**) |
|---|---|
| 做什么 | 当成"刚拿到 workspace 的新工程师" → 启动检查 → smoke test → GPU 利用率检查 |
| 输出 | `VerifyState{passed, failed_at, evidence, confidence}` |
| 关键 | **工具集只有 Read + Bash**(故意无 Edit/Write 防"顺手修");不读 run_result 字段以保持独立判定 |

---

## 完整目录结构

```
/root/ai-auto-harness/                  (基于 claudecode_sourcecode1 fork)
│
├── src/, bin/, package.json …          Claude Code 源码(不动,upstream 同步)
│
├── .env                                ANTHROPIC_API_KEY / BASE_URL / HF_TOKEN
├── .env.example
├── README.md                           本文件
│
├── .claude/                            CC 项目级配置
│   ├── CLAUDE.md                       项目硬约束 + 工作流(LLM 加载到 system prompt)
│   ├── settings.json                   权限白名单 + MCP scan server 配置 + hook 注册
│   ├── hooks/                          (TUI 模式生效;cron 用 --bare 跳过)
│   │   ├── session-start.sh            生成 run-id + 加载今日上下文
│   │   ├── post-tool-use.sh            追写 transcript.jsonl
│   │   └── session-end.sh              git commit + 清理老 runs
│   ├── skills/                         16 个自定义 skill(CC 自动识别 <name>/SKILL.md)
│   │   │
│   │   ├── auto-daily/SKILL.md         主 agent 顶层(/auto-daily 触发)
│   │   ├── auto-status/SKILL.md        只读看状态(/auto-status)
│   │   ├── auto-deploy/SKILL.md        手动单项目(/auto-deploy <url>)
│   │   ├── auto-recover/SKILL.md       强制接续(/auto-recover)
│   │   │
│   │   ├── intake/SKILL.md             Stage 1
│   │   ├── fetch-weights/SKILL.md      Stage 2
│   │   ├── install-env/SKILL.md        Stage 3
│   │   ├── run-and-repair/SKILL.md     Stage 4
│   │   ├── verify/SKILL.md             Stage 5
│   │   │
│   │   ├── api-skeleton/SKILL.md       不能 self-host 时产 API 调用骨架
│   │   ├── request-human-intervention/SKILL.md  人介入通道
│   │   ├── preflight-gpu-disk/SKILL.md GPU/磁盘/gated/30B 子能力
│   │   ├── write-recommendation/SKILL.md 主 agent 写日报 + MCP 回填
│   │   │
│   │   ├── verifier-corrector/SKILL.md 报告事实核验(借鉴 ai-daily-scan)
│   │   ├── coverage-gaps/SKILL.md      跨日盲区(借鉴)
│   │   └── cost-analysis/SKILL.md      双路成本表(借鉴)
│   │
│   └── agents/                         SubAgent 角色定义(限工具集 + 反模式)
│       ├── intake-agent.md
│       ├── fetch-agent.md
│       ├── install-agent.md
│       ├── runner-agent.md
│       └── verify-agent.md
│
├── cron/
│   ├── daily.sh                        cron@10:30 入口(--bare + --add-dir + --settings)
│   └── crontab.example                 安装 crontab 参考
│
├── workspace/<slug>/                   每项目隔离工作目录(.gitignored)
│   ├── state.json                      阶段进度(跨 cron 接续核心)
│   ├── repo/                           git clone 的项目代码
│   ├── venv/                           Python venv
│   ├── .cache/                         隔离的 HF/transformers cache(强制 HF_HOME)
│   ├── progress.md                     fetch-weights 阶段的下载进度摘要
│   └── api_skeleton/                   API 路线产出(client.py + 使用指导.md 等)
│
├── runs/<run-id>/                      每次 cron 跑的完整 trace(.gitignored)
│   ├── meta.json                       run 元数据
│   ├── decisions.md                    agent 主动写的关键决策(审计材料)
│   ├── intake.json / fetch.json / ...  各 SubAgent 返回
│   └── transcript.jsonl                tool_use 流(--bare 模式下需 skill 自己写)
│
├── reports/<YYYY-MM-DD>.md             每日总报告(人读,git tracked)
│
├── memory/
│   ├── projects/<slug>.md              项目专属经验(部署一次的踩坑记录)
│   └── lessons/                        跨项目复用经验(LLM 自主积累)
│       ├── torch-sm12.md               5090 sm_12 wheel 修复(3 种方案)
│       ├── hf-gated.md                 gated repo 处理(token vs license)
│       └── flash-attn-build.md         prebuilt wheel 智能选择
│
├── pending_human/<slug>.md             需要人手介入的项目(.gitignored,人删文件即解除)
├── state/blacklist.jsonl               agent 自主写入的 blacklist
│
└── docs/superpowers/
    ├── specs/2026-05-19-ai-auto-harness-design.md  完整设计文档(16 节)
    ├── plans/2026-05-19-ai-auto-harness-implementation.md  实施 plan(46 task)
    └── phase2-test-setup.md            Phase 2 e2e 验证 setup memo
```

---

## 🚀 快速开始(完整 walkthrough)

### 前置准备

```bash
# 1. 装 bun(运行 CC 必需)
curl -fsSL https://bun.sh/install | bash

# 2. 装 CC 依赖
cd /root/ai-auto-harness
bun install

# 3. 配 .env
cp .env.example .env
vim .env
#   ANTHROPIC_API_KEY=<你的 key>
#   ANTHROPIC_BASE_URL=<API endpoint,如 MiniMax / Astron / 官方>
#   ANTHROPIC_MODEL=<模型 ID>
#   HF_TOKEN=<可选,部署 gated repo 时需要>
```

### Step 1:看现状(只读,不动 GPU/磁盘)

```bash
./bin/claude-haha \
    --bare \
    --add-dir . \
    --settings .claude/settings.json \
    --print "/auto-status"
```

输出例:

```markdown
## AI Auto Harness — 平台状态

| 维度 | 状态 |
|------|------|
| In-progress 项目 | 无 — workspace/ 为空 |
| 待人手处理 | 无 — pending_human/ 不存在 |
| GPU 状况 | ⚠️ 8 卡均 ≥ 25GB 占用(你的训练在跑) |
| 磁盘 free | 487 GB |

### 总结
平台 idle.GPU 全占用,新部署会被 preflight 拒绝.等训练完再 trigger.
```

### Step 2:手动单项目部署(用 SongGeneration 走一遍)

```bash
./bin/claude-haha \
    --bare \
    --add-dir . \
    --settings .claude/settings.json \
    --print "/auto-deploy https://github.com/tencent-ailab/SongGeneration"
```

完整 flow(预计 30-60 分钟):

```
1. analyze_project 跑一次 ad-hoc Analyst → 拿 finding(4B / 15GB / 非 gated / scenario_005)
2. 30B 阈值 OK → 进 5 阶段流水线
3. intake: git clone + 读 README + preflight → GPU 拿到 GPU 3 + 4
4. fetch-weights: huggingface-cli download tencent/SongGeneration(15GB,后台 background)
   ├── 周期 poll 进度写到 progress.md
   └── 完成
5. install-env: venv + pip install -e . + torch sm_12 检测
   ├── 发现 stable torch 不支持 sm_12
   └── 装 nightly cu124 → ok
6. run-and-repair: python sample.py
   ├── round 1: CUDA OOM
   ├── 修复:改 config batch_size 8 → 1
   └── round 2: pass,出 sample/output/audio_001.mp3
7. verify: 独立 SubAgent 跑 smoke + GPU 利用率检查
   └── 通过(GPU 87% 利用率,文件 mp3 4.2MB,合理)
8. write-recommendation: 写 reports/2026-05-19.md + MCP record_outcome 回填
```

### Step 3:看产出

```bash
cat reports/2026-05-19.md            # 中文日报
cat workspace/song-generation/state.json | jq  # 阶段进度
ls workspace/song-generation/repo/sample/output/  # 生成的音频文件
cat runs/$(cat runs/.current_run_id)/decisions.md  # agent 决策轨迹
```

### Step 4:部署每日自动 cron

```bash
crontab -e
# 加这一行(注意 scan@9:00 跑完才能跑 deploy@10:30):
30 10 * * * /root/ai-auto-harness/cron/daily.sh
```

### Step 5(出问题时):看 pending_human/

```bash
ls pending_human/
cat pending_human/<slug>.md   # 看 agent 为啥 raise + 建议你做啥
# 按指引处理(配 HF_TOKEN / 等 GPU / 等)
rm pending_human/<slug>.md    # 删了文件,下次 cron 自动重试
```

---

## 🔧 关键设计决策(为什么这么选)

| 决策 | 选 | 没选 | 为什么 |
|---|---|---|---|
| Agent loop | CC `query.ts` while(true) | 手写 Python while | 5 轮规则枚举不够,LLM 天然适合"看现场判断" |
| SubAgent 隔离 | CC `Task` 工具(单层嵌套) | 主 agent 全包 | 单项目 100K+ context 不爆主 agent |
| 跨 cron 接续 | `state.json` + `setsid nohup` bg | 一次 cron 跑完 | 15GB 下载 + 装环境总 1h+,单次 --print 撑不住 |
| 自主修复上限 | 硬性 3 轮 → pending_human | LLM 自己决定 | 防"硬试 4 5 6 轮"浪费 token + 时间 |
| HF cache | 每项目独立 `HF_HOME` | 共享 ~/.cache | 多项目同跑会污染,人手清理麻烦 |
| GPU preflight 阈值 | 单卡 ≥ 25GB 拒动 | 严格 0 占用 | 留 7GB 给训练做 buffer,共享集群常态 |
| 模型大小阈值 | self-host ≤ 30B | 无上限 | 30B 以上 5090 8 卡 ROI 差,API 划算 |
| 报告 destination | 本地 reports/<date>.md | 邮件 / Slack | MVP 先不依赖外部服务,后续可加 |
| CC 启动模式 | `--bare`(跳 OAuth/keychain/plugin) | 默认完整启动 | 公司内网 Privoxy 拦截让默认启动挂死 |
| 失败处理 | 写 markdown 给人 | 静默重试或邮件告警 | 中文 markdown 是最低运维成本的接口 |

---

## ⚙️ 运维 / 常见操作

### 日常

```bash
./bin/claude-haha --bare --add-dir . --settings .claude/settings.json --print "/auto-status"
# → 看现状

cat reports/$(date +%Y-%m-%d).md
# → 看今日报告

ls pending_human/
# → 看积压
```

### 手动 trigger

```bash
# 跑常规流程(挑新项目 OR 接续 in_progress)
./bin/claude-haha --bare --add-dir . --settings .claude/settings.json --print "/auto-daily"

# 强制接续(只跑 in_progress,不挑新项目)
./bin/claude-haha --bare --add-dir . --settings .claude/settings.json --print "/auto-recover"

# 部署指定项目(跳过 scan pick)
./bin/claude-haha --bare --add-dir . --settings .claude/settings.json --print "/auto-deploy https://github.com/x/y"
```

### 故障排查

| 症状 | 看哪 | 怎么修 |
|---|---|---|
| cron 没产 reports | `runs/cron-<ts>/cron.{out,err,status}` | 看 stderr 有啥 |
| 项目卡在 fetch | `workspace/<slug>/progress.md` + `.cache/<repo>.pid` | `kill -0 <pid>` 看 bg 还活着不;`ls workspace/<slug>/.cache/hf_models/<repo>` 看下到多少 |
| run-and-repair 死循环 | `runs/<run-id>/decisions.md` | 应该 3 轮就停;若没停查 skill prompt |
| 磁盘满 | `df -h /root` + `du -sh workspace/*` | 清 7 天前 workspace + `runs/` |
| GPU 全被训练占 | `nvidia-smi` | 等训练完,或调 preflight 阈值(.claude/skills/preflight-gpu-disk/SKILL.md) |

### 清理

```bash
# 清 7 天以上 runs
find runs/ -maxdepth 1 -mtime +7 -type d -exec rm -rf {} \;

# 清已 done 的 workspace(权重最占空间)
# 谨慎:可能丢已下完的权重,下次再跑要重下
ls workspace/
# 单个删:rm -rf workspace/<slug>/
```

### 后续

```bash
# CC 上游升级
cd /root/ai-auto-harness
git pull upstream main      # 合并 CC 新版本

# 自己改动用 ai-auto 前缀
git commit -m "ai-auto: ..."

# 看自己的 commit
git log --grep=ai-auto
```

---

## 已知限制 / 待验证

| # | 项 | 状态 |
|---|---|---|
| 1 | `--bare` 模式下 `Bash(run_in_background)` + `setsid nohup` 跨 CC 进程退出能否真持久 | **待 Phase 2 e2e 验证** |
| 2 | `--print` 模式撑得过 30+ 分钟 long-running session 吗 | **待 Phase 2 e2e 验证** |
| 3 | 我们的 SubAgent dispatch 与 Anthropic 官方 SubAgent API 行为差异 | 用上后看 |
| 4 | Verify SubAgent 内部还能不能再开 SubSubAgent | CC 单层嵌套限制,Phase 5 可考虑子进程升级 |
| 5 | pending_human 无主动通知(邮件/Slack)— 全靠人去看 | Phase 5 可加 webhook |
| 6 | 单次 cron N=1 项目 | 后续可扩 N=2/3 并发(GPU 抢占需协调) |

---

## 深入阅读

- **完整设计文档**(16 节,含数据 schema / Flux 8 痛点对照 / human-in-loop / 风险登记):
  → [docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md](docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md)

- **实施 plan**(46 task,Phase -1 → 4,含每步代码/测试/commit):
  → [docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md](docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md)

- **上游(信号来源)**:[ai-daily-scan](https://github.com/haichengmai20-hub/ai-daily-scan) — 7 子 Agent 流水线 + 公司业务画像

- **已替代(prompt 经验来源)**:[auto-deploy-agent](http://192.168.1.227/dangchenrui/auto-deploy-agent) — Python 实现的旧版,domain knowledge 已迁移到 `memory/lessons/`

---

*基于 Claude Code 源码 + 自定义 13 skill + 5 SubAgent · `--bare` 模式 · MCP 协议*
