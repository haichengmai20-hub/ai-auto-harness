# AI Auto Harness — Project Context

你正在 `/root/ai-auto-harness/` 这个工作目录中运行。这是一个**基于 Claude Code 源码的自定义 harness**,目标是 cron-driven 地自动发现 AI 项目信号、自动部署、自动验证、产出公司视角建议。

## 硬约束(必须遵守)

| 维度 | 阈值 |
|---|---|
| GPU 单卡占用 | 已用 ≥ 25GB(31.8GB total)拒动 |
| GPU 叠加预估 | 叠加后剩余必须 ≥ 2GB |
| 磁盘 free | 拉权重前 free ≥ (估算总大小 + 50GB safety) |
| 模型规模 | self-host 目标 ≤ 30B 参数;超过走 api-skeleton |
| torch sm 兼容 | wheel 必须含 sm_12.0(5090) |
| 并发项目数 | 单次 cron run N=1 |
| 修复循环上限 | 同阶段 max 3 轮 LLM 决策后 raise pending_human |

## 工作流(主 agent / `/auto-daily`)

1. 接续扫:`workspace/*/state.json` phase ∉ {done, paused_for_human}
2. 项目选择:接续优先 OR scan_today → 按 30B/blacklist/gated 过滤
3. 部署流水线:按 state.phase 串行 dispatch 5 SubAgent
4. 写报告 + MCP `record_outcome` 回填

## 关键路径

- 设计文档:`docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md`
- 实施计划:`docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`
- 主 skill:`.claude/skills/ai-auto/daily-auto.md`
- 5 SubAgent skills:`.claude/skills/ai-auto/{intake,fetch-weights,install-env,run-and-repair,verify}.md`
- 项目工作目录:`workspace/<slug>/`
- 经验积累:`memory/lessons/*.md`

## SubAgent 隔离

每个项目部署用 5 个 SubAgent 串行,每个 SubAgent 独立 context.
SubAgent 5(verify)**禁止读** state.json 的 run_result 字段 — 独立判定原则。

## 落盘约定(每个 SubAgent 必须遵守)

平台所有 SubAgent 的中间产物落盘到这两类位置:

### 项目级(跨 cron 累积,看 slug 即可找到)

```
workspace/<slug>/
├── state.json                      总状态(已有)
├── logs/                           [集中日志,跨 cron append]
│   ├── intake.log                  Stage 1: clone + 读 README + preflight 的 bash stdout/stderr
│   ├── fetch_weights.log           Stage 2: huggingface-cli download 的完整输出
│   ├── install_env.log             Stage 3: venv build + pip install 的完整输出
│   ├── run_and_repair.log          Stage 4: 每轮试跑的 stdout/stderr(多轮 append)
│   ├── verify.log                  Stage 5: smoke test 的完整输出
│   └── fixes.log                   [累积]agent 修复轨迹(每次修复 append 一行)
└── results/                        [最新阶段 result JSON,覆写]
    ├── intake.json                 同 SubAgent return,workspace 侧最新一份
    ├── fetch.json
    ├── install.json
    ├── environment.json            torch / cuda / python / sm_arch 快照
    ├── weights.json                hf_repos 下载元数据(下完时间 / 大小 / 是否 resume)
    ├── run.json                    RunResult
    └── verify.json                 VerifyState
```

### Run 级(每次 cron run 一份独立快照,审计用)

```
runs/<run-id>/
├── meta.json                       run 元数据
├── decisions.md                    主 agent + 各 SubAgent 写的关键决策
├── intake.json / fetch.json / ...  各 SubAgent 本次 run 的返回(快照,不覆写)
└── transcript.jsonl                tool_use 流(--bare 模式下 skill 自己 append 写入)
```

**双写原则**:每个 SubAgent return 时**同时写两份**:
- `workspace/<slug>/results/<phase>.json` — 覆写(最新)
- `runs/<run-id>/<phase>.json` — append(本次 run 独立快照)

日志只写 `workspace/<slug>/logs/<phase>.log`(累积 append,不覆写).

## 🔴 硬规则(违反 = 跑挂 / 作弊 / 损坏别人的 run)

### R1. workspace 隔离 — 只能动自己的 `$WORKSPACE`

- 你的 `$WORKSPACE` = 主 agent 传入的 `workspace/<slug-this-run>/`,**完全等于你的活动范围**
- **严禁** 读、写、`du -sh`、`ls`、`tail` 其他 `workspace/<other-slug>/` 下任何内容
- **严禁** `kill <pid>` 任何不是你本 run 起的子进程 — 哪怕看上去在抢带宽,**那是别人的 run**
  - 想知道哪些 PID 是自己的:每次 `nohup ... &` 后立刻 `echo $! > $WORKSPACE/.cache/<task>.pid`
  - 只允许 `kill $(cat $WORKSPACE/.cache/*.pid)` — 别的一概不动
