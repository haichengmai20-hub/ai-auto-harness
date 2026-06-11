# ai-auto-harness 迁移到 Hermes Agent 方案

> 版本: v2 (2026-06-10)
> 状态: 探索阶段，未动手

---

## 一、现状

ai-auto-harness 基于 **Claude Code (claude-haha) 源码 fork**，是一个 cron 驱动的自动化平台：

| 层 | 现状 |
|---|---|
| Agent runtime | claude-haha（CC 源码 TypeScript，魔改 Task 工具做 SubAgent dispatch） |
| Cron 入口 | `daily.sh` → `claude-haha -p "..." --dangerously-skip-permissions --output-format stream-json` |
| SubAgent 隔离 | CC 原生 `Task()` 工具，每个 SubAgent 独立 200K context |
| 硬规则执行 | PostToolUse hook（bash + python3 检测 R1-R10）→ 注入 `additionalContext` 回 LLM |
| 跨 cron 接续 | `workspace/<slug>/state.json` + handoff sentinel + session-start hook |
| 缓存隔离 | `launch_worker.sh` export HF_HOME / PIP_CACHE_DIR 等 12 行 env |
| Skills | `.claude/skills/` 目录，YAML frontmatter + markdown body，18 个 |
| MCP 对接 | `.mcp.json` 连 ai-daily-scan |
| 僵尸清理 | worker.pid + trap cleanup + python3 扫僵尸 |
| 事后审计 | `scripts/validate-run-discipline.sh` 等 6 个 validate 脚本 |

---

## 二、核心映射

| ai-auto-harness 概念 | Hermes 对应 | 匹配度 | 说明 |
|---|---|---|---|
| `claude-haha -p` 无头模式 | `hermes chat -q` / cronjob | 90% | Hermes 原生支持 cron + no_agent 模式 |
| `Task()` SubAgent dispatch | `delegate_task()` | 85% | 子代理隔离 context，但只返回 summary，max_spawn_depth=1 |
| `.claude/skills/*.md` | `~/.hermes/skills/*.md` | 95% | 几乎同构，YAML frontmatter + markdown |
| PostToolUse hook | **缺失** | 30% | 最大差距，无 tool-use 后的 hook/callback |
| SessionStart/End hook | **缺失** | 30% | 同上 |
| `--append-system-prompt` | memory / skill 注入 | 70% | 可注入但不是等价的实时注入 |
| `.mcp.json` MCP | MCP 工具 | 90% | Hermes 原生支持 MCP server |
| `workspace/<slug>/state.json` | file I/O | 100% | 框架无关 |
| `flock` 防并发 | cronjob flock 或 script | 90% | Hermes cronjob 支持 no_agent script |
| 僵尸清理 | process 工具 | 90% | session 内有，跨 session 仍需文件 |
| `--dangerously-skip-permissions` | `--yolo` | 90% | 等价 flag |

---

## 三、三大难题

### 难题 1：PostToolUse Hook 缺失

**严重程度**：🔴 最高

ai-auto-harness 的 R1/R4/R6/R9 约束不是靠 prompt 软约束（LLM 会无视），而是靠 PostToolUse hook 实时拦截 + 注入 additionalContext。run2 实测：没 hook 时 LLM 烧 $20.70 空 sleep 131 turns；有 hook 后显著收敛。

7/10 条硬规则靠 hook 实时拦截才有意义。

**解法（组合）**：

| 方案 | 机制 | 约束力 | 周期 |
|---|---|---|---|
| A. terminal wrapper | 所有 terminal() 调用包一层 bash wrapper，检测 sleep/kill/--no-cache-dir 等模式，违规写 warning 文件 | ~50%（非实时注入 context） | 1-2 天 |
| D. 事后 audit script | 原样复用 `validate-run-discipline.sh`，cron 跑完后审计 ndjson | ~30%（事后而非实时） | 0 天（已有） |
| B. execute_code 中间层 | 所有 bash 调用走 execute_code，Python 脚本里做检测 | ~60% | 2-3 天 |
| C. Hermes PR 加 hook | 给 Hermes 加 PostToolUse hook 机制 | 100% | 长期 |

