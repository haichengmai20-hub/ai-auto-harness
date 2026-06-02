# Fix 记录索引

> 治理规则见 `docs/superpowers/specs/2026-05-27-fix-records-governance.md`

## 索引

| # | Fix ID | 级别 | 状态 | 一句话 |
|---|--------|------|------|--------|
| 1 | [2026-05-19-cron-driven-architecture-fix](2026-05-19-cron-driven-architecture-fix.md) | P1 | ✅ 已闭环 | cron-driven 架构定型和 R1-R9 规则建立 |
| 2 | [2026-05-21-agent-isolation-fix](2026-05-21-agent-isolation-fix.md) | P1 | ✅ 已闭环 | 主 agent 越权亲自 bash,R9 违规 |
| 3 | [2026-05-21-baseline-3-blockers-fix](2026-05-21-baseline-3-blockers-fix.md) | P1 | ✅ 已闭环 | SongGen 部署 3 大阻塞:torch/cuda/flash-attn |
| 4 | [2026-05-21-sleep-loop-discipline-fix](2026-05-21-sleep-loop-discipline-fix.md) | P1 | ✅ 已闭环 | R4 poll 预算 / sleep-loop 纪律 |
| 5 | [2026-05-22-song-generation-pipeline-fix](2026-05-22-song-generation-pipeline-fix.md) | P1 | ✅ 已闭环 | SongGen:torchcodec 缺失 + symlink 损坏 |
| 6 | [2026-05-22-gpu-verify-protocol-fix](2026-05-22-gpu-verify-protocol-fix.md) | P1 | ✅ 已闭环 | GPU 架构验证协议(torch sm_120 标准化) |
| 7 | [2026-05-25-phase5-l1-test-retro-fixes](2026-05-25-phase5-l1-test-retro-fixes.md) | P1 | ✅ 已闭环 | Phase 5 L1 测试:SKILL.md 约束不够硬(归入 #9) |
| 8 | [2026-05-26-phase5-l1-retro-15-fixes](2026-05-26-phase5-l1-retro-15-fixes.md) | P1 | ✅ 已闭环 | Phase 5 L1 retro 15 条修复(节编号/Stage标题/deprecated命令/PHASE_END/dry_run字段/路径/freed_gib/不存在target) |
| 9 | [2026-05-26-runs-cache-cleanup-decision-fix](2026-05-26-runs-cache-cleanup-decision-fix.md) | P2 | ✅ 已闭环 | runs/.cache 残留清理决策 |
| 10 | [2026-05-26-v1.1-hardening-fix](2026-05-26-v1.1-hardening-fix.md) | P1 | ✅ 已闭环 | v1.1 硬化:SKILL.md 反模式 + hook 强化 |
| 11 | [2026-05-27-cache-isolation-boundary-fix](2026-05-27-cache-isolation-boundary-fix.md) | P1 | ✅ 已闭环 | OmniVoice pip 缓存泄漏到系统目录(根因分析,修复归入 #18) |
| 12 | [2026-05-27-fix-records-governance-fix](2026-05-27-fix-records-governance-fix.md) | P1 | ✅ 已闭环 | Fix 记录管控规则建立 |
| 13 | [2026-05-27-spec-plan-governance-fix](2026-05-27-spec-plan-governance-fix.md) | P1 | ✅ 已闭环 | Spec/Plan 管控规则建立 |
| 14 | [2026-05-27-verify-schema-enforcement-fix](2026-05-27-verify-schema-enforcement-fix.md) | P1 | ✅ 已闭环 | verify schema 强约束 |
| 15 | [2026-05-29-polling-handoff-mechanism-fix](2026-05-29-polling-handoff-mechanism-fix.md) | **P0** | ❌ 未落地 | **交接机制断裂(~18.7h 无人接棒)** |
| 16 | [2026-05-29-env-no-daemon-auto-not-closed-loop-fix](2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md) | **P0** | ❌ 未落地 | **环境无 cron/supervisord/init,自动化从未闭环** |
| 17 | [2026-05-29-state-snapshot-stale-fix](2026-05-29-state-snapshot-stale-fix.md) | P1 | ❌ 未落地 | 状态快照失真(paused 快照由即将退出的 agent 拍) |
| 18 | [2026-05-29-verify-content-level-check-fix](2026-05-29-verify-content-level-check-fix.md) | P1 | ❌ 未落地 | verify 只验响度/时长,不验内容 |
| 19 | [2026-05-29-task-dispatch-not-isolated-fix](2026-05-29-task-dispatch-not-isolated-fix.md) | P1 | ❌ 未落地 | LLM 内联执行所有阶段(task_called=0) |
| 20 | [2026-05-29-fetch-before-install-pip-leak-fix](2026-05-29-fetch-before-install-pip-leak-fix.md) | P1 | ❌ 未落地 | fetch 先于 install 导致系统级 pip 泄漏 |
| 21 | [2026-05-29-cache-isolation-boundary-level-fix](2026-05-29-cache-isolation-boundary-level-fix.md) | P1 | ❌ 未落地 | 缓存隔离边界应从 run 级改到项目级/共享 |
| 22 | [2026-05-29-run-json-process-field-inaccurate-fix](2026-05-29-run-json-process-field-inaccurate-fix.md) | P2 | ❌ 未落地 | run.json 过程字段失真(标称 0 修复 vs 实际有修复) |
| 23 | [2026-05-29-poll-count-accumulate-cross-phase-fix](2026-05-29-poll-count-accumulate-cross-phase-fix.md) | P2 | ❌ 未落地 | poll_count 跨阶段累加超限 |
| 24 | [2026-05-29-completed-at-literal-not-evaluated-fix](2026-05-29-completed-at-literal-not-evaluated-fix.md) | P2 | ❌ 未落地 | completed_at 字段是未求值的 shell 字面量 |
| 25 | [2026-05-29-g2-trace-format-flexible-fix](2026-05-29-g2-trace-format-flexible-fix.md) | P1 | ✅ 已闭环 | G2 trace 检查只认 ndjson,交互式 session 产 jsonl 被误拒 |
| 26 | [2026-06-02-hook-runid-clobber-fix](2026-06-02-hook-runid-clobber-fix.md) | **P0** | ✅ 已闭环 | **SessionStart 覆盖 run-id → hook 写孤儿目录,R1/R4/R6/R9 实时约束自上线起从未在正确目录生效**(ControlFoley e2e) |
| 27 | [2026-06-02-fetch-weights-hf1.x-modernization-fix](2026-06-02-fetch-weights-hf1.x-modernization-fix.md) | P1 | ✅ 已闭环 | hf 1.x:去 `--resume-download`(已移除)+ `HF_HUB_ENABLE_HF_TRANSFER`→Xet |
| 28 | [2026-06-02-concurrent-download-zombie-guard-fix](2026-06-02-concurrent-download-zombie-guard-fix.md) | P1 | ✅ 已闭环 | 并发 hf download 锁竞争(0 MB/s)加 pgrep 防护 + 僵尸 hf 保守审计 |
| 29 | [2026-06-02-runbook-cleanup-artifact-accuracy-fix](2026-06-02-runbook-cleanup-artifact-accuracy-fix.md) | P2 | ✅ 已闭环 | runbook cost=0.0/duration 失真 + cleanup weights 白名单泄漏 |

## 统计

- 总计:29 条
- ✅ 已闭环:19 条
- ❌ 未落地:10 条
- P0:3 条(2 未落地 + 1 已闭环 [#26])
- P1:20 条(17 已闭环 + 3 未落地)
- P2:6 条(3 已闭环 + 3 未落地)

## 按项目分组

### 跨项目/平台级
- #1 cron-driven 架构
- #2 主 agent 隔离
- #4 R4 poll 预算
- #6 GPU 验证协议(跨 3 项目)
- #9 runs cache 清理
- #10 v1.1 硬化
- #12 fix 记录管控
- #13 spec/plan 管控
- #15 交接机制断裂
- #16 环境无 daemon
- #17 状态快照失真
- #18 verify 内容级检查
- #19 Task() 隔离未落地
- #21 缓存边界级
- #23 poll_count 累加

### song-generation
- #3 部署 3 大阻塞
- #5 torchcodec + symlink
- #7 L1 测试(归入 #8)
- #8 L1 retro 15 条修复

### omnivoice
- #11 pip 缓存泄漏(根因分析)
- #20 fetch→install pip 泄漏
- #22 run.json 字段失真

### hunyuan3d-2
- #14 verify schema
- #24 completed_at 字面量
- #25 G2 trace 格式兼容

## 优先修复建议

**P0(必须立即修)**:
1. #15 交接机制断裂 — 设计方案已有,待落地(MVP:SessionStart hook 自愈)
2. #16 环境无 daemon — 需运维层改动(装 cron / 启 supervisord)

**P1(本周应修)**:
3. #19 Task() 隔离未落地 — 需先调研 --bare 下 Task() 行为
4. #20 fetch→install pip 泄漏 — 三种方案待选
5. #17 状态快照失真 — 与 #15 ① 自报终态是同一方案
6. #18 verify 内容级检查 — 需设计分级验证策略
7. #21 缓存边界级 — 方案待选(项目级 vs 全局共享)
