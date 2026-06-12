# AI Auto Harness — Hermes 运行时上下文

> 本文件由 install.sh symlink 到 `/root/ai-auto-harness/AGENTS.md`,Hermes `--workdir` 注入主 agent
> (优先级压住根 CLAUDE.md — 那是 claude-haha 源码开发文档,与平台运维无关)。
> ⚠️ delegate_task 子代理**收不到本文件** — 子代理规则在 `hermes/skills/ai-auto-harness/references/*.md`,
> 派发 context 必须指路 playbook(S-1 教训,fix #31)。

你在 `/root/ai-auto-harness/`:cron 驱动的自动平台 — 发现 AI 项目 → 部署 → 验证 → 产出公司视角建议。
主工作流:`ai-auto-harness` skill(Hermes 版,`~/.hermes/skills/ai-auto-harness/SKILL.md`)。

## 资源硬约束

| 维度 | 阈值 |
|---|---|
| GPU 单卡 | 已用 ≥25GB(32GB total)的卡不参与分配 — **那是用户训练,严禁清理/kill** |
| GPU 叠加 | 叠加后剩余 ≥2GB;聚合判定需模型支持多卡切分 |
| 磁盘 | 拉权重前 free ≥ 估算 + 50GB |
| 模型规模 | ≤30B self-host;超了走 api-skeleton |
| 并发 | 单 cron run N=1 |
| 修复轮 | 同阶段 3 轮后 pending_human(依赖缺失类例外 +2,见 run-and-repair playbook) |

## 落盘约定

- 项目级:`workspace/<slug>/{state.json, logs/<phase>.log(append), results/<phase>.json(覆写)}`
- run 级:`workspace/<slug>/runs/<run-id>/` — 主 agent 每 phase 后 `cp results/<phase>.json` 快照(单写+快照,子代理不管双写)
- sentinel:`workspace/<slug>/.cache/handoff/*.json`;PID:`workspace/<slug>/.cache/*.pid`
- 等人:`pending_human/<slug>.md`(文件在=等人,删文件=解除)

## 🔴 R1-R11 硬规则(违反 = 跑挂/作弊;guard.env.sh 对 R1/R4/R6/R7/R11 实时拦截)

- **R1 隔离**:只动自己 `$WORKSPACE`;kill 只许动 `$WORKSPACE/.cache/*.pid` 登记的 PID
- **R2 state 双轴**:每 phase 起止 jq 原子更新 state.json(phase 轴 × status 轴:running/done/paused_in_progress/paused_for_human/blocked)+ updated_at
- **R3 wall-clock**:intake 15' / fetch 180' / install 60' / run 45'×3 / verify 30';超时走暂停分支不再等。兜底 `scripts/enforce-wallclock.sh`
- **R4 等待纪律**:单次 sleep ≤60s,连续 sleep 禁,poll ≤8 次/phase;Hermes 内等待优先 `terminal(background=true, notify_on_complete=true)`;**跨 cron 长任务必须 setsid nohup + sentinel**(background=true 的进程随 cron run 结束可能被回收);退出让 cron 接续比空转便宜 1000 倍
- **R5 串行带宽**:fetch 完全 done 才 install;下载与 pip 绝不并行
- **R6 pip**:禁 `--no-cache-dir`(cache 已隔离);禁并行 pip 写同一 venv
- **R7 HF 下载**:`hf` 不是 `huggingface-cli`;无 `--resume-download`;`HF_HUB_DISABLE_XET=1` + `CONCURRENCY=2`;**严禁 unset proxy / 把外网域名加进 no_proxy**(本机无直连=断网,fix #36);`--token "$HF_TOKEN"` 显式传
- **R8 phase 标记**:子代理进出各 echo `=== PHASE_START|PHASE_END phase=<p> slug=<s> ... ===`(monitor 靠 grep)
- **R9 主 agent 只派发**:每 phase 必须 delegate_task;主 agent 的 terminal 只做路由/读写 state/cp 快照/跑 validator;严禁亲自 git clone / hf download / pip install / python 推理
- **R10 sentinel**:跨 cron 后台任务必写 handoff sentinel;生产者退出时原子写终态;poll 见 PID 死(含 `/proc/<pid>/stat` 为 `Z` 僵尸)立即补写终态。兜底 `scripts/reconcile-sentinels.sh`
- **R11 分支纪律**:run-and-repair 严禁 git checkout/switch 切分支(guard 直接拒);`git checkout -- <file>` 豁免

**verify 独立判定**:verify 子代理禁读 state.json 的 run_result。

## 环境事实

- 本机**无直连外网**,一切外网经代理(`.env` 的 http_proxy);no_proxy 只放内网/可直连国内 host
- `.env` 含 HF_TOKEN / API key,敏感,gitignored,不外泄
- 容器 PID 1 是 `tail -f /dev/null` 不收尸:僵尸进程 kill -0 误判活,判死要查 `/proc/<pid>/stat`
- runs/songgen-e2e-*/ 两个大 cache 是用户自己处理的,**严禁 rm**

## 与 CC 版的关系

CC 版(claude-haha + crontab)与 Hermes 版共用 workspace/state/sentinel/validate 脚本,**同一时刻只能开一边的 daily cron**(否则双驱同一 workspace)。切换/回滚见 `hermes/README.md`。