**推荐**：A + D 组合先顶上（~80% 约束力），长期推方案 C。

### 难题 2：SubAgent Dispatch 差异

**严重程度**：🟡 中

CC 的 `Task()` 让主 agent spawn 独立 200K context 的子 agent。Hermes 的 `delegate_task()` 也能 spawn 子代理，但只返回 summary。

**解法**：5 个阶段 skill 各自独立，主 agent 按 state.json dispatch 对应阶段。子代理的 `context` 参数塞入：
- workspace 路径
- state.json 快照
- skill 名称
- R 规则浓缩版
- 本阶段专属 env vars

子代理返回的 summary 必须包含 result JSON 的完整内容（在 skill 里明确规定 return schema）。

### 难题 3：跨 cron 接续

**严重程度**：🟢 低（反而更好解决）

**解法**：
- Hermes cronjob 原生支持 `script` 参数（no_agent 模式），预检脚本 0 token
- 长任务用 `terminal(background=True, notify_on_complete=True)` 启动
- handoff sentinel 机制原样保留（纯文件 I/O，框架无关）
- 下次 cron 进来先检查 bg 进程 + sentinel + state.json

---

## 四、工作区目录迁移

### 4.1 可直接复用（100%）

| 组件 | 原因 |
|---|---|
| `workspace/<slug>/` 隔离 | 物理隔离，框架无关 |
| `state.json` 状态机 | 简单 JSON，任何 agent/脚本可读 |
| `results/` 覆写 + `runs/` 快照双写 | 既要最新状态又要历史审计 |
| `logs/` append 不覆写 | 保留完整历史 |
| `handoff sentinel` | 纯文件 I/O |
| `pending_human/` | 文件存在即"等人"，删文件=解除阻塞 |
| `validate-*.sh` 事后审计 | 不依赖 runtime hook |
| `cleanup` 白名单清理 | 框架无关 |

### 4.2 改善 1：Hermes Profile 替代 env 隔离

**现状**：`launch_worker.sh` 里 12 行 export HF_HOME / PIP_CACHE_DIR / TORCH_HOME 等，daily.sh 和 launch_worker.sh 重复维护。

**改善**：每个项目一个 Hermes profile：

```yaml
# ~/.hermes/profiles/ai-harness-scail/.env
HF_HOME=/root/ai-auto-harness/workspace/scail/.run-cache/hf-meta
PIP_CACHE_DIR=/root/ai-auto-harness/workspace/scail/.run-cache/pip
TORCH_HOME=/root/ai-auto-harness/workspace/scail/.run-cache/torch
HF_HUB_DISABLE_XET=1
HF_HUB_DOWNLOAD_CONCURRENCY=2
```

cronjob 启动时 `profile: ai-harness-scail`，Hermes 自动加载 .env，缓存隔离零代码。

### 4.3 改善 2：Cron Script 做 0 Token 预检

**现状**：daily.sh 180 行，包含 flock、僵尸清理、缓存隔离、hook_state 初始化、prompt 组装、claude-haha 启动。agent 启动后还要花 1-2 turn 做初始化。

**改善**：拆成两层：

```yaml
# Hermes cronjob 配置
schedule: "30 10 * * *"
script: scripts/harness-preflight.sh   # no_agent，0 token
prompt: "执行 ai-auto-harness 日常部署..."
skills: [ai-auto-harness]
workdir: /root/ai-auto-harness
```

`harness-preflight.sh`：
1. flock 防并发
2. 扫僵尸 worker
3. 读 state.json 判断接续项目
4. 输出一行状态摘要（注入 agent prompt）

### 4.4 改善 3：Hermes Memory 替代 lessons 手动查找

**现状**：6 个 `memory/lessons/*.md`，SubAgent 需要先 `ls` 再 `cat` 对应文件，LLM 不一定记得找。

**改善**：
- 把 lessons 存为 Hermes skill（`ai-auto-harness/lessons/torch-sm12`）
- 或用 Hermes persistent memory（全文检索）
- 遇到 `sm_12` 相关错误时，memory 自动匹配注入

### 4.5 改善 4：目录命名微调

