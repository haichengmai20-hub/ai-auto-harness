# AI Auto Harness — 设计文档

**日期**:2026-05-19
**作者**:Claude(brainstorming 协作)+ haichengmai20@gmail.com
**状态**:设计稿,待 review
**目标读者**:平台实施者(下一阶段 writing-plans 的输入)

---

## 1. Overview

`ai-auto-harness` 是一个 cron-driven 的 AI 项目信号发现与自动部署验证平台。其核心是**基于 Claude Code 源码(claudecode_sourcecode1 修复版)的 agent loop**,把"发现 AI 项目 → 自动 GitHub clone → 自动 HF 权重拉取 → 自动装环境 → 自动跑 → 自动验证 → 不能 self-host 时产 API 骨架 → 写公司视角建议"这一长链路做成一个可观测、可接续的 daemon。

平台**复用 Claude Code 成熟的 agent loop / 工具系统 / Skill / MCP / 记忆 / 上下文压缩**,而不是从零造。Python 端的 `ai-daily-scan`(扫描+评分流水线,已经做扎实)保留并接入 MCP;`auto-deploy-agent`(部署/runner/verify 三段)的 Python 工程被**完全替代**,其 `repair_loop` 5 轮观察→决策→执行→验收的角色被 CC agent loop 天然承担。

---

## 2. Goals & Non-goals

### Goals(MVP)

1. **每天 10:30 自动跑**(等 9:00 的 ai-daily-scan 流水线完成),全自主、无人值守
2. **每次 cron 跑只处理 1 个项目**(避免上下文污染;后续要部署更多 = 多次 cron run 串行)
3. **项目内部按 5 阶段切分 SubAgent**:intake / fetch-weights / install-env / run-and-repair / verify
4. **覆盖 7 个功能能力**:扫描信号 / 公司视角建议 / 探索新赛道 / 自动 GitHub clone / 自动 HF 权重 / 自动部署运行验证 / 失败时产 API 骨架与运行指导
5. **所有中间决策可观测**:每次跑落盘 `runs/<run-id>/transcript.jsonl + decisions.md + 各阶段 return json`
6. **跨 cron 周期可接续**:长任务(下载几十 GB 权重)不必一次 cron 跑完,state.json 持久化进度
7. **失败可降级**:repair 3 轮不收敛 → 主动写 `pending_human/<slug>.md`,不硬试
8. **资源 preflight**:GPU 单卡 used ≥25GB 拒动 / 叠加预估后剩余 ≥ 2GB / 磁盘 free ≥ 50GB / 模型 ≤ 30B 参数

### Non-goals

- 持续部署到生产(只是"原型验证"环境,workspace 是临时)
- 多机 GPU 调度(只本机 8×5090)
- 实时通知(邮件/Slack/Issue)— Phase 2 再考虑
- ai-daily-scan 内部 P0/P1/P2 改进(scan 自己的债,平台只做轻量接入改造)
- 重写 ai-daily-scan 的 7 子 agent + Verifier+Corrector 协作机制(保留,投资值钱)

---

## 3. 硬约束

| 维度 | 阈值 / 规则 | 来源 |
|---|---|---|
| 触发时间 | 每天 10:30(scan@9:00 流水线 17-21 分钟) | 用户决定 |
| GPU 单卡占用 | ≥ 25GB(31.8GB total)拒动 | 用户决定(原 Python 阈值 15GB) |
| GPU 叠加预估 | 叠加预估后剩余必须 ≥ 2GB | 用户决定 |
| 磁盘 free | 拉权重前 free ≥ (估算权重总大小 + 50GB safety) | 衍生 |
| 模型规模 | self-host 目标 ≤ 30B 参数 | 用户决定 |
| torch sm 兼容 | wheel 编译档必须含 sm_12.0(5090) | auto-deploy-agent 经验 |
| 并发项目数 | 单次 cron run N=1(MVP) | 用户决定 |
| 修复循环上限 | 同阶段 max 3 轮 LLM 决策后 raise pending_human | 用户决定(防硬试) |

---

## 4. 整体架构