- **严禁** 看到别人的 workspace 有半成品权重就停止自己下载改去"监控对方" — 那是耍小聪明,本 run 直接判定 cheat

### R2. state.json 每个 phase 必须双写 — 开始 + 结束

```bash
# phase 开始
jq --arg p "<phase>" --arg ts "$(date -Iseconds)" \
   '.phase=$p | .status="running" | .updated_at=$ts' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"

# phase 结束(或 paused/blocked)
jq --arg p "<phase>" --arg s "<done|paused_in_progress|paused_for_human|blocked>" --arg ts "$(date -Iseconds)" \
   '.phase=$p | .status=$s | .phases_done+=[$p] | .updated_at=$ts' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

monitor 看 state.json 来判定当前阶段;不更新 = monitor 看不见你在干嘛。

### R3. 每个 phase 有 wall-clock 上限,超时写 pending_human

| phase | 上限 | 超时动作 |
|---|---|---|
| intake | 15 min | request-human-intervention,reason=`intake_stuck` |
| fetch-weights | 180 min(3h) | 若进度 > 50%:`paused_in_progress=true` 让下次 cron 接续;否则 `paused_for_human` |
| install-env | 60 min | request-human-intervention,reason=`install_stuck` |
| run-and-repair | 45 min/轮 × 3 轮 | `paused_for_human`,reason=`repair_max_rounds` |
| verify | 30 min | `paused_for_human`,reason=`verify_stuck` |

phase 开始时记 `started_at`,每次 poll 前 `$(date +%s) - $(date -d "$started_at" +%s) > 上限` → 走超时分支,**不要再 sleep**.

### R4. 禁止 foreground sleep > 60s + 连续 sleep + sleep loop(浪费 turn 等于烧钱)

**run2 实测教训**:103 min wall-clock 里 sleep 占 97%(19 个空转 turn × full-context token),没做任何有意义决策。**严禁重演**。

#### R4.1 单次 sleep 上限 60s

任何 `sleep 120/300/600 && tail ...` 都禁止。

#### R4.2 连续 sleep 绝对禁止(最硬规则)

**如果上一个 tool_use 也是 sleep / 含 sleep 的 Bash,这一 turn 绝对不许再 sleep。** 必须改做以下之一:
- 立刻 return 让主 agent / cron 接续(`paused_in_progress=true` + state.json 更新)
- 跑一条**真有信息量**的 Bash(`ps aux | grep` / `du -sb $TARGET` / `tail -100 $LOG | grep -i 'error\|done\|installed'`)
- 调 `KillBash` / `BashOutput` 看 background shell 状态
- 写 `progress.md` / 更新 state.json

#### R4.3 sleep loop 检测自检

每次准备 sleep 前问自己:
> "上一次我做的是什么?如果也是 sleep 或 tail,那再 sleep 就是 sleep loop — 立刻退出本 SubAgent 让主 agent / cron 接续,**比 sleep 划算 100 倍**。"

#### R4.4 长任务正确姿势

- 长任务 `setsid nohup <cmd> > $WORKSPACE/logs/<phase>.log 2>&1 &`,记 PID
- 下一个 turn 直接 `tail -50` log + `kill -0 $PID && echo alive` 判活,**不 sleep**
- 真要等一下:**单次** `sleep ≤ 60s` + 立刻 tail,**不连续**
- 等不动了(进度无变化、log 无新行):写 `paused_in_progress=true` + return,**让 cron 下次接续比硬等划算**

#### R4.5 turn 预算上限

同一 phase 内的"poll"操作(tail / ps / du / sleep)**累计 ≤ 8 个 turn**。超过即 return `paused_in_progress`,让主 agent 决定要不要接续。

**核心原则**:LLM turn 不是免费的。每个 turn = 一次完整 LLM 推理 + full-context token 重发(sleep > 5min 必 cache miss)。一个空转 turn 比 cron 下次接续(0 token)贵 1000 倍。**退出比 sleep 划算**。

### R5. 串行带宽 — fetch 与 install 不能并行

带宽就是瓶颈.正确顺序:
1. fetch-weights 阶段:**只下权重**,pip / venv 都不要碰
2. fetch 完毕 → install-env 阶段:**只装 pip**,不再起新下载
3. install 完毕 → run-and-repair

不要在 fetch 还在跑时启动 `pip install torch`(2GB CUDA wheels 会抢同一根管道).

### R6. pip 反模式

- ❌ `pip install --no-cache-dir`(launch_worker 已 env-level 隔离 `PIP_CACHE_DIR`,**不需要**再加 `--no-cache-dir`;加了反而每次重下 wheel)
- ❌ 并行多个 `pip install` 写同一 venv → site-packages 损坏
- ✅ 串行 + foreground + `tee -a $LOG`

### R7. huggingface-cli 已废弃,统一用 `hf`

- ❌ `huggingface-cli download <repo>`(已 deprecated,有 warning)
- ✅ `hf download <repo> --local-dir <path> --token "$HF_TOKEN"`
- 若环境只有老 `huggingface-cli`,先 `pip install -U huggingface_hub`(已自带 `hf` 命令)

### R8. Phase 标记 — 每个 SubAgent 进出都必须 echo 一行可 grep 标记

主 agent / monitor / 事后审计都靠这两行从 ndjson 抓阶段边界(state.json 是终态,ndjson 是过程):

```bash
# SubAgent 进入时(第一个 Bash 调用)
echo "=== PHASE_START phase=<phase> slug=<slug> run_id=<run_id> ts=$(date -Iseconds) ==="