```
workspace/<slug>/
├── state.json                 ← 不变
├── repo/                      ← 不变
├── logs/                      ← 不变
├── results/                   ← 不变
├── artifacts/                 ← 【改】从 output/ 改名，语义更清晰
├── weights/                   ← 【改】从 .cache/hf_models/ 提升
│   └── <repo>/                ← hf download --local-dir 直接落这里
├── handoff/                   ← 【改】从 .cache/handoff/ 提升
│   └── fetch-<repo>.json
├── runs/                      ← 不变
│   └── <run-id>/
│       ├── meta.json
│       ├── events.ndjson      ← 【改】从 harness.stdout.ndjson
│       ├── transcript.jsonl
│       └── <phase>.json
└── .run-cache/                ← 【改】从 .cache/ 改名
    ├── hf-meta/               ← HF metadata（run 级隔离）
    ├── pip/
    └── torch/
```

| 改动 | 原因 |
|---|---|
| `.cache/hf_models/` → `weights/` | 不是缓存，是持久权重。"cache" 暗示可删 |
| `.cache/handoff/` → `handoff/` | sentinel 是核心状态，不该藏在 .cache 里 |
| `.cache/` → `.run-cache/` | 区分项目级持久 vs run 级临时 |
| `output/` → `artifacts/` | "output" 太泛 |
| `harness.stdout.ndjson` → `events.ndjson` | 去 CC 特定命名 |

### 4.6 改善 5：Process 工具替代 PID 文件（session 内）

**现状**：每个 bg 进程写 `.cache/*.pid`，hook 检测 kill 越权。

**改善**：session 内用 `process(action='list')` / `process(action='kill')`。跨 cron 仍需文件追踪。

---

## 五、迁移后的改进汇总

| 改进 | 说明 | 预期收益 |
|---|---|---|
| 模型自由度 | fetch/install 用便宜模型，run-and-repair 用强模型 | 成本降 5-10x |
| 多平台通知 | pending_human 推到 Telegram/飞书 | 不需要人手动 check 目录 |
| Memory 自动检索 | lessons 自动匹配上下文注入 | 减少无效 turn |
| Cron 原生 | 不需要 crontab + flock + daily.sh | 维护成本降低 |
| Profile 隔离 | 每个 profile 独立 .env | 缓存隔离零代码 |
| 预检 0 Token | script 模式做 flock/僵尸清理 | 省 1-2 turn/token |
| 目录命名清晰 | weights/ 替代 .cache/hf_models/ | 新人/新 agent 更易理解 |

---

## 六、复用度评估

