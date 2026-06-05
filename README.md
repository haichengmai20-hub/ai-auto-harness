# AI Auto Harness

> 让 LLM Agent **自主完成**:每天从全网发现 AI 新项目 → 自动部署验证 → 出公司视角建议

一句话:**把"研发同学每天看新 AI 项目 + 写技术调研 + 跑 demo"的事 cron 化**.

**当前进度**(2026-05-22):Phase 1-4 代码完成 · SongGen e2e 试跑暴露 R1/R4/R6/R9 LLM 自觉度问题 · 加入 PostToolUse hook 做 harness 层硬约束 · 待跑 SongGen run4 验证 hook 有效性 · 待跑 5+ 不同类型项目扩样本广度

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

## 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│ cron@10:30  ─→  cron/daily.sh                                 │
│                  ├─ env-level cache 隔离(HF_HOME/PIP_*/TORCH_*)│
│                  └─ IS_SANDBOX=1 + --dangerously-skip-perms   │
│                     --output-format stream-json --verbose      │
│                              │                                │
│                              ▼                                │
│              ┌────  auto-daily skill(主 agent)  ────┐         │
│              │  仅做 4 件事:路由 / 状态机 / Task()  │         │
│              │  dispatch / 聚合写报告 — 严禁自己 bash│         │
│              │                                       │         │
│              │  ① 接续检查(workspace/*/state.json)  │         │
│              │  ② 项目选择(in_progress 优先 / MCP   │         │
│              │     scan_today → 30B/blacklist 过滤)  │         │
│              │  ③ 5 阶段 SubAgent 串行(Task() 工具) │         │
│              │  ④ 写报告 + MCP record_outcome 回填   │         │
│              └───────────────┬───────────────────────┘         │
│                              │ Task(subagent_type=...)         │
│        ┌─────────────────────┼─────────────────────────┐      │
│        ▼      ▼      ▼       ▼          ▼              ▼      │
│     intake fetch install run-and-repair verify   api-skeleton │
│     (1)    (2)   (3)    (4)            (5)      (失败转骨架)   │
│                                                                │
│   每 SubAgent 进出 echo PHASE_START/END(ndjson 可 grep)        │
│   每 SubAgent 必须更新 workspace/<slug>/state.json             │
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

## 🔴 项目级硬规则(R1-R9)

试跑事故复盘后沉淀,全部写在 [.claude/CLAUDE.md](.claude/CLAUDE.md) 顶部,所有 SubAgent 自动加载:

| 规则 | 内容 | 防的是什么 |
|---|---|---|
| **R1** workspace 隔离 | 只动自己的 `$WORKSPACE`;严禁读/写/`kill` 其他 workspace 的内容或 PID | run2:agent 看见旧 run 半成品权重 → kill 别人 → 自己空转 |
| **R2** state.json 双写 | 每个 phase 开始 + 结束都用 jq 更新 `phase` / `status` / `phases_done` | run2:整个 run state 停在 intake,monitor 看不见进度 |
| **R3** phase wall-clock 上限 | intake 15min / fetch 180min / install 60min / run 45min×3 / verify 30min,超时 → `paused_for_human` | 无限 sleep 直到 cron 超时 |
| **R4** 禁 sleep 浪费 turn | (1) 单次 sleep ≤ 60s;(2) **连续 sleep 绝对禁** — 上一 turn 是 sleep 则这一 turn 不许;(3) poll ≤ 8 turn,超过 `paused_in_progress` 退出让 cron 接续 | run2:270min 总 sleep,8 段连续 sleep 链(其中 3 段长 5),烧 $20.70 干 0 件有意义的事 |
| **R5** fetch / install 串行 | 带宽是单根管道,fetch 必须 done 才进 install,不并行抢 | run2:pip torch 2GB 与 hf 28GB 同时跑,各慢一倍 |
| **R6** 禁 `pip install --no-cache-dir` | `PIP_CACHE_DIR` 已 env-level 隔离,加 `--no-cache-dir` 反而每次重下 wheel | run2:cmd 25 显式加了,白下载 |
| **R7** 用 `hf` 不用 `huggingface-cli` | 后者已 deprecated 无加速;`hf download --token "$HF_TOKEN"`(默认断点续传,无 `--resume-download`)+ `HF_XET_HIGH_PERFORMANCE=1`(Xet 后端,非废弃的 `HF_HUB_ENABLE_HF_TRANSFER`) | run2:用了 `huggingface-cli` + 无 token + 无加速 → 0.3MB/s |
| **R8** PHASE_START/END 标记 | 每 SubAgent 进出 echo `=== PHASE_START phase=X slug=Y run_id=Z ts=...` / `=== PHASE_END phase=X slug=Y status=done ts=...`,monitor `grep -E "^=== PHASE_"` 直接拿事件 | ndjson 无结构化阶段事件 |
| **R9** 其他 | 主 agent 不亲自 bash;run-and-repair 不超 3 轮;不污染全局 HF cache;verify 不修问题 | (从原"不要做"段保留) |

## 🛡️ R 规则如何被强制(harness 层硬约束)

光写在 skill prompt 里 LLM 会忽略(run2 实测:R1/R4/R6 全部违反,但当时还没 R1-R9 文字 ✗)。所以在 **harness 层**加了三道防御:

### 1️⃣ PostToolUse hook 实时检测 → 注入 LLM 下一 turn

**文件**:[.claude/hooks/post-tool-use.sh](.claude/hooks/post-tool-use.sh)

每次 `tool_use` 事件触发(任何 Bash 命令执行后),hook 用 python3 解析 event,做下面检测:

| 规则 | 检测逻辑 | 输出 |
|---|---|---|
| R4.1 | 命令含 `sleep N`,N > 60 | 注入 warning(下一 turn LLM 看到) |
| R4.2 | 本次 sleep + 上一 turn 也 sleep(从 `hook_state.json` 读 last_cmd) | 注入"连续第 N 次 sleep,立刻停" |
| R4.5 | poll 类操作(tail/sleep/kill -0/du -s/ps aux)累计 > 8 次 | 注入"paused_in_progress 退出比硬等划算 1000 倍" |
| R1 | 命令含 `kill <pid>`,pid 不在 `workspace/<own_slug>/.cache/*.pid` 里 | 注入"那是别人 run / 用户训练" |
| R1.2 | 命令引用 `workspace/<other-slug>/` 路径 | 注入"本 run 只能动自己的 workspace" |
| R6 | 命令含 `--no-cache-dir` | 注入"PIP_CACHE_DIR 已隔离,去掉这个 flag" |
| R9 | Bash 累计 > 5 次但 0 次 Task() + 命令含 git clone/hf download/pip install | 注入"你可能是主 agent 在干 SubAgent 的活" |

**机制**:hook 不能 BLOCK 已执行的命令,但通过 `hookSpecificOutput.additionalContext` 把告警塞进 LLM 的下一 turn context — 比 skill prompt 软约束硬十倍(LLM 看 system-reminder 比看 skill 文档认真得多)。

### 2️⃣ launch_worker.sh 启动时初始化 `hook_state.json`

```bash
bash cron/launch_worker.sh "<prompt>" "<log_dir>" [<slug>]
                                                       ^^^^^^
                                                 第3参数 slug 写入
                                                 hook_state.own_slug
                                                 (R1 检测启用)
```

### 3️⃣ `--append-system-prompt` 注入 R1-R9 浓缩版

launch_worker.sh 和 daily.sh 都在 claude-haha 启动时通过 `--append-system-prompt` 把 R1/R4/R5/R6/R9 的浓缩版注入 system prompt — 让主 agent 启动第一 turn 就看到规则,不依赖它去 cat CLAUDE.md。

### 4️⃣ trap cleanup + worker.pid 防僵尸进程

```bash
echo "$$" > "$LOG_DIR/worker.pid"
trap cleanup EXIT INT TERM
```

worker 异常退出时清理 claude-haha 子进程。启动前还会扫所有 `runs/*/worker.pid`,对**已死**的 worker 找它的 `.cache/*.pid` 孤儿 bg 进程清掉(不动活的 worker)。

---

## 5 个核心设计机制(为什么这么做)

### 1. SubAgent 隔离(强制 — 避免上下文污染 + 防架构退化)

**问题**:一个项目部署涉及"读 README + 拉 28GB 权重 + 装环境 + 跑模型 + 修 3 轮失败" — 全在主 agent 一个 200K context 里跑会爆;**更严重**的是主 agent 在同一 context 里会做出烂决策(SongGen run2 实测:主 agent 自己起下载 → 太慢自己 kill → 启 pip → 抢同根带宽 → 又 kill 别的 run 的下载抢资源 → 空转 1h)。

**做法(强制)**:每个阶段一个 SubAgent(CC `Task` 工具 dispatch),独立 200K context。主 agent **仅做** 4 件事:

1. 路由决策(30B / gated / 复用 workspace)
2. 状态机推进(读 state.json → 选下一 phase)
3. `Task(subagent_type="<phase>-agent", prompt=...)` dispatch
4. 结果聚合 + 写报告

**主 agent 严禁** 自己 `Bash(git clone / hf download / pip install / python ...)` — 那都是 SubAgent 的事。violation 检测:看 ndjson `tool_use.name` 分布,主 agent 的 Bash 应该 < 5 次(只读 state.json / 写 meta.json),fetch 的密集 hf download Bash 必须落在 fetch-agent 的子 context。

```
主 agent(60K)  ──Task()──→  fetch-agent(独立 200K,只下不装)
                ──Task()──→  install-agent(独立 200K,只装不跑)
                ──Task()──→  runner-agent(独立 200K,跑+修 3 轮)
```

SubAgent context 隔离自动强制串行 + 单一职责,不会发生"顺手抢带宽"的烂决策。

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

#### ⚠️ 关于 resume 的两种概念(常被混淆,SongGen run3 实测澄清)

| | session-level resume | **workspace-level resume(本平台用这个)** |
|---|---|---|
| 机制 | `claude-haha --resume <session_id>` 复用同一 conversation token cache(~130K+ 历史) | 新 session 起来,prompt 引导 + 读 `workspace/<slug>/state.json` + 复用已下权重 |
| 优点 | 上下文连续无歧义 | 干净 context,不带前次烂决策的 token 残留 |
| 风险 | 若前次因 LLM 烂决策(R4 violation)stop,resume 后**继续烂决策烧钱** | 需要 state.json 写得明白 + LLM 看懂接续 |
| 何时用 | API 真断了想接 5 分钟前对话(本平台**不用**) | cron 接续 / 手动 retry / pause→resume(本平台**默认**) |

**为什么不加自动重试 `MAX_RETRIES=3 + --resume`**(评审建议过):
- run2 实测退出原因 `stop_reason='stop_sequence', is_error=True, num_turns=131` — 是 **LLM 自己 stop**(R4 sleep loop 烧光 budget),不是 API ECONNRESET
- 盲 retry 会复制烂决策再烧 $20.70。已加 PostToolUse hook 实时 warn R4 violation 是更治本的方案
- workspace-level resume 已经 work(run3 启动 7 分钟即进入 output 阶段,不重下 29GB 权重)

#### ⚠️ 关于 HF cache 隔离与权重持久(常被误判)

**关键**:权重通过 `hf download --local-dir $WORKSPACE/.cache/hf_models/<repo>` **直接落 workspace 持久目录**,不经过 HF_HOME 中转。

```
launch_worker.sh env-level:  HF_HOME = $LOG_DIR/.cache/huggingface  (run-specific, 每次新建)
                                              ↓ 但权重不走这里 ↓
fetch-weights skill 实际:    hf download --local-dir $WORKSPACE/.cache/hf_models/<repo>
                                              ↓
                             $WORKSPACE/.cache/hf_models/<repo>/  (workspace 持久,跨 run 复用)
```

下次 run 启动,即使 HF_HOME 是新隔离目录,`hf download`(默认断点续传)看到 `--local-dir` 里已有文件就 resume。**HF cache 隔离 ≠ 权重重下**。

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

**问题**:多个项目同时跑,HF cache 混到 `~/.cache/huggingface` 会互相污染;不做 GPU/磁盘预检会偷偷动用户的训练。**更要命**的是:系统 `~/.cache/huggingface` 可能已有该项目的权重,LLM 一不留神就走 cache 30 秒"下载"完 28GB — 等于作弊。

**做法**(双层防御):

1. **launcher 层 env-level 强制**(`cron/launch_worker.sh` / `cron/daily.sh`):每个 run 起 worker 前,在 env 设默认 HF_HOME / HF_HUB_CACHE / TRANSFORMERS_CACHE / TORCH_HOME / PIP_CACHE_DIR / XDG_CACHE_HOME 指向 `runs/<run-id>/.cache/*`,即使 LLM 漏 export 也走隔离 cache,**杜绝走系统 cache 作弊**。
2. **skill 层软重复**(双保险):每次新开 bash 前 SubAgent 再 `export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"` 一遍。

```bash
# launcher 强制(launch_worker.sh):
ISOLATED_CACHE="$LOG_DIR/.cache"
export HF_HOME="$ISOLATED_CACHE/huggingface"
export HF_HUB_CACHE="$ISOLATED_CACHE/huggingface"
export TRANSFORMERS_CACHE="$ISOLATED_CACHE/huggingface"
export TORCH_HOME="$ISOLATED_CACHE/torch"
export PIP_CACHE_DIR="$ISOLATED_CACHE/pip"
export XDG_CACHE_HOME="$ISOLATED_CACHE/xdg"
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
| 做什么 | `git clone --depth=1` + 读 README/setup/req → 推断 entry_script → **抽 weight_target_paths**(grep `ckpt/` / `weights/` / `models/` 的 hardcode 路径)→ 跑 preflight(GPU/磁盘/gated/30B) |
| 输出 | `{entry_script, hf_deps, weight_target_paths, gpu_picks, blocked}` |
| 失败处理 | blocked 非空 → 写 pending_human(磁盘满 / gated 无 token / 模型 > 30B 等) |
| 工具限制 | 只 Read + Write + Bash + Grep,**不能 Edit**(intake 不改代码) |

### Stage 2:`fetch-weights` — 拉权重(可跨 cron)

| 输入 | hf_deps + workspace_path + intake.json(取 weight_target_paths) |
|---|---|
| 做什么 | `HF_XET_HIGH_PERFORMANCE=1 setsid nohup hf download <repo> --token "$HF_TOKEN" --local-dir ...`(默认断点续传,不加 `--resume-download`)→ 周期 poll(不 sleep)→ 下完按 weight_target_paths 建 symlink 到 `$WORKSPACE/repo/<target_rel>` |
| 输出 | `{weights_done, paused_in_progress, bytes_total}` |
| 关键 | env-level + skill-level 双重 HF cache 隔离;`hf` 不用 `huggingface-cli`(R7);严禁 foreground sleep(R4);严禁动其他 workspace(R1) |

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
│   ├── hooks/                          SessionStart / PostToolUse / SessionEnd
│   │   ├── session-start.sh            run-id 注册 + 加载今日上下文
│   │   ├── post-tool-use.sh            🛡️ **R1/R4/R6/R9 硬约束检测** + transcript 落盘(python3 实现)
│   │   └── session-end.sh              清理 + 归档
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
│   ├── daily.sh                        cron@10:30 入口(IS_SANDBOX + dangerously-skip-perms + env-level cache 隔离 + trap cleanup)
│   ├── launch_worker.sh                通用 worker 启动器 — 第 3 参数 slug 激活 R1 检测;trap cleanup 防僵尸
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
│   ├── meta.json                       run 元数据(含 slug + isolated_cache 路径)
│   ├── worker.pid                      launch_worker.sh / daily.sh 的 PID(trap cleanup 用)
│   ├── haha.pid                        claude-haha 子进程 PID
│   ├── .hook_state.json                PostToolUse hook 跨 turn 状态(连续 sleep 计数 / own_slug / bash_count)
│   ├── .cache/                         env-level 隔离 cache(huggingface / pip / torch / xdg)
│   ├── decisions.md                    agent 主动写的关键决策(审计材料)
│   ├── intake.json / fetch.json / ...  各 SubAgent 返回(快照)
│   ├── transcript.jsonl                PostToolUse hook 落盘的完整 tool_use 流
│   ├── harness.stdout.ndjson           CC `--output-format stream-json` 完整事件流
│   ├── harness.stderr.log              stderr
│   ├── trajectory.json                 跑完后抽的简化事件(meta/result)
│   └── cron.status                     `exit=<N>` 结束状态
│
├── reports/<YYYY-MM-DD>.md             每日总报告(人读,git tracked)
│
├── memory/
│   ├── projects/<slug>.md              项目专属经验(部署一次的踩坑记录)
│   └── lessons/                        跨项目复用经验(LLM 自主积累)
│       ├── torch-sm12.md               5090 sm_12 wheel 修复(3 种方案) + requirements.txt pin 冲突剥离套路 + numpy 降级修复
│       ├── hf-gated.md                 gated repo 处理(token vs license)
│       └── flash-attn-build.md         prebuilt wheel 智能选择
│
├── pending_human/<slug>.md             需要人手介入的项目(.gitignored,人删文件即解除)
├── state/blacklist.jsonl               agent 自主写入的 blacklist
│
└── docs/
    ├── songgen-e2e-test-guide.md       SongGen e2e 跑通指南(action-first + 跑死接续协议)
    └── superpowers/
        ├── specs/2026-05-19-ai-auto-harness-design.md  完整设计文档(16 节)
        ├── plans/2026-05-19-ai-auto-harness-implementation.md  实施 plan(46 task)
        └── phase2-test-setup.md        Phase 2 e2e 验证 setup memo
```

---

## 快速开始(完整 walkthrough)

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
# 走 launch_worker.sh 套底姿势(env-level cache 隔离 + IS_SANDBOX + 跳权限提示)
cd /root/ai-auto-harness
bash cron/launch_worker.sh "/auto-status" "/tmp/status-$(date +%s)"
cat /tmp/status-*/harness.stdout.ndjson | grep -oE '"text":"[^"]*"' | head -20
```

或更短的直跑(只能用于不需要 hooks/skills 的简单查询):

```bash
IS_SANDBOX=1 ./bin/claude-haha \
    -p "/auto-status" \
    --dangerously-skip-permissions \
    --settings .claude/settings.json
```

**注**:历史上 README 用 `--bare`,但 `--bare` 会跳 hooks/skills 导致 `/auto-status` slash command 不被识别。现在统一用 `IS_SANDBOX=1 + --dangerously-skip-permissions + --output-format stream-json --verbose`(详见 `cron/daily.sh` / `cron/launch_worker.sh`)。

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
cd /root/ai-auto-harness
LOG_DIR="runs/songgen-$(date +%Y%m%d-%H%M%S)"
# 第 3 参数 slug = song-generation,让 PostToolUse hook 做 R1 workspace 隔离检测
bash cron/launch_worker.sh \
    "请使用 auto-deploy skill 部署 https://github.com/tencent-ailab/SongGeneration (slug=song-generation)" \
    "$LOG_DIR" \
    song-generation

# 跟进:
tail -f "$LOG_DIR/harness.stdout.ndjson" | grep -oE '"text":"[^"]*"'
# 或 grep 阶段事件
grep -E "^=== PHASE_" "$LOG_DIR/harness.stdout.ndjson"
```

详细 e2e 指导见 [docs/songgen-e2e-test-guide.md](docs/songgen-e2e-test-guide.md)(含 preflight 6 步、recovery 协议、anti-cheating 校验)。

完整 flow(预计 30-60 分钟):

```
1. analyze_project 跑一次 ad-hoc Analyst → 拿 finding(4B / 15GB / 非 gated / scenario_005)
2. 30B 阈值 OK → 进 5 阶段流水线
3. intake: git clone + 读 README + preflight → GPU 拿到 GPU 3 + 4
4. fetch-weights: `hf download lglg666/SongGeneration-{Runtime,v2-large}` 28GB(后台 background,hf_transfer 加速)
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
bash scripts/healthcheck-daemon.sh
crontab -e
# 加这一行(注意 scan@9:00 跑完才能跑 deploy@10:30):
30 10 * * * /root/ai-auto-harness/cron/daily.sh
bash scripts/healthcheck-daemon.sh --strict
```

环境前提:本平台需要 cron/crond 或 supervisord 这类等效 daemon 托管 `cron/daily.sh`。如果 `healthcheck-daemon.sh` 提示没有 cron/supervisord,需要人手执行运维动作(例如安装并启动 cron);agent 不应在未获批准时 `apt install` 或改系统服务。

### Step 5(出问题时):看 pending_human/

```bash
ls pending_human/
cat pending_human/<slug>.md   # 看 agent 为啥 raise + 建议你做啥
# 按指引处理(配 HF_TOKEN / 等 GPU / 等)
rm pending_human/<slug>.md    # 删了文件,下次 cron 自动重试
```

---

## 关键设计决策(为什么这么选)

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
| CC 启动模式 | `IS_SANDBOX=1` + `--dangerously-skip-permissions` + `--output-format stream-json --verbose` | `--bare` | `--bare` 会跳 hooks/skills,导致 slash command 不被识别;`IS_SANDBOX` 只绕 root 检测保留 skill/hook |
| 失败处理 | 写 markdown 给人 | 静默重试或邮件告警 | 中文 markdown 是最低运维成本的接口 |

---

## 运维 / 常见操作

### 日常

```bash
bash cron/launch_worker.sh "/auto-status" "/tmp/status-$(date +%s)"
# → 看现状

cat reports/$(date +%Y-%m-%d).md
# → 看今日报告

ls pending_human/
# → 看积压
```

### 手动 trigger

```bash
# 跑常规流程(挑新项目 OR 接续 in_progress) — 走 cron/daily.sh 同款姿势
bash cron/daily.sh

# 强制接续 / 手动单项目 — 走 launch_worker.sh
bash cron/launch_worker.sh "/auto-recover" "runs/recover-$(date +%s)"
# 部署带 slug(开启 R1 workspace 隔离检测)
bash cron/launch_worker.sh "/auto-deploy https://github.com/x/y" "runs/deploy-$(date +%s)" "y"
```

### 故障排查

| 症状 | 看哪 | 怎么修 |
|---|---|---|
| cron 没产 reports | `runs/cron-<ts>/cron.{out,err,status}` | 看 stderr 有啥 |
| 项目卡在 fetch | `workspace/<slug>/progress.md` + `.cache/<repo>.pid` | `kill -0 <pid>` 看 bg 还活着不;`ls workspace/<slug>/.cache/hf_models/<repo>` 看下到多少 |
| run-and-repair 死循环 | `runs/<run-id>/decisions.md` | 应该 3 轮就停;若没停查 skill prompt |
| LLM 反复违反 R 规则 | `grep "VIOLATION" runs/<run-id>/transcript.jsonl` | 看 PostToolUse hook 注的告警是否真触发了下一 turn 修正 |
| 僵尸 [bun] <defunct> 累积 | `ps -ef \| grep bun \| grep defunct` | 下次跑 launch_worker.sh / daily.sh 会自动扫 worker.pid 清理 |
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
| 1 | `setsid nohup` background 跨 CC 进程退出能否真持久(SongGen run1 验证过部分,需 28GB 完整跑通) | **跑通后即可结案** |
| 2 | `-p` 单次 session 撑得过 1h+ long-running 吗(若不行需走 paused_in_progress + 下次 cron 接续) | **SongGen run2 试跑中** |
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

*基于 Claude Code 源码 + 自定义 16 skill + 5 SubAgent · `IS_SANDBOX=1 + --dangerously-skip-permissions + --output-format stream-json --verbose` · MCP 协议*
