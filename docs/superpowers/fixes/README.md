# Fix 记录索引

> 治理规则见 `docs/superpowers/specs/2026-05-27-fix-records-governance.md`
> 每个 fix 文件内都有"人话版"段，用大白话解释问题，一眼就能看懂。

### 术语速查

| 术语 | 大白话 |
|---|---|
| **P0** | 着火了，现在不修整个系统跑不了 |
| **P1** | 大问题，本周必须修，否则越拖越烂 |
| **P2** | 小毛病，记着就行，有空再修 |
| **L1** | 烟测——点一下能亮就行，不测细节 |
| **L2** | 全测——每个功能都跑一遍，边界也试 |
| **🟡 部分落地** | 代码已写但还没真跑验证过 |

> 完整解释见 [Master Plan 人话版速查表 → 优先级与测试级别](../plans/2026-ai-auto-harness-master.md#优先级与测试级别pl)

## 统计

- **总计**: 36 条
- **✅ 已闭环**: 24 条（#36 no_proxy 污染断网+gated 403;#35 monitor 角色纪律;#34 run 目录归项目;#32 #33 toonflow-app e2e 闭环）
- **🟡 部分落地**: 2 条（#30 fetch 完整性校验、#31 R9；均已补 committed 回归测试，待真实 e2e / 上游）
- **❌ 未闭环**: 10 条
- **P0**: 4 条
- **P1**: 23 条
- **P2**: 7 条

> 注：上方 P0/P1/P2 为各 fix 文档 `级别` 字段的本表历史归类，与状态轴(已闭环/部分落地/未闭环)正交；优先级以各 fix 文档头部 `级别` 字段为准。

---

## 🟡 部分落地（2 条 — 代码已写 + 回归测试，待真实 e2e / 上游）

| # | 级别 | 人话 | Fix 文件 | 已落地部分 | 残留 |
|---|---|---|---|---|---|
| 30 | P1 | 下完快递不拆箱验货，少了一半零件不知道 | [fetch-weights-no-download-integrity-check](2026-06-03-fetch-weights-no-download-integrity-check-fix.md) | `validate-fetch-weights.sh` + SKILL.md Xet fallback + committed 回归测试(复现 469-vs-2.2GB) | 真实 GPU 权重下载→校验 + live-Xet-fallback 的 e2e 未跑，按"没真实 e2e 不算闭环"维持 🟡 |
| 31 | P1 | 经理自己干 77 次活 0 次派工，警告也忽略 | [r9-task-dispatch-still-bypassed](2026-06-03-r9-task-dispatch-still-bypassed-fix.md) | PostToolUse hook R9 警告 + `validate-artifacts.sh`(已补回归测试) | 根因 S-1（SubAgent 拿不到 system-prompt）待 CC 平台；硬阻断方案已评估**拒绝**（会搞挂合法路由 bash） |

---

## ❌ 未闭环（10 条 — 按优先级排）

> 接手人从上往下修。

| # | 级别 | 人话 | Fix 文件 | 影响项目 |
|---|---|---|---|---|
| 15 | **P0** | 权重下完了但没人知道该开始装环境了，干等 18 小时（MVP 已加,待 L1） | [polling-handoff-mechanism](2026-05-29-polling-handoff-mechanism-fix.md) | 全平台 |
| 16 | **P0** | 机器没有闹钟，所有"每天自动跑"全是空话（healthcheck 已加,待运维） | [env-no-daemon-auto-not-closed-loop](2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md) | 全平台 |
| 19 | P1 | 经理不派活自己写代码，43 次 Bash 0 次 Task | [task-dispatch-not-isolated](2026-05-29-task-dispatch-not-isolated-fix.md) | omnivoice + hunyuan3d |
| 20 | P1 | 还没建 venv 就先 pip 装，装到全局污染环境了 | [fetch-before-install-pip-leak](2026-05-29-fetch-before-install-pip-leak-fix.md) | omnivoice |
| 17 | P1 | state.json 记的是 3 分钟前的进度，接手人看过期信息 | [state-snapshot-stale](2026-05-29-state-snapshot-stale-fix.md) | 全平台 |
| 18 | P1 | 只查"有声音够长"，不管声音对不对 | [verify-content-level-check](2026-05-29-verify-content-level-check-fix.md) | 全平台 |
| 21 | P1 | 同一个锤子买了 3 把，白占 40GB | [cache-isolation-boundary-level](2026-05-29-cache-isolation-boundary-level-fix.md) | 全平台 |
| 22 | P2 | 写着"修复 0 次"，实际修了 52 次 | [run-json-process-field-inaccurate](2026-05-29-run-json-process-field-inaccurate-fix.md) | omnivoice |
| 23 | P2 | 第一阶段的 poll 次数带到第二阶段了 | [poll-count-accumulate-cross-phase](2026-05-29-poll-count-accumulate-cross-phase-fix.md) | 全平台 |
| 24 | P2 | 该填时间的地方填了变量名 | [completed-at-literal-not-evaluated](2026-05-29-completed-at-literal-not-evaluated-fix.md) | hunyuan3d-2 |

---

## ✅ 已闭环（23 条 — 按时间倒序）

> 最近修的排最前，方便回溯。

| # | 级别 | 人话 | Fix 文件 | commit | 影响项目 |
|---|---|---|---|---|---|
| 36 | **P0** | 叫快递走侧门，侧门是堵墙：HF 全断网；门卡没批的仓库被放进流水线 | [no-proxy-pollution-gated-403](2026-06-10-no-proxy-pollution-gated-403-fix.md) | `f4c4355` | eagle |
| 35 | P1 | 监工动手干活了，该只看不动 | [monitor-role-discipline](2026-06-08-monitor-role-discipline-fix.md) | `<本次>` | magenta-realtime |
| 34 | P1 | 每次跑的草稿全堆公共筐，改成按项目分柜 | [run-dir-into-workspace](2026-06-08-run-dir-into-workspace-fix.md) | `864c3f3` | magenta-realtime |
| 26 | **P0** | 信投进隔壁信箱了，R1/R4/R6/R9 从上线起从未在正确目录生效 | [hook-runid-clobber](2026-06-02-hook-runid-clobber-fix.md) | `3bb1280` | controlfoley |
| 32 | P1 | 扫描到部署全链路从没真跑通过一次 | [scan-to-deploy-never-e2e-verified](2026-06-03-scan-to-deploy-never-e2e-verified-fix.md) | e2e 验证 | toonflow-app |
| 33 | P2 | 打扫只比划没真扫，完工章还盖错了 | [cleanup-no-real-cleanup-and-state-mismatch](2026-06-03-cleanup-no-real-cleanup-and-state-mismatch-fix.md) | toonflow-app e2e | controlfoley |
| 29 | P2 | 报表写免费实际是数据不可用；漏清了 weights | [runbook-cleanup-artifact-accuracy](2026-06-02-runbook-cleanup-artifact-accuracy-fix.md) | P6/P7 | hunyuan3d + omnivoice |
| 28 | P1 | 3 个人同时写同一目录，互相锁住 0 MB/s | [concurrent-download-zombie-guard](2026-06-02-concurrent-download-zombie-guard-fix.md) | `b0a97bf` | controlfoley |
| 27 | P1 | 新版命令改了，旧参数会报错 | [fetch-weights-hf1.x-modernization](2026-06-02-fetch-weights-hf1.x-modernization-fix.md) | `b0a97bf` | controlfoley |
| 25 | P1 | 交互式 session 产的 jsonl 被 cleanup 当垃圾拒了 | [g2-trace-format-flexible](2026-05-29-g2-trace-format-flexible-fix.md) | — | 全平台 |
| 14 | P1 | verify.json 字段不统一，定 6 个必填字段 | [verify-schema-enforcement](2026-05-27-verify-schema-enforcement-fix.md) | — | hunyuan3d + omnivoice |
| 13 | P1 | 设计文档怎么管：正文写结论，变更写附录 | [spec-plan-governance](2026-05-27-spec-plan-governance-fix.md) | — | 全平台 |
| 12 | P1 | 架构改善怎么记录：先写病历再改处方 | [fix-records-governance](2026-05-27-fix-records-governance-fix.md) | — | 全平台 |
| 11 | P1 | pip 缓存泄漏到系统目录（根因分析，修复归入 #20） | [cache-isolation-boundary](2026-05-27-cache-isolation-boundary-fix.md) | — | omnivoice |
| 10 | P1 | 给所有 SKILL.md 加了反模式 + hook 实时检测 | [v1.1-hardening](2026-05-26-v1.1-hardening-fix.md) | `43e453e` | songgen |
| 9 | P2 | runs/ 残留 22GB .cache，决定怎么清 | [runs-cache-cleanup-decision](2026-05-26-runs-cache-cleanup-decision-fix.md) | `42bdc5c` | songgen |
| 8 | P1 | L1 测试复盘 15 条：节编号/标题/废弃命令/PHASE_END/字段/路径全修 | [phase5-l1-retro-15-fixes](2026-05-26-phase5-l1-retro-15-fixes.md) | `42bdc5c` | songgen |
| 7 | P1 | L1 测试发现 SKILL 约束不够硬（归入 #8） | [phase5-l1-test-retro-fixes](2026-05-25-phase5-l1-test-retro-fixes.md) | — | songgen |
| 6 | P1 | RTX 5090 是 sm_12，旧 wheel 不含会编译失败 | [gpu-verify-protocol](2026-05-22-gpu-verify-protocol-fix.md) | — | 跨 3 项目 |
| 5 | P1 | 缺 torchcodec + repo 里有损坏 symlink | [song-generation-pipeline](2026-05-22-song-generation-pipeline-fix.md) | — | songgen |
| 4 | P1 | AI 反复 sleep 等进度，103 分钟白烧 $20 | [sleep-loop-discipline](2026-05-21-sleep-loop-discipline-fix.md) | `43e453e` | songgen |
| 3 | P1 | torch 版不对 / cuda 编不过 / flash-attn 编不过 | [baseline-3-blockers](2026-05-21-baseline-3-blockers-fix.md) | `8dbe1d5` | songgen |
| 2 | P1 | 经理亲自干活，还 kill 别人的进程 | [agent-isolation](2026-05-21-agent-isolation-fix.md) | `43e453e` | songgen |
| 1 | P1 | 定了"用 cron 定时跑"的整体设计 + R1-R9 | [cron-driven-architecture](2026-05-19-cron-driven-architecture-fix.md) | `84763ae` | 全平台 |

---

## 按影响域分组

### 🏗️ 全平台/架构级（影响所有项目）
- #1 cron-driven 架构定型 ✅
- #2 主 agent 隔离 ✅
- #4 R4 poll 预算 ✅
- #6 GPU 验证协议 ✅
- #9 runs cache 清理 ✅
- #10 v1.1 硬化 ✅
- #12 fix 记录管控 ✅
- #13 spec/plan 管控 ✅
- #15 交接机制断裂 ❌ P0
- #16 环境无 daemon ❌ P0
- #17 状态快照失真 ❌
- #18 verify 内容级检查 ❌
- #19 Task() 隔离未落地 ❌
- #21 缓存边界级 ❌
- #25 G2 trace 格式 ✅
- #32 scan→deploy 全链路 e2e ✅（toonflow-app 首次闭环）

### 🎵 song-generation
- #3 部署 3 大阻塞 ✅
- #5 torchcodec + symlink ✅
- #7 L1 测试（归入 #8）✅
- #8 L1 retro 15 条 ✅

### 🗣️ omnivoice
- #11 pip 缓存泄漏（根因分析）✅
- #20 fetch→install pip 泄漏 ❌
- #22 run.json 字段失真 ❌

### 🎬 controlfoley
- #26 hook run-id 覆盖 ✅ P0
- #27 hf 1.x 现代化 ✅
- #28 并发 download 锁竞争 ✅
- #29 runbook/cleanup artifact ✅
- #30 下载完整性校验 🟡（validator + committed 回归测试；待真实 GPU 权重下载 e2e）
- #31 R9 仍被绕过 🟡（hook + artifact gate 已写；根因 S-1 待 CC 平台，硬阻断已评估拒绝）
- #32 scan→deploy 全链路 ✅（toonflow-app e2e）
- #33 cleanup dry_run + 终态 ✅（toonflow-app e2e 真清 1.68GB + archived）

### 🧊 hunyuan3d-2
- #14 verify schema ✅
- #24 completed_at 字面量 ❌

---

## 优先修复建议

**P0（必须立即修）**:
1. #15 交接机制断裂 — 设计方案已有，待落地（MVP: SessionStart hook 自愈）
2. #16 环境无 daemon — 需运维层改动（装 cron / 启 supervisord）

**P1（本周应修）**:
3. #30 fetch-weights 下载完整性校验 — 🟡 validator + committed 回归测试已落地，待真实 GPU 权重下载 e2e
4. #31 R9 Task() 仍被绕过 — 🟡 hook + artifact gate 已落地（含回归测试）；根因 S-1 待 CC 平台支持
5. #19 Task() 隔离未落地 — 需先调研 --bare 下 Task() 行为
6. #20 fetch→install pip 泄漏 — 三种方案待选
7. #17 状态快照失真 — 与 #15 ① 自报终态是同一方案
8. #18 verify 内容级检查 — 需设计分级验证策略
9. #21 缓存边界级 — 方案待选（项目级 vs 全局共享）

**P2（记录但不急）**:
11. #22 run.json 字段失真
12. #23 poll_count 累加
13. #24 completed_at 字面量