| 组件 | 复用程度 | 说明 |
|---|---|---|
| R1-R10 规则文本 | 90% | 直接搬 skill，措辞微调 |
| 18 个 SKILL.md | 80% | frontmatter 改 Hermes 格式，body 大部分复用 |
| PostToolUse hook 逻辑 | 30% | python3 检测逻辑可复用，触发机制需重写 |
| daily.sh / launch_worker.sh | 40% | env 隔离逻辑可复用，启动参数改 hermes CLI |
| state.json 机制 | 100% | 纯文件 I/O |
| handoff sentinel | 100% | 同上 |
| MCP 对接 | 90% | 格式微调 |
| workspace 目录结构 | 100% | 框架无关，可做命名微调 |
| memory/lessons/ | 90% | 内容复用，载体改 Hermes memory/skill |
| pending_human/ | 100% | 框架无关 |
| validate-*.sh | 100% | 直接复用 |
| cleanup skill | 100% | 直接复用 |
| src/*.ts (300+ 文件) | 0% | CC 源码，不需要 |

---

## 七、推荐迁移路径

### Phase 0（1-2 天）：验证无 hook 约束力

- 写 terminal wrapper 脚本做软检测（sleep/kill/--no-cache-dir）
- 复用现有 validate-run-discipline.sh 做事后审计
- 跑一个简单项目（如 whisper）端到端，验证 ~80% 约束力

### Phase 1（3-5 天）：5 阶段 skill 搬迁

- 5 个阶段 skill 搬到 Hermes 格式
- 主 agent 用 delegate_task dispatch
- workspace 目录结构原样复用
- 跑一个中等项目端到端验证

### Phase 2（1 周）：完善生态

- 搬剩余 skill（monitor/cleanup/cost-analysis/...）
- cron 配置 + MCP 对接
- 多模型策略（cheap model 跑 fetch/install，强模型跑 run-and-repair）
- Hermes profile 做 env 隔离
- 目录命名微调

### Phase 3（长期）：补齐 hook

- 给 Hermes 提 PR 加 PostToolUse hook 机制
- 补齐最后 20% 约束力
- 多项目并行（N>1）

---

## 八、风险与待验证项

| 风险 | 影响 | 缓解 |
|---|---|---|
| 无 hook 下 LLM 无视 R4 规则 | 烧 token 空 sleep | wrapper + audit 组合，Phase0 先验证 |
| delegate_task 只返回 summary | SubAgent 详细结果可能丢失 | skill 里强制规定 return schema，summary 包含完整 result JSON |
| Hermes profile 不支持动态创建 | cron 不能自动为新项目建 profile | 用 no_agent script 预创建，或 fallback 到 shell export |
| 跨 cron bg 进程丢失 | Hermes session 结束后 process 信息消失 | 保留 handoff sentinel + PID 文件（双轨） |
| 多模型策略下 skill 兼容性 | 便宜模型可能不理解复杂 skill | 先用同模型跑通，再逐步切换便宜模型 |

---

## 九、补充可迁移/可改善的模式

### 9.1 monitor-ride-along 陪跑监控 → Hermes process + cronjob

**现状**：`monitor-ride-along` skill 是一个独立 SubAgent，在 e2e pipeline 运行期间每 120 秒巡检一次（R 规则合规性、进程健康、下载进度、资源水位），产出 `monitor.jsonl` + `monitor_alerts.md`。

**问题**：
- CC 的 `Task()` 是同步的，monitor 必须用 `sleep + tail` 循环，浪费 LLM turn
- 每次 poll = 1 个 LLM turn + 全 context 重发，实际信息量只有 2-3 行

**Hermes 改善**：

用 **cronjob(no_agent + script)** 替代 LLM 驱动的 monitor 循环：

```yaml
# monitor cronjob — 0 token，纯 shell 巡检
schedule: "every 2m"
script: scripts/monitor-poll.sh
no_agent: true
deliver: "origin"   # 有告警时才输出(非空 stdout)
```

`monitor-poll.sh` 逻辑：
1. 读 `workspace/<slug>/state.json` 看 phase
2. 检查 bg 进程（PID 文件 / handoff sentinel）
3. 检查磁盘/GPU 水位
4. 检查下载进度（log 文件尾部）
5. 只有异常时 stdout 输出告警（空输出 = 静默，不通知）

**收益**：
- 0 token（原来每次 poll 花 ~$0.05-0.15）
- 2 分钟一次不再受 LLM turn 限制
- 告警推送到 Telegram/飞书（Hermes 原生）

**限制**：R 规则合规性检测仍需 LLM 事后审计（validate-run-discipline.sh）。

### 9.2 verifier-corrector 事实核验 → Hermes 双代理模式

**现状**：`verifier-corrector` skill 在 `write-recommendation` 写完报告后，独立核验报告中的数字声明和 URL，把 ❌ 标记回写正文。这是借鉴 ai-daily-scan 的 Verifier+Corrector 模式。

**可改善**：
- Hermes 的 `delegate_task` 天然适合这种"生产者-核验者"模式
- 核验者可以用不同模型（更便宜的模型做 URL curl 检查，强模型做数字逻辑核验）
- 当前 CC 里这个 skill 靠 `Task()` dispatch，等价于 Hermes delegate_task

**迁移难度**：低。直接复用 skill 文本，改为 delegate_task dispatch。

### 9.3 SessionStart/End Hook → Cron Preflight + Postflight

**现状**：

| Hook | 做的事 |
|---|---|
| `session-start.sh` | 生成 run-id + 加载今日 scan findings + 读 workspace state.json + 读 handoff sentinels → 注入 system prompt addendum |
| `session-end.sh` | handoff sentinel 审计 + 写 handoff-audit.json + 清理老 runs + git commit 报告 |

**Hermes 映射**：

| CC Hook | Hermes 替代 | 说明 |
|---|---|---|
| session-start.sh | cronjob `script` (preflight) | no_agent 模式跑一遍，输出注入 agent prompt |
| session-start.sh 的"今日 context" | `workdir` + skill + memory | workdir 让 agent 读项目文件，memory 自动注入经验，skill 加载规则 |
| session-end.sh | cronjob `notify_on_complete` + postflight script | agent 退出后跑一个 postflight 脚本做审计 |

**具体方案**：

```bash
# scripts/harness-postflight.sh (no_agent, 0 token)
# 1. handoff sentinel audit (原样复用 session-end.sh 逻辑)
# 2. 清理老 runs (保留最近 N 天)
# 3. git commit reports/ + memory/ (如有变更)
# 4. 非空输出 = 有 sentinel 需要下次 cron 接续，推通知
```

**收益**：
- session-start 的 context 注入不再需要 hook，由 Hermes 的 workdir + skill + memory 自动完成
- session-end 的审计逻辑独立于 agent 生命周期，即使 agent crash 也能跑 postflight

### 9.4 anthropic-qwen-proxy → 直接多模型配置

**现状**：`proxy/anthropic-qwen-proxy.ts` 是一个 33KB 的 TypeScript 代理，把 Anthropic API 格式转换为 Qwen 后端格式。这是因为 CC 只支持 Anthropic API。

**Hermes 改善**：**直接删掉**。Hermes 原生支持多 provider（openrouter/anthropic/custom），config.yaml 里直接配：

```yaml
providers:
  qwen:
    base_url: https://dashscope.aliyuncs.com/compatible-mode/v1
    api_key: ${DASHSCOPE_API_KEY}
  deepseek:
    base_url: https://api.deepseek.com/v1
    api_key: ${DEEPSEEK_API_KEY}
model:
  default: qwen/qwen3-235b-a22b
```

每个 SubAgent 可以用不同 provider，不需要代理层。

**收益**：
- 删掉 33KB TS 代码 + 维护成本
- 延迟降低（少一跳代理）
- 每阶段可以用最适合的模型（fetch 用 cheap，run-and-repair 用强）

### 9.5 auto-recover / auto-status → Hermes 斜杠命令或 skill

**现状**：`auto-recover`（强制扫接续）和 `auto-status`（看状态）是 CC 的斜杠命令 skill。

**Hermes 映射**：
- `auto-status`：直接在 chat 里问 Hermes，它读 workspace state.json 即可。或做成 no_agent cronjob 每小时推送一次状态摘要。
- `auto-recover`：做成 skill，触发时只接续 in_progress 项目不挑新。

**改善**：`auto-status` 可以做成定期 cron（每小时一次，no_agent script），自动推送状态到 Telegram/飞书，不需要人主动查。

### 9.6 trajectory.json 事件流 → Hermes session DB

**现状**：daily.sh 最后用 python3 解析 `harness.stdout.ndjson`，提取 assistant/user/result 事件，写 `trajectory.json`。这是轻量级的轨迹记录。

**Hermes 改善**：Hermes 有内置的 SQLite session DB（`state.db`），存完整的对话历史。不需要自己解析 ndjson + 写 trajectory.json。

可以通过 `session_search` 查任意历史 session，比 trajectory.json 更强大。

**收益**：
- 不需要 daily.sh 尾部的 python3 解析逻辑
- session_search 支持全文检索，比 trajectory.json 的简单事件列表有用得多

### 9.7 落盘双写原则 → 简化为单写 + 符号链接

**现状**：每个 SubAgent return 时同时写两份：
- `workspace/<slug>/results/<phase>.json`（覆写，最新）
- `workspace/<slug>/runs/<run-id>/<phase>.json`（快照，审计）

双写的维护成本：主 agent 必须在每次 SubAgent return 后手动写两份，容易遗漏。

**改善方案 A**：SubAgent 只写 `results/<phase>.json`（覆写），主 agent 在 dispatch 前用 `cp` 把上一份 results 快照到 runs 目录。这样 SubAgent 不需要知道双写规则。

**改善方案 B**：`results/<phase>.json` 仍是覆写，`runs/<run-id>/` 不存 phase JSON 副本，审计靠 `events.ndjson`（agent 事件流）+ `results/` 的 git diff。即：从"双写 JSON"改为"单写 JSON + 事件流 diff"。

**推荐**：方案 B。事件流已经包含所有 tool call 和 return 信息，不需要冗余存 phase JSON。审计时 `diff results/prev results/curr` 即可。

### 9.8 pending_human → Hermes gateway 通知

**现状**：`pending_human/<slug>.md` 文件存在即"等人"。人需要手动 `ls` 目录才知道有积压。

**改善**：写 pending_human 文件的同时，用 Hermes cronjob 推通知：

```bash
# 在 request-human-intervention skill 里追加：
# Hermes 有 Telegram/Discord/飞书 gateway，直接推消息
```

或者在 Hermes 里配一个 cronjob（每 10 分钟，no_agent script）扫 `pending_human/`，有文件就推送。

**收益**：从"被动等人发现"变成"主动推送通知"。

### 9.9 成本追踪 → Hermes 内置 + 多模型策略

**现状**：CC 有 `costHook.ts` + `cost-tracker.ts` 做 token 成本追踪，落盘到 session 级。

**Hermes 改善**：Hermes 有内置的成本追踪（每次 tool call 记录 token 用量）。迁移后：
- 不需要自己写 costHook.ts
- 多模型策略下可以按模型/阶段统计成本
- 可以用 cronjob 定期汇总成本推送

### 9.10 CLAUDE.md → AGENTS.md (Hermes 原生)

**现状**：项目指令写在 `CLAUDE.md`（16KB），包含硬规则 R1-R9、落盘约定、SubAgent 隔离等。

**Hermes 映射**：Hermes 原生读 `AGENTS.md` / `CLAUDE.md` / `.cursorrules`（自动检测）。直接把 CLAUDE.md 重命名或 symlink 到 AGENTS.md 即可。

**改善**：CLAUDE.md 里的 R 规则可以拆分：
- R1/R4/R6/R9 硬约束 → 写进 terminal wrapper（代码强制）
- R2/R3/R5/R7/R8 流程规则 → 留在 AGENTS.md（prompt 软约束）
- R10（独立判定原则）→ 写进 verify skill 的 SKILL.md

这样 AGENTS.md 更短，agent 更容易遵守。

---

## 十、整体复用度更新

| 组件 | 复用程度 | 说明 |
|---|---|---|
| R1-R10 规则文本 | 90% | 直接搬 skill，措辞微调 |
| 18 个 SKILL.md | 80% | frontmatter 改 Hermes 格式，body 大部分复用 |
| PostToolUse hook 逻辑 | 30% | python3 检测逻辑可复用，触发机制需重写 |
| SessionStart/End hook | 40% | 逻辑可复用，改为 preflight/postflight script |
| daily.sh / launch_worker.sh | 40% | env 隔离逻辑可复用，启动参数改 hermes CLI |
| anthropic-qwen-proxy.ts | 0% | **删掉**，Hermes 原生多 provider |
| monitor-ride-along skill | 30% | 逻辑可复用，改为 no_agent cronjob |
| verifier-corrector skill | 90% | 直接复用，delegate_task dispatch |
| auto-recover / auto-status | 80% | 复用逻辑，改为 Hermes skill/cronjob |
| cost-tracker.ts | 0% | **删掉**，Hermes 内置 |
| trajectory.json 生成 | 0% | **删掉**，Hermes session DB 替代 |
| state.json 机制 | 100% | 纯文件 I/O |
| handoff sentinel | 100% | 同上 |
| MCP 对接 | 90% | 格式微调 |
| workspace 目录结构 | 100% | 框架无关，可做命名微调 |
| memory/lessons/ | 90% | 内容复用，载体改 Hermes memory/skill |
| pending_human/ | 100% | 框架无关，可加通知推送 |
| validate-*.sh | 100% | 直接复用 |
| cleanup skill | 100% | 直接复用 |
| CLAUDE.md | 80% | 重命名为 AGENTS.md，R 规则拆分 |
| 落盘双写逻辑 | 60% | 简化为单写 + 事件流审计 |
| src/*.ts (300+ 文件) | 0% | CC 源码，不需要 |
