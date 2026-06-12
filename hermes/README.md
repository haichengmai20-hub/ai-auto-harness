# ai-auto-harness — Hermes Agent 版

> 按 [docs/migration-to-hermes.md](../docs/migration-to-hermes.md)(v2, 2026-06-10)实现,2026-06-12 落地。
> 目标运行时:hermes-agent 0.16.0(Nous Research,本机已装,源码 /root/hermes-agent)。

## 目录

```
hermes/
├── AGENTS.md                      # 主 agent 上下文(install 后 symlink 到 harness 根,压住源码 CLAUDE.md)
├── install.sh                     # 安装/卸载/注册 cron
├── skills/ai-auto-harness/
│   ├── SKILL.md                   # 主编排 skill(= CC auto-daily;delegate_task 派发)
│   └── references/                # 7 个阶段 playbook(子代理读;= CC 各阶段 SKILL.md 的移植)
│       ├── intake.md  fetch-weights.md  install-env.md  run-and-repair.md
│       ├── verify.md  write-deploy-runbook.md  cleanup.md
└── scripts/
    ├── guard.env.sh               # R 规则软拦截(替代 CC PostToolUse hook;难题1 方案A)
    ├── harness-preflight.sh       # cron --script:0 token 预检,stdout 注入 agent prompt(4.3/9.3)
    ├── harness-postflight.sh      # no_agent:sentinel 审计/runs 清理建议/违规汇总/git 归档(9.3)
    ├── monitor-poll.sh            # no_agent every 5m:有活跃部署才巡检,异常才输出(9.1)
    └── pending-human-notify.sh    # no_agent every 30m:pending_human 新文件推送(9.8)
```

**复用不复制**:workspace/state.json/sentinel/pending_human/memory/lessons/validate-*.sh/reconcile-*.sh 与 CC 版**共用同一份**(迁移方案"100% 复用"组件),本目录只含 Hermes 特有层。

## 三大难题的落地

| 难题 | 落地 |
|---|---|
| 🔴 PostToolUse hook 缺失 | `guard.env.sh`:bash 函数覆盖 sleep/kill/pip/git/huggingface-cli。R4 截断、R1/R11 直接拒绝(exit 125)、R6 剥 flag——**比方案 A 预估的"仅警告"更强**。违规进工具结果 stderr(LLM 看得到)+ `state/guard-violations.log`(monitor/postflight 汇总)。双轨加载:① `~/.hermes/.env` 的 BASH_ENV + config.yaml env_passthrough;② 各 playbook 命令模板第一行显式 source。树外(非 /root/ai-auto-harness)零行为变化 |
| 🟡 delegate_task 只回 summary | 派发 context 强制三件套:输入参数显式注入(禁子代理自拼路径)+ 指路 references/<phase>.md + "summary 必须原样含完整 result JSON";主 agent 兜底读 `results/<phase>.json`(子代理总会落盘) |
| 🟢 跨 cron 接续 | preflight(注入模式)+ sentinel/PID 文件原样保留。⚠️ 跨 cron 长任务**必须 setsid nohup**,不可用 `terminal(background=true)`(挂在 Hermes 进程下,cron 一次性 run 结束可能被回收) |

## 与迁移方案的 4 处明确偏离(都有理由)

1. **目录命名不改**(4.5 的 weights/ handoff/ .run-cache/ 暂缓):workspace 与 CC 版共用,validate/reconcile 脚本全 grep 旧路径;等 CC 版退役后再单独迁移
2. **落盘用 9.7 方案 A 而非推荐的 B**(主 agent cp 快照,而非纯事件流审计):B 依赖 CC 的 events.ndjson;Hermes 的事件在自己 DB 里,现有 validate 工具读文件。A 只花每 phase 一条 cp,保住 runs/ 审计与工具 100% 复用
3. **不用 per-project profile**(4.2):Hermes profile 是完整 HERMES_HOME 命名空间(自带 config/skills/cron),按项目建会配置漂移;按方案风险表第 3 行的预案退回 shell export(guard.env.sh 恢复 env + playbook 显式 export)
4. **monitor 巡检 5m 不是 2m**(9.1):无活跃部署时整段静默 exit,5m 足够且少打扰

**暂未做**(Phase 2/3 余项):lessons → Hermes memory 自动检索(9.4 多模型已在 SKILL 留口:delegate_task 的 model 参数)、Telegram/飞书 deliver(cron 命令把 `--deliver local` 换平台即可)、PostToolUse hook 的 Hermes PR(难题1 方案 C)、api-skeleton/verifier-corrector/auto-recover 等周边 skill 移植。

## 安装与启用

```bash
bash hermes/install.sh            # 装 skill/scripts/AGENTS.md/guard(不注册 cron,安全)
bash ~/.hermes/scripts/harness-preflight.sh   # 冒烟:应输出状态摘要
# 手动试一轮(交互式,不等 cron):
#   hermes chat → "用 ai-auto-harness skill 跑一轮部署"
```

**切到 Hermes cron(双驱防护)**:CC 版 crontab 的 daily.sh 与 Hermes daily job **同一时刻只能开一个**(同一 workspace)。
`install.sh --register-cron` 会先检查 crontab,发现 daily.sh 未注释直接拒绝。9:00 的 ai-daily-scan 扫描 cron 与此无关,保留。

**回滚**:`bash hermes/install.sh --uninstall` + 恢复 crontab 的 daily.sh 行。state.json/sentinel 格式两边相同,中断点互相可接续。

## 约束力分层(对照 CC 版)

| 层 | CC 版 | Hermes 版 |
|---|---|---|
| 实时拦截 | PostToolUse hook(R1/R4/R6/R9/R11 警告注入) | guard.env.sh(R1/R11 拒绝、R4 截断、R6 剥除、R7 改写)— R9 无法在 bash 层拦,靠 SKILL 强调 + 事后审计 |
| 规则到达执行者 | 各 SKILL.md 内复述(S-1) | references/*.md + 派发 context 浓缩(同一原则) |
| 事后审计 | validate-run-discipline.sh(ndjson) | postflight 汇总 guard-violations.log;ndjson 审计不适用(Hermes 无该文件) |
| 平台兜底 | reconcile-*/enforce-wallclock(cron 前) | 同一批脚本,preflight/monitor/postflight 调用 |

## 验证状态(2026-06-12)

- [x] 全部脚本 `bash -n` 通过;guard 函数单测(sleep 截断/kill 拒绝/pip 剥 flag/git 拒绝/树外不激活)
- [x] preflight 实跑输出正确摘要;monitor/postflight/notify 空跑静默
- [x] install.sh 实装(skill/scripts/AGENTS.md/env_passthrough)
- [ ] L1:hermes chat 手动跑一轮 scan→pick→intake(待用户起,烧 API token)
- [ ] L2:Hermes daily cron 端到端一个小项目(待切换决策)