```
┌────────────────────────────────────────────────────────────────────────┐
│                      ai-auto-harness                                   │
│  (fork of claudecode_sourcecode1 — TypeScript/Bun + Claude Code)        │
│                                                                         │
│  cron@10:30                                                             │
│     │                                                                   │
│     ▼                                                                   │
│  cron/daily.sh → claude-haha --print "/auto-daily"                     │
│     │                                                                   │
│     ▼                                                                   │
│  ┌─────────────── 顶层主 Agent ──────────────────────────────────────┐  │
│  │ skill: daily-auto.md                                              │  │
│  │   任务 1: 接续扫 workspace/*/state.json                             │  │
│  │   任务 2: pick 1 项目 (从接续 OR scan findings)                     │  │
│  │   任务 3: dispatch 5 阶段 SubAgent (按 state.phase)                 │  │
│  │   任务 4: 写报告 + MCP record_outcome                                │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                │                                          │
│            ┌───────────────────┼─────────────────────┐                    │
│            ▼                                         ▼                    │
│        SubAgent 1                                 SubAgent 5              │
│      (intake)                                    (verify)                 │
│                                                                           │
│      SubAgent 2: fetch-weights (长任务,background)                       │
│      SubAgent 3: install-env                                              │
│      SubAgent 4: run-and-repair (CC agent loop 自身,max_turns=20)        │
│                                                                           │
│  hooks:                                                                   │
│    SessionStart  → 加载今日 findings、state 扫、GPU/磁盘快照               │
│    PostToolUse   → 追写 runs/<run-id>/transcript.jsonl                    │
│    SessionEnd    → git commit 报告 / 归档老 runs                          │
│                                                                           │
│  落盘:                                                                     │
│    runs/<run-id>/transcript.jsonl    主+子 agent 全部 tool_use/result     │
│    runs/<run-id>/decisions.md        agent 主动写的关键决策                │
│    runs/<run-id>/{intake,fetch,install,run,verify}.json  各阶段 return    │
│    workspace/<slug>/state.json       阶段进度 (跨 cron 接续核心)          │
│    workspace/<slug>/repo/            git clone 的代码                     │
│    workspace/<slug>/venv/            Python venv                          │
│    workspace/<slug>/.cache/          隔离的 HF/transformers cache         │
│    reports/<date>.md                 每日总报告                            │
│    memory/projects/<slug>.md         项目专属经验                          │
│    memory/lessons/*.md               通用经验 (替代 auto-deploy run_memory)│
│    pending_human/<slug>.md           需要人手介入的项目                     │
│    state/blacklist.jsonl             blacklist (LLM agent 自主决策写入)   │
│                                                                           │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ MCP (stdio)
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                   ai-daily-scan (Python,保留)                             │
│                                                                           │
│  mcp_server.py (新)                                                       │
│    工具: scan_today / get_recent_findings / record_outcome / analyze_project │
│                                                                           │
│  src/findings_writer.py (新) → 产 findings.jsonl                          │
│  src/outcomes_reader.py (新) → 读 outcomes.jsonl 供 scan 内部 skip 已 done │
│  state/findings.jsonl (新) ← scan_today 每次 cron 覆写                    │
│  state/outcomes.jsonl (新) ← CC 通过 record_outcome 回填                  │
│  src/ (原 7 子 agent + orchestrator,不动)                                │
│  config/company_profile.jsonl + company_infra.md (不动)                  │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 数据流

**正常流程(单项目从零部署成功)**:

1. `cron@9:00` → ai-daily-scan 原 `run_daily.py` 跑流水线,产 `reports/<ts>_report.md` + `state/findings.jsonl`
2. `cron@10:30` → `cron/daily.sh` → `claude-haha --print "/auto-daily"`
3. 主 agent 启动:
   - `SessionStart` hook 读 `workspace/*/state.json` + scan `findings.jsonl` 摘要
4. 主 agent 任务 1(接续扫):无 in_progress 项目
5. 主 agent 任务 2(pick):MCP `scan_today()` → 拿 findings → 按规则挑 1 个新项目(过滤 30B / blacklist / gated 无 token)
6. 主 agent 写 `workspace/<slug>/state.json`(phase=intake, hf_repos=...)
7. 主 agent dispatch **SubAgent 1 (intake)**:
   - `git clone --depth=1 <github_url>` 到 `workspace/<slug>/repo`
   - 读 README + setup + req 推断 `entry_script`
   - preflight(GPU/磁盘/gated/30B)— 全 OK
   - 返回 `{entry_script, hf_deps[], gpu_picks[], blocked: []}`
8. 主 agent 更新 state.phase=fetching,dispatch **SubAgent 2 (fetch-weights)**:
   - 设置 `HF_HOME=workspace/<slug>/.cache/huggingface`
   - `huggingface-cli download <repo> --local-dir ...` 多个 repo background
   - state.json 落 `bg_shells` + 进度
   - poll BashOutput,直到全部 done
   - 返回 `{weights_done, paused_in_progress: false}`
9. 主 agent 更新 state.phase=installing,dispatch **SubAgent 3 (install-env)**:
   - `python -m venv venv && source ...`
   - `pip install -e .` or `pip install -r requirements.txt`
   - torch sm_12 检测;若 wheel 不支持 → 卸+装 nightly
   - 返回 `{venv_path, deps_ok: true, fixes_applied: [...]}`
10. 主 agent 更新 state.phase=running,dispatch **SubAgent 4 (run-and-repair)**:
    - `source venv/bin/activate && <entry_script>`
    - 失败 → 观察(stderr / nvidia-smi / 文件)→ 决策修复 → 试跑
    - 收敛 → 返回 `RunResult{passed: true, repair_count: N, ...}`
11. 主 agent 更新 state.phase=verifying,dispatch **SubAgent 5 (verify)**:
    - 独立 system prompt:"你不知道之前的修复历史,你只看 workspace 现状"
    - 限工具:只 Bash + Read,不能 Edit/Write
    - 跑 smoke test + GPU 占用检查 + 启动检查
    - 返回 `VerifyState{passed: true, ...}`
12. 主 agent 更新 state.phase=done,任务 4(写报告):
    - `reports/<date>.md` 追加这个项目的 outcome 段(模板见 § 13)
    - MCP `record_outcome(slug, status=passed, ...)`
    - `memory/projects/<slug>.md` 记录可复用经验
13. `SessionEnd` hook git commit + 清理 7 天以上 runs

**失败/接续流程(单项目跨 cron)**:

- cron@10:30 day-1:project X 跑到 fetch-weights 阶段,权重 30GB 下载到 50% 时已 11:30,主 agent 决定收尾(不 kill bg shell — `nohup` 包裹 + 写 state.json `paused_in_progress=true`)
- cron@10:30 day-2:主 agent 任务 1 扫到 `workspace/<X>/state.json` phase=fetching,**跳过任务 2 不 pick 新项目**,直接 dispatch SubAgent 2 接续(`huggingface-cli download` 天然 resume)
- fetch 跑完后正常推进到 install 等

**失败转骨架流程**:

- intake 阶段 SubAgent 1 发现 `estimated_params_b=320`(DeepSeek-V4-Flash)→ blocked.append("model_too_large")
- 主 agent 看到 blocked → 不进 fetch 阶段,改 dispatch **api-skeleton skill**
- 生成 `workspace/<slug>/api_skeleton/{client.py,smoke_test.py,.env.example,使用指导.md}`
- 报告里标"API 路线,见骨架路径"

**人介入流程**:

- fetch 阶段 SubAgent 2 发现 gated repo 无 token + `huggingface-cli` 试探 401
- SubAgent 2 调 `request-human-intervention skill` → Write `pending_human/<slug>.md`
- state.phase = `paused_for_human`
- 主 agent 写报告时标 `## 待人手处理` 段引用这个文件
- 下一次 cron 主 agent 任务 1 扫 pending_human → 在报告里继续显示提醒(不重跑)
- 人手处理完后**手动删除 `pending_human/<slug>.md`** → 下次 cron 才会重新尝试

---

## 6. 仓库结构

**Git 模型**:`git clone /root/claudecode_sourcecode1` fork 含历史 → `git remote rename origin upstream` → `git remote add origin http://192.168.1.227/maihaicheng/ai-auto-harness.git`。后续 CC 升级靠 `git pull upstream main`;自己的 commits 全部用 `ai-auto: ...` 前缀(`git log --grep=ai-auto` 查自己的 work)。

```
/root/ai-auto-harness/
├── README.md                            说明 + 启动指令
├── .claude/
│   ├── settings.json                    权限 + MCP + hooks 配置
│   ├── CLAUDE.md                        给 agent 看的项目根上下文(硬约束、规则)
│   ├── skills/ai-auto/
│   │   ├── daily-auto.md               主 agent 顶层工作流
│   │   ├── intake.md                    SubAgent 1
│   │   ├── fetch-weights.md             SubAgent 2
│   │   ├── install-env.md               SubAgent 3
│   │   ├── run-and-repair.md            SubAgent 4
│   │   ├── verify.md                    SubAgent 5
│   │   ├── api-skeleton.md              失败转骨架(子能力)
│   │   ├── request-human-intervention.md 写 pending_human(子能力)
│   │   ├── preflight-gpu-disk.md        资源检查(intake/install 子调)
│   │   ├── write-recommendation.md      主 agent 写报告
│   │   ├── verifier-corrector.md        借鉴 ai-daily-scan
│   │   ├── coverage-gaps.md             借鉴 ai-daily-scan
│   │   └── cost-analysis.md             借鉴 ai-daily-scan
│   ├── commands/
│   │   ├── auto-daily.md               /auto-daily — cron 入口
│   │   ├── auto-deploy.md              /auto-deploy <github_url> — 手动单项目
│   │   ├── auto-status.md              /auto-status — 看积压/接续
│   │   └── auto-recover.md             /auto-recover — 强制接续(忽略 scan)
│   ├── agents/
│   │   ├── intake-agent.md              SubAgent 1 角色定义(限工具集)
│   │   ├── fetch-agent.md
│   │   ├── install-agent.md
│   │   ├── runner-agent.md
│   │   └── verify-agent.md              SubAgent 5(只读工具集)
│   └── hooks/
│       ├── session-start.sh             加载今日 findings + state 扫
│       ├── post-tool-use.sh             append transcript.jsonl
│       └── session-end.sh               git commit / 清理老 runs
├── cron/
│   ├── daily.sh                         crontab 入口(10:30 触发)
│   └── crontab.example                  user 安装时参考
├── workspace/                           每项目工作目录
│   └── <slug>/
│       ├── state.json                   阶段进度(§ 9)
│       ├── repo/                        git clone 的代码
│       ├── venv/                        Python venv
│       ├── .cache/                      隔离的 HF/transformers cache
│       ├── api_skeleton/                api-skeleton 产物(若走 API 路线)
│       └── progress.md                  当前阶段进度摘要(SubAgent 写)
├── runs/                                每次 cron 跑的 trace
│   └── <YYYY-MM-DD-HHMM>-<slug>/
│       ├── transcript.jsonl             主+子 agent 全部 tool_use/result(JSONL)
│       ├── decisions.md                 agent 主动写的关键决策
│       ├── intake.json                  SubAgent 1 返回
│       ├── fetch.json                   SubAgent 2 返回
│       ├── install.json                 SubAgent 3 返回
│       ├── run.json                     SubAgent 4 RunResult
│       └── verify.json                  SubAgent 5 VerifyState
├── reports/<YYYY-MM-DD>.md              每日总报告(一天可累积多项目)
├── memory/
│   ├── projects/<slug>.md               项目专属经验(复部署看)
│   └── lessons/                         通用经验(替代 auto-deploy run_memory)
│       ├── torch-sm12.md                sm_12 修复经验
│       ├── flash-attn-build.md          flash-attn 编译问题
│       ├── hf-gated.md                  gated repo 处理
│       └── ...                          (agent 自己积累)
├── pending_human/                       人介入通道(§ 11)
│   ├── <slug>.md                        每个待处理项目一个文件
│   └── _resources.md                    资源 alert(GPU/磁盘)
└── state/                               平台级 state
    ├── blacklist.jsonl                  blacklist 记录(slug, reason, ts, until)
    └── deployment_history.jsonl         deploy 历史索引(快速查询)
```

### 6.1 ai-daily-scan 改造

```
/root/ai-daily-scan/                    (原 git repo,改动局部)
├── mcp_server.py                       [新增]
├── pyproject.toml                      [改] 加 mcp-sdk 依赖
├── src/
│   ├── findings_writer.py              [新增] 产 state/findings.jsonl
│   ├── outcomes_reader.py              [新增] 读 state/outcomes.jsonl
│   ├── run_daily.py                    [小改] 末尾调 findings_writer.write
│   ├── tools.py                        [小改] analyst deep prompt 加 4 字段
│   ├── schemas.py                      [小改] AnalystReport schema 加 4 字段
│   └── ... (其他 5 文件不动)
├── state/
│   ├── seen_projects.jsonl             [原]
│   ├── findings.jsonl                  [新] scan_today 每次覆写
│   └── outcomes.jsonl                  [新] CC 回填,append-only
└── config/                             [不动]
```

总改动量约 200-300 行(MCP server ~80 行 + findings_writer ~60 行 + schema 更新 ~40 行 + outcomes reader ~30 行)。

---

## 7. MCP 协议 + Finding Schema

### 7.1 MCP Tools

```python
@mcp.tool()
def scan_today(force: bool = False) -> dict:
    """
    检查今日 9:00 scan 是否已跑过.
    若已跑过且 not force,直接返回 state/findings.jsonl 路径
    若没跑过,触发 src.run_daily.main() (耗时 17-21 分钟)
    Returns: {report_path, findings_jsonl_path, project_count, scan_ts}
    """

@mcp.tool()
def get_recent_findings(days: int = 7) -> list[dict]:
    """
    返回最近 N 天 scan 的所有 findings.
    用于:CC 主 agent 看历史信号、tie-break 时参考过往推荐.
    """

@mcp.tool()
def record_outcome(slug: str, status: str, error_class: str = None,
                    notes: str = None, run_id: str = None) -> dict:
    """
    CC 把 deploy/verify 结果回填给 scan.
    status: passed | failed | paused_for_human | skipped_too_large | api_route
    Append 一条到 state/outcomes.jsonl,下次 scan 会读取并影响 next_action 推荐.
    Returns: {ok: True, appended_to}
    """

@mcp.tool()
def analyze_project(url: str) -> dict:
    """
    手动 deploy 时(/auto-deploy <url>)用,临时跑一次 Analyst.
    Returns: AnalystReport(同 scan 内部产出)
    """
```

### 7.2 Finding Schema(scan 写入 findings.jsonl 的一行)

```json
{
  "slug": "flux-schnell",
  "title": "Flux Schnell — 文本生图模型",
  "github_url": "https://github.com/black-forest-labs/flux",
  "hf_repos": ["black-forest-labs/FLUX.1-schnell", "google/t5-v1_1-xxl"],
  "estimated_params_b": 12,
  "estimated_weight_size_gb": 36,
  "gated_repos": ["black-forest-labs/FLUX.1-schnell"],
  "scenario_hits": ["scenario_003"],
  "recommended_route": "self_host_5090",
  "next_action": "try_deploy_self_host",
  "source_urls": ["..."],
  "confidence": "high",
  "scan_ts": "2026-05-19T09:15:00",
  "scan_report_path": "reports/2026-05-19_090001_report.md"
}
```

**新增 4 字段说明**:
- `next_action: try_deploy_self_host | try_api_pilot | monitor_only | skip` — 给 CC 主 agent 直接 signal
- `gated_repos: list[str]` — intake SubAgent 提前知道哪些 repo 是 gated
- `estimated_weight_size_gb: int` — 磁盘 preflight 使用
- `estimated_params_b: int` — 30B 阈值过滤使用

### 7.3 Outcome Schema(CC 回填的一行)

```json
{
  "slug": "flux-schnell",
  "status": "failed",
  "error_class": "gated_repo_no_token",
  "phase_failed_at": "fetching",
  "run_id": "2026-05-19-1030-flux-schnell",
  "notes": "Gated repo 需要人工同意 license + 提供 HF_TOKEN",
  "ts": "2026-05-19T10:42:13",
  "repair_count": 0
}
```

scan 内部下次跑时:
- `outcomes_reader.load_recent()` 读最近 30 天
- 同一 slug `status=failed` 的项目,下次 scan 在 Analyst 阶段读到 → 调整 `next_action`(若 `error_class=gated_repo_no_token` 持续 → 改 `monitor_only`)
- 同一 slug `status=passed` 的项目 → `next_action=monitor_only`(已成功,不重复跑)

---

## 8. 12 个 Skill 详细设计

### Skill 1: `daily-auto.md`(主 agent 顶层)

**Frontmatter**:
```yaml
name: daily-auto
description: AI Auto 顶层工作流 — 接续 / pick / dispatch 5 阶段 SubAgent / 写报告
allowed-tools: [Read, Write, Bash, Task, mcp__ai_daily_scan__*]
```

**Prompt 骨架**:
```
你是 AI Auto 平台的主 agent。每天 10:30 由 cron 启动你,你的任务是:

# 任务清单(顺序执行)

## 任务 1: 接续与积压检查
1. 扫 workspace/*/state.json,列出 state.phase ∉ {done, paused_for_human} 的项目
2. 扫 pending_human/*.md,列出仍存在的文件(不重跑,但报告里要标)

## 任务 2: 项目选择
- 若任务 1 有 in_progress 项目 → 选最早 started_at 的一个
- 否则 → 调 mcp__ai_daily_scan__scan_today() 拿到 findings.jsonl 路径,读它
- 按以下规则过滤 + 排序:
  filter:
    - estimated_params_b ≤ 30(否则改 api_pilot,见末尾)
    - 不在 state/blacklist.jsonl (未过期)
    - 不在 pending_human/
    - gated_repos 为空 OR $HF_TOKEN 已配置
    - 不在 outcomes.jsonl 里 status=passed 且 30 天内 (避免重复)
  rank:
    - confidence=high 优先
    - 然后 len(scenario_hits) 多的优先
    - tie-break: scan_ts 最新的优先

## 任务 3: 部署流水线
- 读项目 state.json 决定当前 phase
- 按 phase 顺序 dispatch SubAgent:
  - phase=null → SubAgent 1 (intake) → state.phase=fetching
  - phase=fetching → SubAgent 2 (fetch-weights) → state.phase=installing
  - phase=installing → SubAgent 3 (install-env) → state.phase=running
  - phase=running → SubAgent 4 (run-and-repair) → state.phase=verifying
  - phase=verifying → SubAgent 5 (verify) → state.phase=done
- 任一 SubAgent 返回 blocked=true 或 paused_for_human → 跳到任务 4

## 特例:模型 > 30B 或不能 self-host
- 任务 2 过滤时 estimated_params_b > 30 的项目改走 api_pilot 路线
- 跳过 intake → 直接 dispatch api-skeleton skill
- 产出 workspace/<slug>/api_skeleton/{client.py,smoke_test.py,使用指导.md}
- state.phase=done(api_route),outcomes 标 status=api_route

## 任务 4: 写报告 + 回填
- 调 write-recommendation skill 写 reports/<date>.md
- 调 mcp__ai_daily_scan__record_outcome(slug, status, ...)

# 硬约束(贯穿全任务)
- N=1 单项目串行,不并行 dispatch SubAgent
- 任一阶段 SubAgent 返回 paused_for_human → 立刻跳到任务 4
- 接续模式下不挑新项目
- 你不亲自跑 git/pip/python — 那些是 SubAgent 的事
```

### Skill 2: `intake.md`(SubAgent 1)

**Frontmatter**:
```yaml
name: intake
description: 项目部署第一阶段 — clone + 读 README + preflight(GPU/磁盘/gated/30B)
allowed-tools: [Read, Write, Bash, Grep]
agent: intake-agent
```

**Prompt 骨架**:
```
你是 intake SubAgent,负责单项目部署的第一阶段。

# 输入(主 agent 传入)
{slug, github_url, hf_repos, estimated_weight_size_gb, gated_repos, scenario_hits}

# 工作流(必须按顺序)

## 1. workspace 初始化
   mkdir -p workspace/<slug>/{.cache/huggingface,.cache/hf_hub,.cache/transformers,repo,venv}

## 2. 克隆
   git clone --depth=1 <github_url> workspace/<slug>/repo
   - 失败 → return {blocked: ["git_clone_failed", error_msg]}

## 3. 读项目核心文件
   - README.md (找 Quickstart / Inference / Demo 章节)
   - setup.py / pyproject.toml / requirements*.txt
   - 任何 *example*.py / inference*.py / demo*.py
   - configs/*.yaml(若有)

## 4. 推断 entry_script
   - 优先级:
     a) README quickstart 章节给的命令
     b) setup.py 的 console_scripts
     c) inference.py / demo.py / app.py
     d) 找不到 → return {blocked: ["entry_script_unknown"]}
   - 验证:venv 内 dry-run `<cmd> --help` 看 CLI 是否真存在

## 5. 校准 hf_deps
   - 读项目代码搜 `from_pretrained\(['"](.*?)['"]`
   - 与主 agent 传入的 hf_repos 比对,补全或修正

## 6. Preflight(调 preflight-gpu-disk skill)
   - GPU:nvidia-smi → 找 used < 25GB 且 free > 估算单卡需求 + 2GB 的卡;记录 gpu_picks
   - 磁盘:df -h /root → free > estimated_weight_size_gb + 50GB safety
   - Gated:对 hf_deps 每个 repo curl https://huggingface.co/api/models/<repo> 看 .gated 字段
     - gated=true 且 $HF_TOKEN 缺失 → blocked.append("gated_no_token")
     - gated=true 且 $HF_TOKEN 存在 → 试 `huggingface-cli download <repo> README.md --quiet`,401 → blocked
   - Size:estimated_params_b > 30 → blocked.append("model_too_large")
     (主 agent 应该已过滤,这里 double check)

## 7. 写 state.json
   {phase: "fetching", intake_result: {...}}

## 返回 schema
{
  entry_script: str,
  hf_deps: list[str],
  gpu_picks: list[int],          # 推荐使用的 GPU index
  blocked: list[str],            # 空 list 表示 OK
  ready_to_fetch: bool
}

# 失败处理
- blocked 非空 → 调 request-human-intervention skill 写 pending_human/<slug>.md
- 不要自己重试,留给主 agent 决策
```

### Skill 3: `fetch-weights.md`(SubAgent 2)

**Frontmatter**:
```yaml
name: fetch-weights
description: 拉 HF 权重 — background bash + BashOutput poll + 跨 cron 接续
allowed-tools: [Read, Write, Bash, BashOutput, KillBash]
agent: fetch-agent
```

**Prompt 骨架**:
```
你是 fetch-weights SubAgent。

# 输入
{slug, hf_deps, gated_repos, workspace_path}

# 硬约束(必须遵守的环境变量,任何 bash 都必须先 export)
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export TRANSFORMERS_CACHE="$WORKSPACE/.cache/transformers"
# 这三个必须设,否则会污染全局 HF cache(影响其他项目)

# 工作流

## 1. 读 state.json,检查是否接续
   若 fetch_state.weights_done 非空 → 跳过已下载的
   若 fetch_state.bg_shells 非空 → 用 BashOutput(shell_id) 看是否还活着

## 2. 启动下载
   对每个未完成的 repo:
     nohup huggingface-cli download \
       <repo> \
       --local-dir $WORKSPACE/.cache/hf_models/<repo> \
       --resume-download > $WORKSPACE/progress_<repo>.log 2>&1 &
   - 用 Bash(run_in_background=true)
   - 拿到 shell_id 写入 state.fetch_state.bg_shells

## 3. Poll 循环(每 60-180s)
   - BashOutput(shell_id) 看新输出
   - 解析进度(huggingface-cli 输出含 "MB" 等关键字)
   - 写 workspace/<slug>/progress.md 摘要(给人看)
   - 检查磁盘:df -h,若 free < 30GB → kill + 报告(disk_low)
   - 检查 .incomplete 文件大小是否在增长(30min 无增长 = 卡了)

## 4. 卡死判定
   - shell 仍 alive 但 30min stderr/stdout 无新输出 + 文件大小 30min 无增长
   → kill,重启(用同一 --resume-download)
   - 重启 2 次仍卡 → blocked

## 5. 时间预算判定
   - 假设主 agent 已跑 50 分钟(从 SessionStart hook 算),距 cron 周期结束 < 30 分钟
   - 且当前下载进度 < 80%
   → 不 kill bg shell,但更新 state.json paused_in_progress=true,return
   - 下次 cron 主 agent 会接续这个 SubAgent

## 6. Gated 二次拦截
   若运行时 401(intake 漏检了)→ 立刻 kill + request-human-intervention

## 返回 schema
{
  weights_done: list[str],
  failed: list[{repo, error_class, msg}],
  paused_in_progress: bool,        # true = 跨 cron 接续
  bytes_total: int
}

# 反模式(不要做)
- 不要用 Bash(timeout=...) — 这是给 short bash 用的,长下载用 background
- 不要自己 rm -rf .cache 重来 — 会丢已下载部分
- 不要 wait 一个 bg shell — 用 BashOutput 周期 poll
```

### Skill 4: `install-env.md`(SubAgent 3)

**Frontmatter**:
```yaml
name: install-env
description: venv + pip + torch sm_12 检测 + 常见 build issue 修复
allowed-tools: [Read, Write, Edit, Bash, Grep]
agent: install-agent
```

**Prompt 骨架**:
```
你是 install-env SubAgent。

# 输入
{slug, workspace_path, entry_script, requirements_files}

# 工作流

## 1. 创建 venv
   python -m venv workspace/<slug>/venv
   source workspace/<slug>/venv/bin/activate

## 2. 升级核心工具
   pip install --upgrade pip setuptools wheel

## 3. 装项目依赖
   优先级:
   a) pip install -e workspace/<slug>/repo (有 setup.py / pyproject.toml)
   b) pip install -r workspace/<slug>/repo/requirements.txt
   c) 从 README quickstart 抄 pip install 命令

## 4. torch sm_12 检测(5090 必须做)
   python -c "import torch; print(torch.cuda.get_arch_list())"
   若输出不含 'sm_120' 或 'compute_120':
     - 卸 torch:pip uninstall -y torch torchvision torchaudio
     - 装 nightly 或 cu124 wheel:
       pip install --index-url https://download.pytorch.org/whl/nightly/cu124 \
         torch torchvision torchaudio
     - 再次验证 sm_120 在列表中
   - 三次重装失败 → blocked.append("torch_sm12_unavailable")

## 5. 常见 build issue 修复(读 memory/lessons/*.md 找经验)
   - flash-attn 装不上 → 用 prebuilt wheel(memory/lessons/flash-attn-build.md)
   - bitsandbytes 不兼容 → 版本回退
   - 缺 nvcc → apt install -y cuda-toolkit-12-4 (若权限允许)OR 跳过 GPU compile-only deps

## 6. 验证 entry_script 至少能 import
   python -c "import <main_module>"
   失败 → 看 stderr 是否缺 module → pip install 补

## 7. 写 memory/projects/<slug>.md(若有非常规修复)
   记录 fixes_applied 供下次复部署看

## 返回 schema
{
  venv_path: str,
  deps_ok: bool,
  fixes_applied: list[str],
  warnings: list[str]
}

# 反模式
- 不要 sudo pip install / pip install --user(隔离破坏)
- 不要 conda env(我们用 venv)
- 不要修改全局 ~/.config 或 /etc
```

### Skill 5: `run-and-repair.md`(SubAgent 4 — 核心)

**Frontmatter**:
```yaml
name: run-and-repair
description: 试跑 entry_script 并修复失败 — CC agent loop 替代 Python repair_loop
allowed-tools: [Read, Write, Edit, Bash, BashOutput, Grep]
agent: runner-agent
```

**Prompt 骨架**:
```
你是 run-and-repair SubAgent。你的任务是让项目的 entry_script 真正跑起来。

# 核心机制
这个 skill 替代 auto-deploy-agent/modules/runner/repair_loop.py 的 5 轮循环.
你**就是** repair loop — CC agent loop 的每一轮 ToolUse 就是一轮"观察→决策→执行→验收".

# 输入
{slug, workspace_path, venv_path, entry_script, gpu_picks}

# 工作流

## 0. 设置环境
   source venv/bin/activate
   export CUDA_VISIBLE_DEVICES=<gpu_picks 第一个>
   export HF_HOME=$WORKSPACE/.cache/huggingface  (与 fetch 一致)

## 1. 试跑(每轮先这一步)
   <entry_script> > workspace/<slug>/run.log 2>&1
   - 短任务:同步 bash(timeout=600s)
   - 长任务(模型推理可能慢):background bash + BashOutput poll
   - 进度判定:nvidia-smi 看 GPU 占用是否上升、看 stdout 是否有 token 输出

## 2. 观察(必须每轮做)
   - tail run.log
   - nvidia-smi --query-gpu=memory.used,utilization.gpu
   - ls workspace/<slug>/ 看预期输出文件是否生成
   - exit code(注意 -15 = SIGTERM,-9 = SIGKILL,137 = OOMKill)

## 3. 决策(LLM 判断)
   - 退出码 = 0 且预期文件存在 → 成功,返回 RunResult
   - 退出码 != 0 → 看 stderr root cause
     常见模式:
     - "CUDA out of memory" → 换更小 batch / 用 quantization / 换 GPU
     - "No module named X" → pip install X(回到 install-env 类似操作)
     - "RuntimeError: nan" + 5090 → sm_12 wheel 问题(应该 install 阶段已修)
     - "401" / "Unauthorized" → gated(应该 intake 已 preflight)
     - SIGTERM / SIGKILL → 超时被杀(看是不是在下载而非真跑)/ 内存不足
   - 卡死(stdout/stderr 30min 无变化 + GPU 利用率 0%)→ kill 重启 OR 调环境变量

## 4. 修复
   - 修代码:Edit workspace/<slug>/repo/<file>
   - 修环境:export 新变量 / 重装 lib
   - 修配置:Edit workspace/<slug>/repo/configs/<yaml>

## 5. 验收
   - 重跑 → 回到步骤 1
   - 最多 3 轮决策 → 第 3 轮仍未收敛 → 调 request-human-intervention skill
     不要硬试第 4 轮 — 那是 Python rule-based 时代的坏习惯,LLM 应该会知道何时止损

# 修复时的强制要求
- 任何 Edit 修代码 → 必须先 Read 看原内容,Edit 后 Write 一条 decisions.md 说明改了什么
- 任何环境变量改动 → 写 state.json env_overrides 让其他 SubAgent 看到
- 任何卸装新包 → 写 memory/projects/<slug>.md fixes_applied

# 返回 schema
{
  passed: bool,
  error_class: str | null,    # CUDA_OOM, MODULE_MISSING, INFER_NAN, ...
  repair_count: int,
  stdout_tail: str (last 50 lines),
  gpu_snapshot: {memory_used, utilization, processes},
  fixes_applied: list[str],
  post_conditions_met: dict   # {output_file_exists: bool, valid_format: bool, ...}
}
```

### Skill 6: `verify.md`(SubAgent 5 — 独立判定)

**Frontmatter**:
```yaml
name: verify
description: 独立判定项目是否真能跑 — 不读 run-and-repair 的修复历史
allowed-tools: [Read, Bash]
agent: verify-agent
```

**关键设计**:**只 Read + Bash,无 Edit/Write**。verify 不是来修问题的,只来判定。

**Prompt 骨架**:
```
你是 verify SubAgent。你不知道项目 X 之前发生了什么.
你的任务:像一个"刚拿到这个 workspace 的工程师"一样,验证它能不能跑.

# 输入
{slug, workspace_path, venv_path, entry_script}

# 工作流

## 1. 启动检查(冷启动一次)
   source venv/bin/activate
   <entry_script> --help  (或对应的 quickstart 命令)
   退出码 = 0 → 启动 OK

## 2. 功能检查(smoke test)
   读 workspace/<slug>/repo/README.md 找最小 demo 命令
   跑一次,看输出是否合理
   - 文本模型:看输出是不是连贯文本
   - 图像模型:看输出文件大小是否合理(几百 KB 到几 MB)
   - 视频模型:看 ffmpeg 能否读出帧数
   - 音频模型:看采样率/时长

## 3. GPU 利用率检查
   推理跑时另一个 bash:
   nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv -l 2
   - GPU 占用必须 > 1GB(不然是 CPU fallback)
   - 利用率必须 > 10%(不然没真在跑)

## 4. 判定
   - 三步都通过 → passed=true
   - 任一失败 → passed=false,failed_at=<step>

# 返回 schema
{
  passed: bool,
  failed_at: str | null,   # "startup" / "smoke_test" / "gpu_utilization"
  evidence: dict,          # 关键观察(stdout snippets / gpu stats / output file paths)
  notes: str               # LLM 的简短判断说明
}

# 反模式
- 不要试图修问题 — 那是 SubAgent 4 的事
- 不要怪罪之前的 SubAgent — 你不知道他们做了什么
- 不要假设 entry_script 一定能跑 — 该失败就失败
```

### Skill 7: `api-skeleton.md`(失败转骨架子能力)

**Frontmatter**:
```yaml
name: api-skeleton
description: 不能 self-host 时(模型 > 30B / gated 无 token / 资源不足)产 API 骨架 + 中文指导
allowed-tools: [Read, Write]
```

**Prompt 骨架**:
```
你是 api-skeleton 子能力,主 agent 在以下情况调你:
- estimated_params_b > 30(模型太大)
- intake 返回 blocked=["gated_no_token"](短期无法解决)
- 资源不足且短期改不了

# 输入
{slug, github_url, hf_deps, scan_finding}  # scan_finding 含 cost_estimate

# 产物(写到 workspace/<slug>/api_skeleton/)

## client.py
   - 最小可调用的 HTTP client
   - 用 requests 或 httpx
   - 优先级 API:
     a) 项目官方 API(若 scan_finding 提到)
     b) HuggingFace Inference API
     c) OpenRouter / Together / WaveSpeed 等第三方托管
   - 包含 retry / timeout / error handling

## smoke_test.py
   - 一个最小 demo 调用
   - 比如对文本模型:输入"你好",看输出
   - 对图像模型:用一个测试 prompt 生成一张图

## .env.example
   - 列出需要的环境变量(API_KEY,BASE_URL,...)
   - 注释说明每个去哪获取

## 使用指导.md(中文)
   段落:
   1. 项目简介(从 scan_finding 抄)
   2. 为什么走 API 而非自部署
     - 若 size > 30B:说明 self-host 需要 N 卡才能跑,API 路线月成本 ~$X
     - 若 gated:说明需要先在 huggingface.co 同意 license
   3. 注册 + 拿 API key 的步骤(具体链接)
   4. 配置:cp .env.example .env && 填 key
   5. 跑 smoke test:python smoke_test.py
   6. 双路成本表(借鉴 cost-analysis skill)
   7. 限流 / quota 提示
   8. 上线建议(灰度 / 监控)

# 返回 schema
{
  skeleton_path: str,
  ready: bool,
  api_route_chosen: str  # "official" / "hf_inference" / "openrouter" / ...
}
```

### Skill 8: `request-human-intervention.md`(子能力)

**Frontmatter**:
```yaml
name: request-human-intervention
description: 任何 SubAgent 主动 raise 时调 — 写 pending_human/<slug>.md
allowed-tools: [Read, Write]
```

**Prompt 骨架**:
```
你是 request-human-intervention 子能力。
任何 SubAgent 发现"我搞不定了"时调你.

# 输入
{slug, reason_category, what_tried, what_blocked, next_steps_suggested}
reason_category ∈ {
  "auth_missing",      # 凭证 / token
  "stuck_repair_3x",   # repair_loop 3 轮不收敛
  "resource_shortage", # GPU / 磁盘 短期不够
  "model_too_large",   # > 30B
  "credential_needed", # API key 需要人配
  "unknown_failure"    # LLM 自己说不知道为什么
}

# 工作流
1. Write 到 pending_human/<slug>.md,内容模板:
   ```markdown
   # <slug> — 需要人手介入

   **时间**:<ts>
   **原因类别**:<reason_category>
   **当前阶段**:<state.phase>

   ## 我尝试过什么
   <what_tried 的 bullet list>

   ## 我被卡在哪
   <what_blocked 的具体描述>

   ## 建议人手做的事
   <next_steps_suggested 的 bullet list>

   ## 上下文
   - workspace: workspace/<slug>/
   - trace: runs/<run-id>/
   - state: <state.json 摘要>

   ---
   处理完后**手动删除本文件** → 下次 cron 才会重新尝试
   ```

2. 更新 workspace/<slug>/state.json:
   {phase: "paused_for_human", pending_human: {reason, written_to, ts}}

# 返回
{wrote_to: str, blocked: true}
```

### Skills 9-11: 借鉴 ai-daily-scan 的 3 个

**Skill 9: `verifier-corrector.md`**:主 agent 写完报告后,触发"事实核验"段落 — 在同一会话里换个 system prompt 段独立 verify 报告里的数字/URL,把 ❌ 的回写到正文(模拟 SubAgent,但 CC SubAgent 不支持嵌套,所以用"prompt 段切换"模拟)。

**Skill 10: `coverage-gaps.md`**:主 agent 写报告时调,读 30 天 outcomes.jsonl + scenario_hits 历史,产出"近 7 天哪些业务线 0 次 deploy 成功" alert,放在报告头部。

**Skill 11: `cost-analysis.md`**:api-skeleton skill 内部调,产出标准化双路成本表(API 月度估算 vs self-host 月度估算)。

### Skill 12: `write-recommendation.md`(主 agent 写报告)

**Frontmatter**:
```yaml
name: write-recommendation
description: 主 agent 写每日总报告 + 调 MCP record_outcome
allowed-tools: [Read, Write, Bash, mcp__ai_daily_scan__record_outcome]
```

**Prompt 骨架(报告 template)**:
```
你是 write-recommendation 子能力。

# 输入
{run_results: list[(slug, status, RunResult, VerifyState)],
 pending_human_files: list[path],
 resource_snapshot: {gpu_status, disk_free_gb}}

# 渲染 reports/<YYYY-MM-DD>.md(覆写,因为单天可能多次 cron 重跑)

## Template

# AI Auto 报告 — <date>

> 生成时间:<ts>
> Run IDs:<list>

## 总览
- 今日处理项目:<n_total>
- 成功 self-host:<n_pass> / API 路线:<n_api> / 失败:<n_fail> / 待人手处理:<n_human>
- GPU 状况:<gpu_summary>(8 卡可用 <n>)
- 磁盘 free:<disk_gb> GB <若 < 100 标 ⚠️>

## 今日处理项目详情

### <slug> — <title>
- **路径**:self_host_5090 | api_pilot
- **结果**:✅ PASS / ❌ FAILED / ⏸️ PAUSED_FOR_HUMAN
- **阶段进展**:intake ✅ / fetch ✅ / install ✅ / run ⚠️ / verify ❌
- **公司视角**:命中 <scenario_hits>,推荐试点 <pilot_product>,验收指标 <metrics>
- **修复轨迹**:<RunResult.fixes_applied 摘要>
- **GPU 利用**:<gpu_snapshot 摘要>(若已跑通)
- **报告**:[runs/<run-id>/](runs/<run-id>/)
- (若 FAILED) **失败原因**:<error_class>
- (若 PAUSED) **待人手**:[pending_human/<slug>.md](pending_human/<slug>.md)

## 待人手处理积压(从 pending_human/ 索引)
| Slug | 类别 | 卡了几天 | 文件 |
|---|---|---|---|
| <slug> | <category> | <days> | [link](...) |

## 跨日盲区(coverage-gaps skill 输出)
- 近 7 天 scenario_005 (AI 音乐音频) 0 次成功部署 — 是否值得加权重?

## 下一步建议(LLM 主动写,基于以上)
- ...

## 资源 Alert
- 磁盘 free 459 GB(94% used)— 建议清理:
  - /root/core.* (180GB 可释放)
  - workspace 中 7 天前的项目

---
*生成依赖:claudecode_sourcecode1 + ai-daily-scan MCP*
```

写完后**调 MCP record_outcome** 把每个项目结果回填给 scan。

---

## 9. State.json + 接续机制

### 9.1 State.json Schema

```json
{
  "slug": "flux-schnell",
  "github_url": "https://github.com/black-forest-labs/flux",
  "hf_repos": ["black-forest-labs/FLUX.1-schnell", "google/t5-v1_1-xxl"],
  "estimated_params_b": 12,
  "estimated_weight_size_gb": 36,
  "gated_repos": ["black-forest-labs/FLUX.1-schnell"],
  "scenario_hits": ["scenario_003"],

  "phase": "fetching",
  "phases_done": ["intake"],
  "current_phase_started_at": "2026-05-19T10:32:11",

  "intake_result": {
    "entry_script": "python -m flux t2i --output out.png",
    "hf_deps": [...],
    "gpu_picks": [3, 4],
    "blocked": []
  },

  "fetch_state": {
    "weights_done": ["google/t5-v1_1-xxl"],
    "weights_pending": ["black-forest-labs/FLUX.1-schnell"],
    "bg_shells": [
      {"id": "abc123", "cmd": "nohup huggingface-cli ...",
       "started_at": "2026-05-19T10:35:00",
       "log_path": "workspace/flux-schnell/progress_flux.log"}
    ],
    "last_progress_at": "2026-05-19T10:42:13",
    "bytes_downloaded": 12_345_678_901
  },

  "install_result": null,
  "run_result": null,
  "verify_result": null,

  "pending_human": null,
  "decisions": [
    {"ts": "2026-05-19T10:32", "by": "intake-agent",
     "decision": "skip subdir 'experimental/' (not in mainline)"}
  ],

  "run_id": "2026-05-19-1030-flux-schnell",
  "started_at": "2026-05-19T10:30:00",
  "updated_at": "2026-05-19T10:42:13"
}
```

### 9.2 接续算法(主 agent 任务 1+2 实现)

```python
# 伪代码
in_progress_states = []
for state_file in glob("workspace/*/state.json"):
    s = json.load(state_file)
    if s["phase"] not in ["done", "paused_for_human"]:
        in_progress_states.append(s)

