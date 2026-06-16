# AI Auto Harness — Project Context

你在 `/root/ai-auto-harness/`(基于 Claude Code 源码的自定义 harness):cron-driven 自动发现 AI 项目 → 部署 → 验证 → 产出公司视角建议。

> 本文件只写**结论**。详解/示例/bash 模板/目录树/历史 ChangeLog → [docs/superpowers/specs/2026-06-10-r-rules-reference.md](../docs/superpowers/specs/2026-06-10-r-rules-reference.md)(下称 **REF**)。各阶段操作细节以对应 `.claude/skills/*/SKILL.md` 为准(SubAgent 收不到本文件,规则已复述在 skill 内 — 故意设计,见 fix #31)。

## 资源硬约束

| 维度 | 阈值 |
|---|---|
| GPU 单卡占用 | 已用 ≥ 25GB(31.8GB total)拒动 |
| GPU 叠加预估 | 叠加后剩余必须 ≥ 2GB |
| 磁盘 free | 拉权重前 free ≥ (估算总大小 + 50GB safety) |
| 磁盘 cron 门槛 | free < 150GB 不起新 cron run(daily.sh / hermes preflight 代码强制,`AI_HARNESS_MIN_FREE_GB` 可调)— 本机训练优先,部署让路 |
| 模型规模 | self-host 目标 ≤ 30B 参数;超过走 api-skeleton |
| torch sm 兼容 | wheel 必须含 sm_12.0(5090) |
| 并发项目数 | 单次 cron run N=1 |
| 修复循环上限 | 同阶段 max 3 轮 LLM 决策后 raise pending_human(依赖缺失类例外 +2 轮,见 R3) |

## 工作流(主 agent / `/auto-daily`)

1. 接续扫:`workspace/*/state.json`,phase ∉ {done, archived, paused_for_human} 且 status ≠ paused_for_human
2. 项目选择:接续优先 OR `scan_today` → 按 30B/blacklist/gated/pending_human 过滤
3. 部署流水线:按 state.phase 串行 Task() dispatch SubAgent(intake → fetch → install → run → verify → runbook → cleanup)
4. 写报告 + MCP `record_outcome` 回填(失败暂存 `state/outcomes-pending.jsonl` 下次重试)

关键路径:主 skill `.claude/skills/auto-daily/`;各阶段 skills `.claude/skills/{intake,fetch-weights,install-env,run-and-repair,verify,write-deploy-runbook,cleanup-deployed-workspace}/`;项目目录 `workspace/<slug>/`;经验 `memory/lessons/`;设计 `docs/superpowers/specs/`。

## 落盘约定(核心;目录树全文 → REF)

- **项目级**:`workspace/<slug>/{state.json, logs/<phase>.log(append), results/<phase>.json(覆写)}`
- **run 级**:`workspace/<slug>/runs/<run-id>/`;launcher 经 `$AI_HARNESS_RUN_DIR` 注入,统一用 `$RUN_DIR`,**禁自拼** `runs/$RUN_ID`(例外:daily.sh 未知 slug 时暂存全局 `runs/cron-<ts>/`)
- **双写**:SubAgent return → `results/<phase>.json`(覆写) + `$RUN_DIR/<phase>.json`(快照)两份都写

## 🔴 R1-R10 硬规则(违反 = 跑挂/作弊;R1/R4/R6/R9 有 PostToolUse hook 实时警告;详解 → REF)

- **R1 隔离**:只动自己 `$WORKSPACE`;严禁读/写/du/ls/tail 别人 workspace;严禁 kill 任何不在 `$WORKSPACE/.cache/*.pid` 里的 PID(起后台进程后立刻 `echo $! > $WORKSPACE/.cache/<task>.pid`)
- **R2 state 双写**:每个 phase 开始(`status=running`)和结束(`done|paused_in_progress|paused_for_human|blocked` + `phases_done`)都 jq 原子更新 state.json + `updated_at` — 不更新 = monitor 看不见你
- **R3 wall-clock**:intake 15min / fetch 180min(进度>50%→`paused_in_progress`,否则 `paused_for_human`)/ install 60min / run 45min×3 轮 / verify 30min;超时走暂停分支,**不再 sleep**。代码兜底:`scripts/enforce-wallclock.sh`。**修复轮次分类 (P11 fix)**:"依赖缺失"类错误(ModuleNotFoundError/AssertionError from import)不计入 3 轮上限,可额外重试 2 次;"框架 bug"类(tensor mismatch/OOM/segfault)正常计入 3 轮
- **R4 sleep 纪律**:单次 sleep ≤ 60s;**连续 sleep 绝对禁**(上一 turn 是 sleep 这一 turn 就不许);poll 类(tail/ps/du/sleep)每 phase ≤ 8 turn,超了 `paused_in_progress` return。长任务 `setsid nohup ... &` + 记 PID + 下 turn tail 判活。**退出让 cron 接续比空转 turn 划算 1000 倍**
- **R4.6 poll 动态间隔 (P12 fix)**:后台进程存活且健康时,poll 间隔可递增 30s→45s→60s 省 turn(**单次 sleep ≤60s 硬上限不变**,要更长等待用 `sleep 55 && tail -5 $LOG` 把等待+采样合并成一次 poll);PID 死或 sentinel 变 done/failed 立即密集检查。注:R4.1/R4.2 编号属 sleep 上限/连续 sleep(hook 告警文案用此编号,详见 REF),勿混淆
- **R5 串行带宽**:fetch 完全 done 才进 install;下载与 pip 绝不并行(抢同一根管道)
- **R6 pip**:禁 `--no-cache-dir`(PIP_CACHE_DIR 已 env 隔离,加了反而重下);禁并行 pip 写同一 venv
- **R7 HF 下载**:用 `hf` 不用 `huggingface-cli`;**无** `--resume-download`(1.x 已移除,默认续传);代理环境 `HF_HUB_DISABLE_XET=1` + `HF_HUB_DOWNLOAD_CONCURRENCY=2`;**严禁 unset proxy / 把外网域名(huggingface.co 等)加进 no_proxy**(本机无直连=断网,fix #36);起前 `pgrep -f "hf download.*<repo>"` 防并发;`--token "$HF_TOKEN"` 显式传
- **R8 phase 标记**:SubAgent 进/出各 echo 一行 `=== PHASE_START|PHASE_END phase=<p> slug=<s> ... ===`(格式严格,monitor/hook 靠 grep;全格式 → REF)
- **R9 主 agent 只 dispatch**:每个 phase 必须 Task() 派 SubAgent;主 agent 的 Bash 只做路由/读写 state/调 validator;严禁亲自 `git clone` / `hf download` / `pip install` / `python ...`;run-and-repair 修 3 轮不好就 pending_human;verify 只判定不修
- **R10 sentinel**:跨 turn/cron 的后台长任务必写 `workspace/<slug>/.cache/handoff/<phase>-<id>.json`(status/pid/exit_code/started_at/completed_at/log_path,fetch 加 repo/local_dir/bytes);**生产者**退出时原子写终态;poll 发现 PID 死(含 `/proc/<pid>/stat` 为 `Z` 僵尸 — 容器 PID 1 不收尸)**立即补写终态**;看到 done 仍要 dispatch SubAgent 推进,不许主 agent 自己接着干。平台兜底:`scripts/reconcile-sentinels.sh`
- **R11 run-and-repair 分支纪律 (P10 fix)**:**严禁** `git checkout`/`git switch` 切到其他分支(丢已打的修复补丁 + 新分支结构可能完全不兼容,SCAIL 实测);修复只在当前分支做;当前分支跑不通 → `paused_for_human`。hook 对切分支命令注入警告

**verify 独立判定**:verify SubAgent 禁读 state.json 的 `run_result`(不被修复历史污染)。

## 🔴 D1-D7 文档维护规则(全文 → [spec-plan-governance](../docs/superpowers/specs/2026-05-27-spec-plan-governance.md) / [fix-records-governance](../docs/superpowers/specs/2026-05-27-fix-records-governance.md) / REF)

- **D1**:**先写 fix.md,再改 spec/SKILL/CLAUDE.md**(判定:"不写 fix 直接改规则会不会心虚")→ 改文件加 ChangeLog → 验证回填 → commit → 更新 Master Plan 索引
- **D2**:实质性改动(schema/字段/硬约束/阈值/反模式)末尾必须追加 ChangeLog 条目(变更类型/影响范围/动机/证据 fix 路径/验证);排版/错字/加示例不用
- **D3**:正文只写当下结论,历史进 ChangeLog + fix.md;同主题不写第二份 spec(用 addendum 或改原文)
- **D4**:fix 命名 `<YYYY-MM-DD>-<topic-kebab>-fix.md`,topic 是问题主题不是项目名;同 topic 唯一;fixes/README.md 索引与目录一致
- **D5**:fix 闭环后,跨项目复现的根因提升 `memory/lessons/`;单次问题留 fix 即可
- **D6**:新 SKILL.md 必含 frontmatter / 落盘约定 / 输入 schema / 返回 schema / 反模式≥3 条
- **D7**:commit 格式 `[fix]|[skill]|[spec]|[lessons] <topic>: <一句话>` + body 写改了哪些文件

---

## ChangeLog

> 2026-06-10 之前的历史条目(10 条,2026-05-21 起)已归档至 REF 末尾"历史 ChangeLog 归档"段;规则语义未变。新条目按 D2 继续加在本节。

- **2026-06-10** — CLAUDE.md 瘦身:23KB → 结论版,详解/示例/历史外迁 REF
  - 变更类型: 结构(规则语义零变更)
  - 影响范围: 全文重组;R1-R10/D1-D7 每条压缩为 1-3 行硬内核;落盘目录树/bash 模板/历史 ChangeLog 移至 `docs/superpowers/specs/2026-06-10-r-rules-reference.md`;顺带修正过时路径(skills/ai-auto/* → 实际目录)
  - 动机: 23KB 每 session 注入,规则被 3 倍体积的解释稀释,实测遵守率没换来(R9 5/5 违反);结论与教学材料分层
  - 证据: [fixes/2026-06-10-claude-md-slimming-fix.md](../docs/superpowers/fixes/2026-06-10-claude-md-slimming-fix.md)(含瘦身前后规则覆盖自查表)
  - 验证: ✅ 规则零删减自查 + 无程序化消费者(grep hooks/cron/scripts 仅 prose 引用)

- **2026-06-12** — 磁盘 cron 门槛 150GB
  - 变更类型: 硬约束(新增)
  - 影响范围: 资源硬约束表;`cron/daily.sh`(含 30min 续跑/15min 重试链)与 `hermes/scripts/harness-preflight.sh` 代码强制
  - 动机: 用户要求 — 本机同时跑训练(RL/SFT 链),部署峰值(权重+venv+wheel 几十 GB)可能挤爆磁盘;free < 150GB 时 cron 不起新 run,已在后台的下载不受影响
  - 验证: ✅ 双端阈值拉到 9999 触发 DISK_GATE / 正常阈值放行

- **2026-06-12** — 续跑假退出 fix #40:fetch-weights 后台下载免续跑
  - 变更类型: 流程(效率优化)
  - 影响范围: `cron/daily.sh`(续跑判断加 PID 存活检查);`fetch-weights/SKILL.md`(PID 活着时 1 turn 退出);`auto-daily/SKILL.md`(任务 1 加 bg_download_alive 跳过逻辑)
  - 动机: khala 实战 4 次续跑全空转(80min/300+ API 调用只做"看一眼下载还在不在")。后台 hf download PID 活着时不需要 agent 守着,应免续跑、免消耗配额
  - 证据: [fixes/2026-06-12-resume-fake-exit-fix.md](../docs/superpowers/fixes/2026-06-12-resume-fake-exit-fix.md);[specs/2026-06-11-cron-resume-and-optimization.md §7](../docs/superpowers/specs/2026-06-11-cron-resume-and-optimization.md)
  - 验证: 🟡 spec 已写,代码待实现

- **2026-06-11** — SCAIL 试跑三规则(P10/P11/P12)+ 审查更正编号与上限冲突
  - 变更类型: 规则(R3 轮次分类 / R4.6 poll 动态间隔 / R11 分支纪律)
  - 影响范围: R3 / R4.6(新) / R11(新) / 资源约束表修复轮上限行;同步下沉 run-and-repair/SKILL.md(S-1:SubAgent 收不到本文件);hook 加 R11 检测
  - 动机: SCAIL 试跑(切 wan 分支丢补丁 / flash_attn 缺失烧掉末轮 / resharding 被 poll 预算截断);初版把新规则编号写成 R4.1/R4.2 与既有 sleep 子规则(hook 告警文案同名)冲突、120s 间隔违反 sleep≤60s 上限,审查时改 R4.6/R11 并调和
  - 证据: specs/2026-06-11-试跑复盘与验证清单.md + [fixes/2026-06-11-p1-p12-implementation-corrections-fix.md](../docs/superpowers/fixes/2026-06-11-p1-p12-implementation-corrections-fix.md)
  - 验证: ✅ hook R11 单测 4/4;reconcile-state fixture 3/3