# SubAgent 退出前(写完 results JSON 之后,return 之前)
echo "=== PHASE_END   phase=<phase> slug=<slug> status=<done|paused|blocked> ts=$(date -Iseconds) ==="
```

格式严格(`===` 两边 + `phase=` `slug=` `status=` 键值对,空格分隔)— monitor `grep -E "^=== PHASE_(START|END)"` 直接拿事件。

### R9. 其他

- 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py` — 那是 SubAgent 的事
- 不要 max_turns > 3 在 run-and-repair 阶段(写 pending_human 比硬试好)
- 不要污染全局 HF cache — `launch_worker.sh` 已 env-level 强制 `HF_HOME=$LOG_DIR/.cache/huggingface`,你**不需要**改它,但每次 bash 重新 export 一遍是好习惯
- 不要在 verify 阶段修问题 — 只判定

---

## ChangeLog

> 本节回填 R1-R9 的引入来源。每条 R 规则都对应一个 fix.md(架构改善事实链)。规则见 [docs/superpowers/specs/2026-05-27-spec-plan-governance.md](../docs/superpowers/specs/2026-05-27-spec-plan-governance.md) §3.3。

- **2026-05-27** — 立 ChangeLog 章节
  - 变更类型: 结构
  - 影响范围: 本文件
  - 动机: 引入 fix 体系,R 规则需可追溯
  - 证据: [docs/superpowers/specs/2026-05-27-spec-plan-governance.md](../docs/superpowers/specs/2026-05-27-spec-plan-governance.md)

- **2026-05-26** — R1-R9 整合到本文件 + PostToolUse hook 实时检测
  - 变更类型: 规则集成
  - 影响范围: 本文件全部 R 规则 + `.claude/hooks/post-tool-use.sh` + `cron/{launch_worker,daily}.sh`
  - 动机: SongGen run2/run3 暴露 LLM 自觉度极低,SKILL prompt 里 R 规则被忽视
  - 证据: [docs/superpowers/fixes/2026-05-26-v1.1-hardening-fix.md](../docs/superpowers/fixes/2026-05-26-v1.1-hardening-fix.md)
  - 验证: ✅ 3 项目跑通(SongGen / OmniVoice / Hunyuan3D-2)

- **2026-05-21** — R4 sleep loop 禁止(5 个子规则)
  - 变更类型: 约束
  - 影响范围: R4 + PostToolUse hook R4 检测
  - 动机: SongGen run2 实测 sleep 占 97% wall-clock,turn 预算爆炸
  - 证据: [docs/superpowers/fixes/2026-05-21-sleep-loop-discipline-fix.md](../docs/superpowers/fixes/2026-05-21-sleep-loop-discipline-fix.md)

- **2026-05-21** — R1 workspace 隔离 + R9 主 agent 不亲自 bash
  - 变更类型: 约束
  - 影响范围: R1 + R9 + verify 独立判定
  - 动机: SongGen run2 暴露主 agent 越权 + 跨 run kill 别人 PID
  - 证据: [docs/superpowers/fixes/2026-05-21-agent-isolation-fix.md](../docs/superpowers/fixes/2026-05-21-agent-isolation-fix.md)

- **2026-05-21** — R5 串行带宽 + R6 pip 反模式 + R7 `hf` 不 `huggingface-cli`
  - 变更类型: 规则
  - 影响范围: R5 / R6 / R7 + `cron/launch_worker.sh` HF_HOME 隔离
  - 动机: SongGen baseline 对比 3 个阻塞点
  - 证据: [docs/superpowers/fixes/2026-05-21-baseline-3-blockers-fix.md](../docs/superpowers/fixes/2026-05-21-baseline-3-blockers-fix.md)
