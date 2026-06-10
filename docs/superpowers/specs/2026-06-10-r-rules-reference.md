# R 规则参考手册(完整版) — CLAUDE.md 的详解外迁

> 来源:2026-06-10 CLAUDE.md 瘦身(fix: `2026-06-10-claude-md-slimming-fix`)。
> `.claude/CLAUDE.md` 只留结论(墙贴);本文件是参考手册 — 完整示例、bash 模板、目录树、历史 ChangeLog。
> **以 CLAUDE.md 的结论为准**;本文件与其冲突时改本文件。各阶段操作细节以对应 SKILL.md 为准。

---

## 落盘约定(完整目录树)

### 项目级(跨 cron 累积,看 slug 即可找到)

```
workspace/<slug>/
├── state.json                      总状态(已有)
├── logs/                           [集中日志,跨 cron append]
│   ├── intake.log                  Stage 1: clone + 读 README + preflight 的 bash stdout/stderr
│   ├── fetch_weights.log           Stage 2: hf download 的完整输出
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

### Run 级(每次 run 一份独立快照,审计用)— 归到项目下

run 级数据落在**项目自己的** `workspace/<slug>/runs/<run-id>/`,不再堆在全局 `runs/`(各项目独立,R1 隔离自洽)。launcher(launch_worker.sh)启动时把完整路径经 `$AI_HARNESS_RUN_DIR` 注入,hook / skill 统一用 `$RUN_DIR`(= `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`),不要再自拼 `runs/$RUN_ID`。

```
workspace/<slug>/runs/<run-id>/
├── .current_run_id                 每个项目独立的当前 run 指针(不再全局单文件)
├── meta.json                       run 元数据
├── decisions.md                    主 agent + 各 SubAgent 写的关键决策
├── intake.json / fetch.json / ...  各 SubAgent 本次 run 的返回(快照,不覆写)
├── harness.stdout.ndjson           worker 事件流(launch_worker 产)
├── transcript.jsonl                PostToolUse hook 落盘的 tool_use 流
└── .cache/                         本 run 的 isolated cache(HF/pip/torch,cleanup 第 2.5 步清)
```

**唯一例外**:`daily.sh`(auto-daily cron)在 launch 时还没 pick slug,其 worker 级目录暂存在全局 `runs/cron-<ts>/`(N=1,无跨项目混杂);slug 已知后 SubAgent 双写仍走 `$AI_HARNESS_RUN_DIR`(= 该 cron 目录)。

**双写原则**:每个 SubAgent return 时**同时写两份**:
- `workspace/<slug>/results/<phase>.json` — 覆写(最新)
- `$RUN_DIR/<phase>.json` — append(本次 run 独立快照,slug 已知时即 `workspace/<slug>/runs/<run-id>/<phase>.json`)

日志只写 `workspace/<slug>/logs/<phase>.log`(累积 append,不覆写).

---

## R1. workspace 隔离 — 只能动自己的 `$WORKSPACE`

- 你的 `$WORKSPACE` = 主 agent 传入的 `workspace/<slug-this-run>/`,**完全等于你的活动范围**
- **严禁** 读、写、`du -sh`、`ls`、`tail` 其他 `workspace/<other-slug>/` 下任何内容
- **严禁** `kill <pid>` 任何不是你本 run 起的子进程 — 哪怕看上去在抢带宽,**那是别人的 run**
  - 想知道哪些 PID 是自己的:每次 `nohup ... &` 后立刻 `echo $! > $WORKSPACE/.cache/<task>.pid`
  - 只允许 `kill $(cat $WORKSPACE/.cache/*.pid)` — 别的一概不动
- **严禁** 看到别人的 workspace 有半成品权重就停止自己下载改去"监控对方" — 那是耍小聪明,本 run 直接判定 cheat

## R2. state.json 每个 phase 必须双写 — 开始 + 结束

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

## R3. 每个 phase 有 wall-clock 上限,超时写 pending_human

| phase | 上限 | 超时动作 |
|---|---|---|
| intake | 15 min | request-human-intervention,reason=`intake_stuck` |
| fetch-weights | 180 min(3h) | 若进度 > 50%:`paused_in_progress=true` 让下次 cron 接续;否则 `paused_for_human` |
| install-env | 60 min | request-human-intervention,reason=`install_stuck` |
| run-and-repair | 45 min/轮 × 3 轮 | `paused_for_human`,reason=`repair_max_rounds` |
| verify | 30 min | `paused_for_human`,reason=`verify_stuck` |

phase 开始时记 `started_at`,每次 poll 前 `$(date +%s) - $(date -d "$started_at" +%s) > 上限` → 走超时分支,**不要再 sleep**.

代码级兜底:`scripts/enforce-wallclock.sh`(launcher 启动前置调用,stale running → paused_in_progress,不 kill)。

## R4. 禁止 foreground sleep > 60s + 连续 sleep + sleep loop(浪费 turn 等于烧钱)

**run2 实测教训**:103 min wall-clock 里 sleep 占 97%(19 个空转 turn × full-context token),没做任何有意义决策。**严禁重演**。

### R4.1 单次 sleep 上限 60s

任何 `sleep 120/300/600 && tail ...` 都禁止。

### R4.2 连续 sleep 绝对禁止(最硬规则)

**如果上一个 tool_use 也是 sleep / 含 sleep 的 Bash,这一 turn 绝对不许再 sleep。** 必须改做以下之一:
- 立刻 return 让主 agent / cron 接续(`paused_in_progress=true` + state.json 更新)
- 跑一条**真有信息量**的 Bash(`ps aux | grep` / `du -sb $TARGET` / `tail -100 $LOG | grep -i 'error\|done\|installed'`)
- 调 `KillBash` / `BashOutput` 看 background shell 状态
- 写 `progress.md` / 更新 state.json

### R4.3 sleep loop 检测自检

每次准备 sleep 前问自己:
> "上一次我做的是什么?如果也是 sleep 或 tail,那再 sleep 就是 sleep loop — 立刻退出本 SubAgent 让主 agent / cron 接续,**比 sleep 划算 100 倍**。"

### R4.4 长任务正确姿势

- 长任务 `setsid nohup <cmd> > $WORKSPACE/logs/<phase>.log 2>&1 &`,记 PID
- 下一个 turn 直接 `tail -50` log + `kill -0 $PID && echo alive` 判活,**不 sleep**
- 真要等一下:**单次** `sleep ≤ 60s` + 立刻 tail,**不连续**
- 等不动了(进度无变化、log 无新行):写 `paused_in_progress=true` + return,**让 cron 下次接续比硬等划算**

### R4.5 turn 预算上限

同一 phase 内的"poll"操作(tail / ps / du / sleep)**累计 ≤ 8 个 turn**。超过即 return `paused_in_progress`,让主 agent 决定要不要接续。
(enforcement:PostToolUse hook 见到 Bash 命令含 `PHASE_START` 即把 `poll_count` 重置 0 — 计数按阶段,不跨阶段累计;Fix: 2026-05-29-poll-count-accumulate-cross-phase)

**核心原则**:LLM turn 不是免费的。每个 turn = 一次完整 LLM 推理 + full-context token 重发(sleep > 5min 必 cache miss)。一个空转 turn 比 cron 下次接续(0 token)贵 1000 倍。**退出比 sleep 划算**。

## R5. 串行带宽 — fetch 与 install 不能并行

带宽就是瓶颈.正确顺序:
1. fetch-weights 阶段:**只下权重**,pip / venv 都不要碰
2. fetch 完毕 → install-env 阶段:**只装 pip**,不再起新下载
3. install 完毕 → run-and-repair

不要在 fetch 还在跑时启动 `pip install torch`(2GB CUDA wheels 会抢同一根管道).

## R6. pip 反模式

- ❌ `pip install --no-cache-dir`(launch_worker 已 env-level 隔离 `PIP_CACHE_DIR`,**不需要**再加 `--no-cache-dir`;加了反而每次重下 wheel)
- ❌ 并行多个 `pip install` 写同一 venv → site-packages 损坏
- ✅ 串行 + foreground + `tee -a $LOG`

## R7. huggingface-cli 已废弃,统一用 `hf`(+ Xet 加速,无 `--resume-download`)

- ❌ `huggingface-cli download <repo>`(已 deprecated,有 warning)
- ❌ `--resume-download` flag(huggingface_hub 1.x 已移除,加了直接报错)— `hf download` **默认断点续传**
- ❌ `HF_HUB_ENABLE_HF_TRANSFER=1`(已废弃 FutureWarning)— 用 `HF_XET_HIGH_PERFORMANCE=1`(Xet 后端,1.x 默认,`hf_xet` 随包捆绑)
- ❌ 并发起多个 `hf download` 写同一 `--local-dir`(锁竞争 → 0 MB/s)— 起前先 `pgrep -f "hf download.*<repo>"`
- ❌ 在代理环境下开 Xet 多连接跑 `hf download`(打爆代理 → 503 Too many open connections)
- ❌ 在无直连外网能力的机器上 unset proxy/no_proxy(会断网 → Network is unreachable);**严禁把 `huggingface.co` 等外网域名加进 `no_proxy`**(= 强制直连 = 断网,fix #36)
- ✅ `HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2 hf download <repo> --local-dir <path> --token "$HF_TOKEN"`(禁 Xet + 降并发,走代理但不打爆)
- ✅ launch_worker.sh / daily.sh 已 env-level 设 `HF_HUB_DISABLE_XET=1` 和 `HF_HUB_DOWNLOAD_CONCURRENCY=2`;SubAgent setsid 块内也需 re-export
- 若环境只有老 `huggingface-cli`,先 `pip install -U huggingface_hub`(已自带 `hf` 命令 + `hf_xet`)

## R8. Phase 标记 — 每个 SubAgent 进出都必须 echo 一行可 grep 标记

主 agent / monitor / 事后审计都靠这两行从 ndjson 抓阶段边界(state.json 是终态,ndjson 是过程):

```bash
# SubAgent 进入时(第一个 Bash 调用)
echo "=== PHASE_START phase=<phase> slug=<slug> run_id=<run_id> ts=$(date -Iseconds) ==="

# SubAgent 退出前(写完 results JSON 之后,return 之前)
echo "=== PHASE_END   phase=<phase> slug=<slug> status=<done|paused|blocked> ts=$(date -Iseconds) ==="
```

格式严格(`===` 两边 + `phase=` `slug=` `status=` 键值对,空格分隔)— monitor `grep -E "^=== PHASE_(START|END)"` 直接拿事件。

## R9. 主 agent 不亲自干活 + 其他

- 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py` — 那是 SubAgent 的事
- 不要 max_turns > 3 在 run-and-repair 阶段(写 pending_human 比硬试好)
- 不要污染全局 HF cache — `launch_worker.sh` 已 env-level 强制 `HF_HOME=$LOG_DIR/.cache/huggingface`,你**不需要**改它,但每次 bash 重新 export 一遍是好习惯
- 不要在 verify 阶段修问题 — 只判定

## R10. 长任务 handoff sentinel — 生产者写终态,hook 只提醒

任何会跨 turn / 跨 cron 的后台长任务(fetch / pip install / build)都必须写 sentinel:

```
workspace/<slug>/.cache/handoff/<phase>-<safe-id>.json
```

必填字段:`status`, `slug`, `phase`, `pid`, `exit_code`, `started_at`, `completed_at`, `log_path`。
fetch 场景额外字段:`repo`, `local_dir`, `bytes`。

规则:
- 后台 wrapper 退出时由**生产者进程**原子写 `status=done|failed`,不要靠即将离开的 LLM observer 猜终态
- poll 发现 PID 死(`kill -0` 失败或 `/proc/<pid>/stat` 第 3 列 `Z` — 容器 PID 1 不收尸,僵尸也算死)→ **立即**补写 sentinel 终态(fix #37)
- SessionStart hook 只把 paused / sentinel done|failed 注入上下文,提示下次 Task dispatch 接续
- SessionEnd hook 只写 handoff audit,不改 workspace state,不 kill 别人进程
- 看到 sentinel done 后,主 agent 仍必须 dispatch 对应 SubAgent 读日志/results 并推进 state,不要自己 Bash 接着做下一阶段
- 平台对账兜底:`scripts/reconcile-sentinels.sh`(launcher 启动前置调用)

---

## D1-D7 文档维护规则(完整版)

> 为什么要强制文档规则？因为本项目 fix/spec/plan/lessons **文档比代码多**。如果不按规则写文档，后人（AI 或人）翻 10 个地方也拼不出完整故事。规则来源见 [spec-plan-governance](2026-05-27-spec-plan-governance.md) 和 [fix-records-governance](2026-05-27-fix-records-governance.md)。

### D1. Fix → Spec/SKILL 的先后顺序(最硬规则)

**先写 fix.md，再改 spec/SKILL/CLAUDE.md。不许跳过 fix 直接改规则文档。**

判定标准：
> "如果不写 fix，我能不能在改 spec/SKILL 时不心虚？"
> - 不能（改的理由说不清）→ **必须写 fix**
> - 能（改的理由很显然，如初始实现）→ 不需要写 fix

流程：
1. 试跑/讨论出架构改善点 → 写 `docs/superpowers/fixes/<YYYY-MM-DD>-<topic>-fix.md`（用 `_template-fix.md`）
2. 基于 fix 结论改 spec/SKILL/CLAUDE.md
3. 被改文件末尾加 ChangeLog 条目，引 fix.md 路径
4. 验证 → 回填 fix.md "修复结果" → 标"已闭环"
5. git commit: `[fix] <topic>: <一句话>`
6. 更新 Master Plan 的 Fix 索引区

### D2. ChangeLog 条目(每份规则文档必须有)

任何 spec / SKILL.md / CLAUDE.md 的实质性改动（改 schema/字段名/硬约束/阈值/反模式），末尾**必须追加 ChangeLog 条目**：

```markdown
- **YYYY-MM-DD** — <一句话变更摘要>
  - 变更类型: 规则 / 流程 / 阈值 / 结构 / 约束 / schema / 反模式
  - 影响范围: <章节 / 字段名 / 反模式条目>
  - 动机: <为何修改>
  - 证据: <fixes/...md 路径>
  - 验证: ✅ 已验证(方式) / ⬜ 待验证
```

**不加 ChangeLog 的情况**：排版/错字/加示例/开发期初始实现。

### D3. 正文只写结论，不写历史

- ❌ 不在正文保留"旧版本是这样的…"、"以前改过 3 次…" — 过时内容让人困惑
- ✅ 正文只写当下结论（"应该这么做"），历史变迁写在 ChangeLog + fix.md
- ❌ 不在同一主题写第二份 spec（造成"哪份是真"困惑）
- ✅ 用 addendum 增量，或改原 spec 正文（并加 ChangeLog）

### D4. Fix 记录命名与唯一性

- 命名: `<YYYY-MM-DD>-<topic-kebab-case>-fix.md`（日期是写 fix 的日期，不是问题首次发生日期）
- topic 是**问题主题**，不是项目名：
  - ✅ `sleep-loop-discipline-fix`（规则）
  - ❌ `songgen-run2-fix`（项目名 — 那是 workspace/fixes.log 的语义）
- 同一 topic 只一份 fix，闭环后作为永久档案
- Fix README.md 索引表必须与 fixes/ 目录一致（无漏）

### D5. 经验库(memory/lessons/)自动增长

当 fix 闭环后，判断是否需提升到 `memory/lessons/`：
- **同一根因多次跨项目复现** → 提升到 lessons（如 torch sm_12、flash-attn）
- **只出现一次的特定问题** → 不提升，留在 fix.md 就够
- **monitor 陪跑发现的新模式** → 追加到 `memory/lessons/monitor-patterns.md`
- `memory/MEMORY.md` 索引必须与 `memory/lessons/` 目录一致

### D6. 新 Skill/Agent 创建时的文档义务

创建新 `.claude/skills/<name>/SKILL.md` 时**必须**：
1. 包含 YAML frontmatter（name / description / allowed-tools / agent）
2. 包含"落盘约定"段（日志路径 / 结果路径 / state 更新 / decisions.md）
3. 包含"输入"段（主 agent 传入的 JSON schema）
4. 包含"返回 schema"段（SubAgent return 的 JSON schema）
5. 包含"🔴 反模式"段（至少 3 条，从实际踩坑提炼）
6. 若是 fix 驱动创建 → 末尾加 ChangeLog 条目引 fix.md

### D7. Git commit 纪律

| 变更类型 | commit message 格式 | body |
|---|---|---|
| Fix 闭环 | `[fix] <topic>: <一句话>` | `fix: <path>; affected: <spec/skill path>; closes: <issue>` |
| SKILL 初始实现 | `[skill] <slug>: <一句话>` | 无强制 |
| Spec/plan 更新 | `[spec] <topic>: <一句话>` | `updated: <path>` |
| 经验库追加 | `[lessons] <topic>: <一句话>` | `added: memory/lessons/<file>` |

**严禁**：一个 commit 同时改规则文档 + 运行时代码但不写 body 说明 → 后人 grep 看不出改了什么。

---

## CLAUDE.md 历史 ChangeLog 归档(2026-06-10 之前)

> 以下条目原在 `.claude/CLAUDE.md` 末尾,瘦身时归档至此。新条目仍按 D2 加在 CLAUDE.md。

- **2026-06-08** — run 级数据从全局 runs/ 移入 workspace/<slug>/runs/
  - 变更类型: 结构 / 约束
  - 影响范围: "落盘约定" Run 级段 + 双写原则 + `cron/{launch_worker,daily}.sh` + 3 hook + `scripts/validate-run-discipline.sh` + 10 SKILL.md
  - 动机: run 级数据堆在全局 runs/ 跨项目混杂、与 R1 隔离矛盾、`.current_run_id` 全局单文件 N>1 互踩;改为按项目归档 + launcher 经 `$AI_HARNESS_RUN_DIR` 注入完整路径
  - 证据: [fixes/2026-06-08-run-dir-into-workspace-fix.md](../fixes/2026-06-08-run-dir-into-workspace-fix.md)
  - 验证: ✅ `bash -n` 全过 + skills `runs/$RUN_ID` 改 `$RUN_DIR` + 向后兼容(旧 launcher 无 RUN_DIR → fallback 全局)

- **2026-06-08** — R7 加代理环境下载优化(禁 Xet + 降并发,非 unset proxy)
  - 变更类型: 反模式 + 约束(R7 扩充)
  - 影响范围: R7 段 + `cron/launch_worker.sh` / `cron/daily.sh` + `fetch-weights/SKILL.md`
  - 动机: 公司代理连接池有限,Xet 多连接打爆代理 → 503；实测本机无直连外网能力(unset proxy → Network is unreachable),改为禁 Xet + 降并发走代理
  - 证据: [fixes/2026-06-08-proxy-hf-download-503-fix.md](../fixes/2026-06-08-proxy-hf-download-503-fix.md)
  - 验证: ⬜ 待验证(重跑 magenta-realtime fetch 阶段)

- **2026-06-04** — 加 R10 handoff sentinel + hook 审计约定
  - 变更类型: 规则 / schema
  - 影响范围: R10 / `.claude/hooks/session-start.sh` / `.claude/hooks/session-end.sh`
  - 动机: fetch 完成后无人接棒 18h,长任务终态不能只靠 observer poll
  - 证据: [fixes/2026-05-29-polling-handoff-mechanism-fix.md](../fixes/2026-05-29-polling-handoff-mechanism-fix.md)
  - 验证: ⬜ 待验证(handoff sentinel fixture + auto-recover 接续)

- **2026-06-02** — 加 D1-D7 文档维护规则(从 spec-plan-governance / fix-records-governance 提炼为硬规则)
  - 变更类型: 规则(D1-D7 新增)
  - 影响范围: CLAUDE.md "文档维护规则"段
  - 动机: 项目已有 29 fix / 4 spec / 10+ plan / 4 lessons — 文档比代码多，AI 不按规则写文档就导致知识断层
  - 证据: [specs/2026-05-27-spec-plan-governance.md](2026-05-27-spec-plan-governance.md) + [specs/2026-05-27-fix-records-governance.md](2026-05-27-fix-records-governance.md)

- **2026-06-02** — R7 对齐 huggingface_hub 1.x(去 `--resume-download` / Xet / 并发防护)
  - 变更类型: 规则(R7 扩充)
  - 影响范围: R7 段 + `fetch-weights/SKILL.md` + `fetch-agent.md` + `auto-deploy/SKILL.md` + `README.md`
  - 动机: 1.x 移除 `--resume-download`、`HF_HUB_ENABLE_HF_TRANSFER` 被 Xet 取代(FutureWarning)、并发 `hf download` 锁竞争 0 MB/s
  - 证据: [fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md](../fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md)

- **2026-06-02** — 修复 hook 执行链 run-id 所有权(R1/R4/R6/R9 实时约束失效真因)
  - 变更类型: 约束(执行链修复)
  - 影响范围: `.claude/hooks/{session-start,post-tool-use}.sh` + `cron/launch_worker.sh` + 新增 `scripts/validate-run-discipline.sh`
  - 动机: SessionStart hook 覆盖 launch_worker 的 `.current_run_id`,致 PostToolUse 把 transcript/计数写进孤儿目录,本 run 目录恒 0 计数 → R1/R4/R6/R9 自上线起从未在正确目录生效
  - 证据: [fixes/2026-06-02-hook-runid-clobber-fix.md](../fixes/2026-06-02-hook-runid-clobber-fix.md)
  - 验证: ✅ launch_worker 端到端实测 transcript 落正确目录 + own_slug 正确 + 纪律审计器复现 ControlFoley 43Bash/0Task

- **2026-05-27** — 立 ChangeLog 章节
  - 变更类型: 结构
  - 影响范围: CLAUDE.md
  - 动机: 引入 fix 体系,R 规则需可追溯
  - 证据: [specs/2026-05-27-spec-plan-governance.md](2026-05-27-spec-plan-governance.md)

- **2026-05-26** — R1-R9 整合到 CLAUDE.md + PostToolUse hook 实时检测
  - 变更类型: 规则集成
  - 影响范围: CLAUDE.md 全部 R 规则 + `.claude/hooks/post-tool-use.sh` + `cron/{launch_worker,daily}.sh`
  - 动机: SongGen run2/run3 暴露 LLM 自觉度极低,SKILL prompt 里 R 规则被忽视
  - 证据: [fixes/2026-05-26-v1.1-hardening-fix.md](../fixes/2026-05-26-v1.1-hardening-fix.md)
  - 验证: ✅ 3 项目跑通(SongGen / OmniVoice / Hunyuan3D-2)

- **2026-05-21** — R4 sleep loop 禁止(5 个子规则)
  - 变更类型: 约束
  - 影响范围: R4 + PostToolUse hook R4 检测
  - 动机: SongGen run2 实测 sleep 占 97% wall-clock,turn 预算爆炸
  - 证据: [fixes/2026-05-21-sleep-loop-discipline-fix.md](../fixes/2026-05-21-sleep-loop-discipline-fix.md)

- **2026-05-21** — R1 workspace 隔离 + R9 主 agent 不亲自 bash
  - 变更类型: 约束
  - 影响范围: R1 + R9 + verify 独立判定
  - 动机: SongGen run2 暴露主 agent 越权 + 跨 run kill 别人 PID
  - 证据: [fixes/2026-05-21-agent-isolation-fix.md](../fixes/2026-05-21-agent-isolation-fix.md)

- **2026-05-21** — R5 串行带宽 + R6 pip 反模式 + R7 `hf` 不 `huggingface-cli`
  - 变更类型: 规则
  - 影响范围: R5 / R6 / R7 + `cron/launch_worker.sh` HF_HOME 隔离
  - 动机: SongGen baseline 对比 3 个阻塞点
  - 证据: [fixes/2026-05-21-baseline-3-blockers-fix.md](../fixes/2026-05-21-baseline-3-blockers-fix.md)
