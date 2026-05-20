# AI Auto Harness

> **基于 Claude Code 源码的 AI 项目信号发现 → 自动部署 → 自动验证 → 公司视角建议 平台**

每天 10:30 由 cron 触发,自主完成:
1. 通过 MCP 从 [ai-daily-scan](https://github.com/haichengmai20-hub/ai-daily-scan) 拿当日 AI 项目候选
2. 按 30B 阈值 / 资源 / blacklist 过滤,挑 1 个最值得部署的
3. 5 阶段 SubAgent 串行部署:
   - **intake**:git clone + 读 README + 资源 preflight(GPU/磁盘/gated/参数量)
   - **fetch-weights**:HF 权重下载(background bash + 跨 cron 周期接续)
   - **install-env**:venv + pip + torch sm_12 修复 + 常见 build issue
   - **run-and-repair**:试跑 entry_script,失败 LLM 自主修复(max 3 轮)
   - **verify**:独立 SubAgent 判定能否跑(限 Read+Bash 工具防"顺手修")
4. 模型 > 30B / gated 无 token / 资源短缺 → 产 API 调用骨架 + 中文使用指导
5. 失败 3 轮收敛不了 → 写 `pending_human/<slug>.md` 等人手处理
6. 写每日报告 + MCP `record_outcome` 回填给 scan

---

## 架构

```
cron@10:30 ─→ /auto-daily ─→ daily-auto skill ─┐
                                                │
                                ┌───────────────┴────┐
                                ▼                    ▼
                          5 阶段 SubAgent       write-recommendation
                                                       │
                                                       ▼
                                              reports/<date>.md
                                              + MCP record_outcome
```

```
/root/ai-auto-harness/                  (基于 claudecode_sourcecode1 fork,Bun + TypeScript)
├── src/                                CC 源码(不动)
├── bin/claude-haha                     CC 启动入口
├── .claude/
│   ├── CLAUDE.md                       项目硬约束 + 工作流
│   ├── settings.json                   权限白名单 + MCP server 配置
│   ├── skills/                         13 自定义 skill,CC 自动识别
│   │   ├── auto-daily/SKILL.md         主 agent / cron 入口
│   │   ├── auto-status/SKILL.md        /auto-status 只读状态
│   │   ├── auto-deploy/SKILL.md        /auto-deploy <url> 手动单项目
│   │   ├── auto-recover/SKILL.md       /auto-recover 强制接续
│   │   ├── intake/SKILL.md             SubAgent 1
│   │   ├── fetch-weights/SKILL.md      SubAgent 2(背景下载 + 跨 cron 接续)
│   │   ├── install-env/SKILL.md        SubAgent 3
│   │   ├── run-and-repair/SKILL.md     SubAgent 4(替代 Python repair_loop)
│   │   ├── verify/SKILL.md             SubAgent 5(独立判定)
│   │   ├── api-skeleton/SKILL.md       不能 self-host 时产 client.py + 指导
│   │   ├── write-recommendation/SKILL.md 报告 + 回填
│   │   ├── request-human-intervention/SKILL.md 人介入通道
│   │   ├── preflight-gpu-disk/SKILL.md GPU/磁盘/gated/30B 子能力
│   │   ├── verifier-corrector/SKILL.md 报告事实核验 + 回写
│   │   ├── coverage-gaps/SKILL.md      跨日盲区追踪
│   │   └── cost-analysis/SKILL.md      双路成本表标准化
│   └── agents/                         5 SubAgent 角色定义(限工具集 + 反模式)
├── cron/
│   ├── daily.sh                        cron 入口(--bare + --add-dir + --settings)
│   └── crontab.example
├── workspace/<slug>/                   每项目隔离工作目录(gitignored)
│   ├── state.json                      阶段进度(跨 cron 接续核心)
│   ├── repo/                           git clone 的项目代码
│   ├── venv/                           Python venv
│   ├── .cache/                         HF/transformers 隔离 cache
│   └── api_skeleton/                   API 路线时的产出
├── runs/<run-id>/                      每次 cron 跑的 trace(gitignored)
│   ├── meta.json
│   ├── decisions.md                    agent 主动写的关键决策
│   ├── intake.json / fetch.json / ...  各 SubAgent 返回
│   └── transcript.jsonl                tool_use 流(--bare 模式下需 skill 内自己写)
├── reports/<YYYY-MM-DD>.md             每日总报告(人读)
├── memory/
│   ├── projects/<slug>.md              项目专属经验(部署一次的踩坑记录)
│   └── lessons/                        通用经验(跨项目复用)
│       ├── torch-sm12.md               5090 sm_12 wheel 修复(3 方案)
│       ├── hf-gated.md                 gated repo 处理(token vs license)
│       └── flash-attn-build.md         prebuilt wheel 智能选择
├── pending_human/<slug>.md             需要人手介入的项目(删文件即解除)
├── state/blacklist.jsonl               agent 自主写入的 blacklist
└── docs/superpowers/
    ├── specs/                          设计文档
    └── plans/                          实施 plan(本平台开发用)
```

---

## 快速开始

### 1. 装 bun(若没装)

```bash
curl -fsSL https://bun.sh/install | bash
```

### 2. 装 CC 依赖

```bash
cd /root/ai-auto-harness
bun install
```

### 3. 配 .env

```bash
cp .env.example .env
# 编辑:
#   ANTHROPIC_API_KEY=<你的 key>
#   ANTHROPIC_BASE_URL=<API endpoint,如 MiniMax / Astron / 官方>
#   ANTHROPIC_MODEL=<模型 ID>
#   HF_TOKEN=<可选,部署 gated repo 时需要>
```

### 4. 测试(只读,不动 GPU/磁盘)

```bash
./bin/claude-haha \
    --bare \
    --add-dir . \
    --settings .claude/settings.json \
    --print "/auto-status"
```

应看到 GPU + 磁盘 + workspace 状态摘要(中文 markdown).

### 5. 手动单项目部署

```bash
./bin/claude-haha \
    --bare \
    --add-dir . \
    --settings .claude/settings.json \
    --print "/auto-deploy https://github.com/tencent-ailab/SongGeneration"
```

(会真跑 — clone repo + 拉 HF 权重 + 装环境 + run + verify;30-60 分钟)

### 6. 部署 cron(每日自动)

```bash
crontab -e
# 加:
30 10 * * * /root/ai-auto-harness/cron/daily.sh
```

---

## 为什么用 `--bare`

CC 默认启动会做:OAuth / keychain reads / plugin sync / auto-memory / 等等 — 在公司内网 Privoxy 代理环境下,这些会触发 HTTP 拦截造成**启动挂死**.

`--bare` 跳过这些,Anthropic auth 严格走 `ANTHROPIC_API_KEY`,完全符合"workspace 内全权 + 不动 server 其他东西"的安全模型.

代价:`--bare` 同时跳 hooks(SessionStart/PostToolUse/SessionEnd)— skill 内自己生成 run-id / 写 transcript / commit 报告.

---

## 设计文档 + 实施 Plan

完整设计(16 节):[docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md](docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md)

实施 plan(46 task,Phase -1 → 4):[docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md](docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md)

---

## 上下游

```
┌─────────────────────────┐         ┌─────────────────────────┐
│  ai-daily-scan          │  MCP    │  ai-auto-harness        │
│  (Python, 你的 GitHub)  │ ──────→ │  (本项目,公司 Gitea)    │
│  - 每日 scan / Analyst  │  stdio  │  - 部署 / 验证 / 报告   │
│  - 7 子 agent 流水线    │         │  - 13 skill / 5 SubAgent│
│  - 产 findings.jsonl    │ ←─────  │  - 回填 outcomes.jsonl  │
└─────────────────────────┘ MCP     └─────────────────────────┘

[已 deprecated] auto-deploy-agent — Python 工程,prompt 经验已迁移到本平台 lessons
```

---

## 维护

- **CC 升级跟进**:`git pull upstream main`(upstream remote 指向 claudecode_sourcecode1)
- **自己的 commit 前缀**:全部用 `ai-auto: ...`,`git log --grep=ai-auto` 看自己 work
- **新 lesson 积累**:run-and-repair / install-env SubAgent 自主写入 `memory/lessons/`(跨项目复用)
- **磁盘清理**:定期清 `workspace/` 中 7 天未访问的项目 + 7 天以上 `runs/`(SessionEnd hook 在 TUI 模式下自动做;cron 模式需手动)

---

## 风险与注意

- **R2(待验证)**:`Bash(run_in_background=true)` + `setsid nohup` 在 CC `--print` 模式退出后能否真持久 — Phase 2 e2e 验证时确认
- **R3(待验证)**:`--print` 模式撑得过 30+ 分钟 long-running session 吗 — 同上
- **磁盘**:跑 SongGen 等中等模型(~15GB)+ FLUX 等(~30GB)+ 大模型(>50GB)前确认 free > 估算 + 50GB safety
- **GPU**:本平台**严格 preflight 不抢训练 GPU**(单卡 ≥25GB used 拒动),所以训练时跑 cron 通常会触发 `pending_human/_resources.md`

---

*Powered by Claude Code(`--bare` 模式)+ ai-daily-scan MCP*