if in_progress_states:
    # 选最早 started_at 的接续
    target = min(in_progress_states, key=lambda s: s["started_at"])
    dispatch_subagent_for_phase(target["phase"], target)
else:
    # pick 新项目
    findings = mcp.scan_today()
    target = filter_and_rank(findings)
    init_state_json(target)
    dispatch_subagent("intake", target)
```

### 9.3 长任务 bg_shell 跨 cron 接续

**问题**:CC 主进程死后,`Bash(run_in_background=true)` 启动的 bash 也跟着死(默认 setpgid)。

**方案**:
- `Bash` 命令显式用 `nohup ... &` + `disown`,或者 `setsid bash -c "..."`
- 启动后立刻把 PID 写到 state.json
- 下次 cron 主 agent 接续时:
  1. 读 state.fetch_state.bg_shells[*].cmd_or_pid
  2. `kill -0 <pid>` 检查是否还活着
  3. 活着 → 用 `tail -f <log_path>` 接上 OR 直接读 log_path
  4. 死了但任务未完 → 用 `huggingface-cli` 的 `--resume-download` 重启

**注意**:CC `Bash(run_in_background=true)` 的 shell_id 是 CC session 内的句柄,**不是 OS PID**。所以 state.json 里要存 `cmd` + 自己用 `pgrep` 找 PID,或者在 bash 里 echo `$$` 落盘。

---

## 10. Flux 8 痛点对照

| # | Flux 痛点 | 本设计在哪解决 |
|---|---|---|
| 1 | 权重下载在 run 阶段,timeout 300s 被杀 | **intake 阶段就列 hf_deps + 估算大小**;**fetch 阶段单独负责下载,不与 run 混合**;run 阶段假设权重已就绪 |
| 2 | HF cache 不隔离 | fetch-weights skill 强制 export `HF_HOME=workspace/<slug>/.cache/huggingface`(§ 8 Skill 3) |
| 3 | entry_script 提取不准 | intake skill 让 LLM 自由读 README quickstart + 试 `--help`,不靠规则匹配(§ 8 Skill 2) |
| 4 | 长下载无进度 | fetch-weights skill `BashOutput` 周期 poll,写 `progress.md`(§ 8 Skill 3) |
| 5 | **HF Gated Repo 认证** | intake skill `curl huggingface.co/api/models/<repo>` 探 .gated + 试探 401;**预 preflight** 避免下载阶段才发现(§ 8 Skill 2 step 6) |
| 6 | timeout 太短 | **不用 timeout 兜底**:长任务全 background + BashOutput poll + 卡死判定(stderr 30min 无新 + 文件大小 30min 无增长)(§ 8 Skill 3 step 3/4) |
| 7 | exit_code=-15 误判为 crash | LLM 看 exit code 直接懂 SIGTERM/SIGKILL/OOMKill,不用 RuleRunDecider(§ 8 Skill 5 step 3) |
| 8 | RuleRunDecider 对超时无修复方案 | LLM 看现场判断:`.incomplete` 文件存在 + 网络 OK = 还在下;stderr 在 import torch + GPU 在用 = 真在跑;全静默 30min = 死了(§ 8 Skill 5 step 3) |

---

## 11. Human-in-the-loop 通道

### 5 类触发 + 报告呈现

| 触发条件 | 写入 | 报告呈现 |
|---|---|---|
| HF gated repo 缺 token | `pending_human/<slug>.md`(含 license URL + 需要的环境变量) | "## 待人手处理 — 鉴权类" |
| 同一项目连续 3 次失败,agent 主动 raise | `pending_human/<slug>.md`(含失败轨迹) | "## 待人手处理 — 卡死类" |
| GPU/磁盘短期不可恢复 | `pending_human/_resources.md` | 报告头 ALERT |
| 模型 > 30B 但有价值 | `pending_human/<slug>.md`(标 "建议 API 路线评估") | "## 待人手处理 — 决策类" |
| API 骨架完毕但缺 API key | `pending_human/<slug>.md` | "## 待人手处理 — 凭证类" |

### 解除条件:**人手动删除 `pending_human/<slug>.md`**

- 下次 cron 主 agent 不再扫到这个文件 → 项目重新进入候选
- state.json `phase=paused_for_human` 不会自动清,但下次主 agent 看到 pending_human 消失 + state phase=paused_for_human → 主 agent 重置 state.phase 回到 paused 之前的阶段重试

---

## 12. Hooks / Commands / Settings

### 12.1 Hooks

**`session-start.sh`**:
```bash
#!/bin/bash
# 生成本次 run-id 并落盘(post-tool-use 会读)
RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"
mkdir -p runs/$RUN_ID
echo $RUN_ID > runs/.current_run_id

# 加载今日 findings 摘要 + state 扫 + 资源快照到 system prompt addendum
echo "## Today's context (loaded by SessionStart hook)"
echo "Run ID: $RUN_ID"
echo "### Findings (latest scan)"
jq -c '.[0:5]' /root/ai-daily-scan/state/findings.jsonl  # top 5 candidates
echo "### In-progress projects"
find workspace -name state.json -exec jq -c '{slug, phase, updated_at}' {} \;
echo "### Pending human"
ls pending_human/ 2>/dev/null | grep -v _resources.md
echo "### Resources"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv | head -10
df -h /root | tail -1
```

**`post-tool-use.sh`**:
```bash
#!/bin/bash
# CC 调用工具后追写 transcript.jsonl
RUN_ID=$(cat runs/.current_run_id 2>/dev/null || echo "unknown")
echo "{\"ts\":\"$(date -Iseconds)\",\"tool\":\"$TOOL_NAME\",\"input\":$TOOL_INPUT,\"result\":$TOOL_RESULT}" \
  >> runs/$RUN_ID/transcript.jsonl
```

**`session-end.sh`**:
```bash
#!/bin/bash
# git commit 今日报告(若有变化)+ 清理 7 天以上 runs
cd /root/ai-auto-harness
git add reports/ memory/ state/ pending_human/
git commit -m "AI Auto run $(date +%Y-%m-%d-%H%M)" || true  # 没变化不报错
find runs/ -maxdepth 1 -mtime +7 -exec rm -rf {} \;
```

### 12.2 Commands

- **`/auto-daily`** — cron 入口,触发主 agent skill `daily-auto`
- **`/auto-deploy <github_url>`** — 手动跑单项目(跳过 scan pick,直接进 intake)
- **`/auto-status`** — 输出 workspace + pending_human + recent reports 索引,不跑任何 agent
- **`/auto-recover`** — 强制扫接续(忽略 scan,跳过任务 2),用于"今天不要新 pick,只把昨天没跑完的跑完"

### 12.3 settings.json

```json
{
  "permissions": {
    "allow": [
      "Bash(git clone *)",
      "Bash(git pull *)",
      "Bash(huggingface-cli *)",
      "Bash(pip *)",
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(nvidia-smi*)",
      "Bash(df *)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(tail *)",
      "Bash(head *)",
      "Bash(grep *)",
      "Bash(find *)",
      "Bash(mkdir *)",
      "Bash(rm -rf workspace/*)",
      "Bash(curl -s https://huggingface.co/api/*)",
      "Bash(nohup *)",
      "Bash(kill *)",
      "Bash(pgrep *)",
      "Bash(source *)",
      "Read(*)",
      "Write(workspace/**)",
      "Write(runs/**)",
      "Write(reports/**)",
      "Write(memory/**)",
      "Write(pending_human/**)",
      "Write(state/**)",
      "Edit(workspace/**)",
      "Grep(*)",
      "Task(*)",
      "mcp__ai_daily_scan__*"
    ],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~/*)",
      "Bash(sudo *)",
      "Write(/etc/**)",
      "Write(/root/.ssh/**)"
    ]
  },
  "mcpServers": {
    "ai_daily_scan": {
      "command": "python",
      "args": ["/root/ai-daily-scan/mcp_server.py"],
      "env": {
        "PYTHONPATH": "/root/ai-daily-scan"
      }
    }
  },
  "hooks": {
    "SessionStart": "/root/ai-auto-harness/.claude/hooks/session-start.sh",
    "PostToolUse": "/root/ai-auto-harness/.claude/hooks/post-tool-use.sh",
    "SessionEnd": "/root/ai-auto-harness/.claude/hooks/session-end.sh"
  },
  "env": {
    "ANTHROPIC_BASE_URL": "...",
    "ANTHROPIC_API_KEY": "..."
  }
}
```

---

## 13. 测试策略

### L1 单元测试(每个 skill)

每个 SubAgent skill 独立测,给 mock workspace + mock 输入,断言:
- 返回 schema 符合定义
- 文件写入位置正确
- 失败时调 request-human-intervention(不硬试)

工具:Python `pytest` 写测试驱动,跑 `claude-haha --print "/<skill-test>"` 拿输出 JSON,断言。

### L2 集成测试(端到端 1 项目)

候选项目:**SongGeneration**(scan 2026-05-12 报告里已推荐)
- 已知:开源、3B/4B 参数(在 30B 阈值内)、非 gated、5090 单卡可跑
- 验证:5 阶段全过、verify 通过、报告生成、record_outcome 调用
- 验证接续:故意在 fetch 阶段 sleep 后 kill CC 主进程,重新 `/auto-daily`,看 fetch 接续

### L3 Chaos 测试

构造异常场景验证 agent 是否触发 pending_human:
- 磁盘满:`dd if=/dev/zero of=/root/fake_full bs=1M count=500000` 把 free 降到 < 20GB → 期望 intake blocked
- GPU 占满:跑一个 dummy load 占 30GB → 期望 intake gpu_picks 为空 → blocked
- gated 无 token:unset HF_TOKEN + 拉 FLUX → 期望 fetch 阶段 paused_for_human
- sm_12 不兼容:故意装 cu118 torch → 期望 install 阶段修复 OR blocked
- repair 不收敛:故意改 entry_script 让它必然 NaN → 期望 run-and-repair 3 轮后 raise

---

## 14. 迁移路径

### Phase 0(前置)— ai-daily-scan 接入

- 加 `mcp_server.py` + `findings_writer.py` + `outcomes_reader.py`
- AnalystReport schema 加 4 字段 (next_action / gated_repos / estimated_params_b / estimated_weight_size_gb)
- 验收:scan@9:00 跑完产 findings.jsonl,CC 端能 MCP 读取
- **不动 7 子 agent 内部**

### Phase 1 — harness 骨架 + 主 agent

- 在公司 Gitea web 界面新建空 repo `maihaicheng/ai-auto-harness`
- 本地:`git clone /root/claudecode_sourcecode1 /root/ai-auto-harness`(保留 CC 历史)
- `git remote rename origin upstream` + `git remote add origin http://192.168.1.227/maihaicheng/ai-auto-harness.git`
- 加平台 `.gitignore`(workspace/ runs/ memory/ pending_human/ state/ reports/)
- 后续 CC 升级:`git pull upstream main`(merge);自己 commits 用 `ai-auto:` 前缀
- 写 `.claude/skills/ai-auto/daily-auto.md` + `intake.md`(只到克隆 + 读 README)
- 写 `.claude/commands/auto-daily.md` + 3 个 hook 脚本(session-start / post-tool-use / session-end)
- 写 cron/daily.sh + crontab 安装文档
- 验收:`/auto-daily` 能跑通 "scan → pick → SubAgent 1 git clone" 流程

### Phase 2 — fetch + install + run

- 写 `fetch-weights.md` + `install-env.md` + `run-and-repair.md` skill
- 写 state.json 接续机制 + bg_shell 持久化
- 验收:用 SongGeneration 端到端跑通 self-host 部署(run-and-repair 至少 1 轮)

### Phase 3 — verify + api-skeleton + human + 报告

- 写 `verify.md` + `api-skeleton.md` + `request-human-intervention.md` + `write-recommendation.md`
- 验收:**MVP 完成**,L2 集成测试通过

### Phase 4 — 借鉴 skill + memory

- 写 `verifier-corrector.md` / `coverage-gaps.md` / `cost-analysis.md` 三个借鉴 skill
- 让 agent 写 `memory/lessons/*.md` 通用经验
- L3 Chaos 测试

### Phase 5(未来)

- pending_human 邮件 / Slack 通知
- 并发度 N=2/3(SubAgent 之间 GPU 抢占)
- verify 用真正的子进程(`claude-haha --print --session-id=...`)实现彻底独立

---

## 15. 已知风险与开放问题

| # | 风险 | 缓解 | 是否 blocker |
|---|---|---|---|
| R1 | CC SubAgent 单层嵌套限制 — verify 想真正独立判定 | 初版用"同 SubAgent 内换 system prompt + 限工具集"模拟;Phase 5 升级子进程 | 否 |
| R2 | `Bash(run_in_background=true)` 跨 cron 周期是否真正持久 | 必须实验:用 `nohup ... &` + `disown` + 写 PID 到 state.json,实测 CC 主进程死后 bash 是否存活 | **是 — 实施前必须验证** |
| R3 | `claude-haha --print` 是否支持几十分钟的 long-running session | 必须实验:跑一个故意 1 小时的 task 看是否中断 | **是 — 实施前必须验证** |
| R4 | 磁盘 94% 已满 | 上线前必须清理 `/root/core.*`(180GB)+ 老 workspace | **是 — Phase 1 前 blocker** |
| R5 | pending_human 无通知,人不主动看会积压 | Phase 5 加 webhook;短期靠每日报告 `## 待人手处理` 段提醒 | 否 |
| R6 | MCP scan_today() 触发 scan 流水线耗时 17-21 分钟 — 若用户在 10:30 才发现 9:00 scan 没跑成功,需要等很久 | 主 agent 应该先看 findings.jsonl 是否存在且 ts < 2h,若超时才触发完整 scan | 否 |
| R7 | LLM 误判"还在下载"导致无限等 | fetch skill 硬阈值:30min 无新输出 + 文件大小 30min 无增长 = kill | 否 |
| R8 | repair_loop 第 3 轮时 LLM 可能贪心继续试第 4 轮 | skill prompt 明确禁止;hook 监控 SubAgent 4 的 turn 计数,超过 3 轮强制注入 stop signal | 否 |
| R9 | Finding schema 加的 4 个字段需要 Analyst LLM 自己估算(估算可能不准) | Phase 0 加 unit test 验证 Analyst 输出格式;不准的字段 SubAgent 1 会现场探测 | 否 |
| R10 | 平台权限白名单可能漏掉某些 deploy 需要的 bash 命令 | settings.json 是迭代的;每次发现漏掉一个就加;短期可临时 allow `Bash(*)` 用于探索 | 否 |

### 开放问题(实施时再决定)

1. **memory/lessons 的写入触发**:何时让 SubAgent 4 主动写一条 lesson?(可能:任何 fix 成功且非常规)
2. **Blacklist 过期策略**:重复失败的项目 blacklist 多久?(初版 14 天,可调)
3. **跨日报告聚合**:reports/<date>.md 是每天一份还是按周聚合?(初版每天一份,但模板里加"近 7 天概览")
4. **scan 同步 vs 异步**:CC 主 agent 是等 scan_today 返回再开始,还是先做接续再读最新 findings?(初版等)

---

## 16. Appendix:数据 Schema 完整定义

### A.1 Finding(scan → CC)

```typescript
type Finding = {
  // 标识
  slug: string;            // "flux-schnell"
  title: string;
  github_url: string;

  // 模型规模
  hf_repos: string[];
  estimated_params_b: number;          // 参数量(B,30B 阈值)
  estimated_weight_size_gb: number;    // 磁盘 preflight
  gated_repos: string[];               // 子集 of hf_repos

  // 业务关联
  scenario_hits: string[];             // ["scenario_003"]
  recommended_route: "api" | "self_host_5090" | "hybrid";
  next_action: "try_deploy_self_host" | "try_api_pilot" | "monitor_only" | "skip";

  // 元数据
  source_urls: string[];
  confidence: "high" | "medium" | "low";
  scan_ts: string;
  scan_report_path: string;
};
```

### A.2 RunResult(SubAgent 4 → 主 agent)

```typescript
type RunResult = {
  passed: boolean;
  error_class: string | null;  // "CUDA_OOM" | "MODULE_MISSING" | ...
  repair_count: number;
  stdout_tail: string;
  gpu_snapshot: {
    memory_used_mb: number;
    utilization_pct: number;
    processes: number;
  };
  fixes_applied: string[];
  post_conditions_met: Record<string, boolean>;
};
```

### A.3 VerifyState(SubAgent 5 → 主 agent)

```typescript
type VerifyState = {
  passed: boolean;
  failed_at: "startup" | "smoke_test" | "gpu_utilization" | null;
  evidence: {
    stdout_snippet?: string;
    gpu_stats?: object;
    output_files?: string[];
  };
  notes: string;
};
```

### A.4 Outcome(CC → scan via MCP)

```typescript
type Outcome = {
  slug: string;
  status: "passed" | "failed" | "paused_for_human" | "skipped_too_large" | "api_route";
  error_class: string | null;
  phase_failed_at: string | null;
  run_id: string;
  notes: string;
  ts: string;
  repair_count: number;
};
```

---

**End of design doc.**

---

## ChangeLog

> 本节回填 v1.0 立项后所有影响本 spec 的架构改善。每条引 fix.md 证据。规则见 [spec-plan-governance §3](2026-05-27-spec-plan-governance.md#3-正文--changelog-二分原则)。

- **2026-05-27** — 立 ChangeLog 章节,回填 v1.0 后所有架构改善
  - 变更类型: 结构
  - 影响范围: 本 spec 全部正文
  - 动机: 引入 fix 体系后,spec 变更需可追溯到 fix 证据
  - 证据: [fixes/2026-05-19-cron-driven-architecture-fix.md](../fixes/2026-05-19-cron-driven-architecture-fix.md)(架构立项 fix)
  - 验证: 待验证(下次 spec 变更走完整流程时回填)

- **2026-05-25** — 引入 Phase 5 增量(runbook + cleanup)
  - 变更类型: 流程扩展
  - 影响范围: 不动 v1.0 正文,通过 addendum 增量
  - 动机: 部署后需"沉淀 runbook + 清理 workspace"两步,完善生命周期
  - 证据: [specs/2026-05-25-runbook-and-cleanup-addendum.md](2026-05-25-runbook-and-cleanup-addendum.md)
  - 验证: ✅ L1 测试通过

- **2026-05-21** — Baseline 对比 3 个阻塞点闭环(cache 隔离 / 禁并行 pip / GPU preflight)
  - 变更类型: 规则
  - 影响范围: 主 agent 与 SubAgent 串行/并行约定 + preflight 必调用
  - 动机: SongGen baseline 试跑暴露的根本阻塞
  - 证据: [fixes/2026-05-21-baseline-3-blockers-fix.md](../fixes/2026-05-21-baseline-3-blockers-fix.md)
  - 验证: ✅ 3 项目跑通(SongGen / OmniVoice / Hunyuan3D-2)

- **2026-05-21** — SubAgent 隔离原则(R1 + R9 + verify 独立判定)
  - 变更类型: 约束
  - 影响范围: 全部 SubAgent 边界
  - 动机: SongGen run2 暴露主 agent 越权 + 跨 run 干扰
  - 证据: [fixes/2026-05-21-agent-isolation-fix.md](../fixes/2026-05-21-agent-isolation-fix.md)
  - 验证: ✅ PostToolUse hook 实时检测生效
