# ai-auto-harness 文档治理索引

> 本文件为项目全部 Spec / Plan / Fix / Retro / Handoff 的完整索引，供 Claude Code 审阅。

---

## 文档规模

| 分类 | 份数 | 总行数 | 大小 |
|------|------|--------|------|
| Spec | 8 | 3,748 | 172 KB |
| Plan | 14 | 7,414 | 252 KB |
| Fix | 45 | 6,185 | 268 KB |
| Retro | 1 | 299 | 14 KB |
| Handoff | 1 | 195 | 10 KB |
| **Master Plan** | 1 | 302 | - |
| **SKILL.md** | 1 | 648 | - |
| **合计** | **70** | **~18K** | **~716 KB** |

---

## SPECS (8 份 — 设计规范)

| # | 文件 | 标题 | 状态 |
|---|------|------|------|
| S1 | 2026-05-19-ai-auto-harness-design.md | 项目整体设计 | 设计已完成,开发已完成 |
| S2 | 2026-05-25-runbook-and-cleanup-addendum.md | Runbook + Cleanup 增补设计 | - |
| S3 | 2026-05-27-fix-records-governance.md | Fix 记录治理规范 | - |
| S4 | 2026-05-27-spec-plan-governance.md | Spec/Plan 治理规范 | - |
| S5 | 2026-06-10-r-rules-reference.md | R1-R10 硬规则参考 | - |
| S6 | 2026-06-11-cron-resume-and-optimization.md | Cron 续跑与优化设计 | 设计稿 |
| S7 | 2026-06-11-试跑复盘与验证清单.md | 试跑复盘与验证清单 | - |
| S8 | 2026-06-16-service-type-inference-design.md | 服务型推理设计 | - |

## PLANS (14 份 — 实施计划)

| # | 文件 | 标题 | 状态 |
|---|------|------|------|
| P0 | 2026-ai-auto-harness-master.md | **Master Plan** (全局活索引) | 持续更新 |
| P1 | 2026-05-19-ai-auto-harness-implementation.md | 总实施计划 | - |
| P2 | 2026-05-19-phase--1-preflight-risk.md | Phase -1: Preflight 风险 | ✅ 已完成 |
| P3 | 2026-05-19-phase-0-ai-daily-scan-mcp.md | Phase 0: MCP 接通 | ✅ 已完成 |
| P4 | 2026-05-19-phase-1-harness-skeleton-intake.md | Phase 1: 骨架+Intake | ✅ 已完成 |
| P5 | 2026-05-19-phase-2-fetch-install-run.md | Phase 2: Fetch+Install+Run | ✅ 已完成 |
| P6 | 2026-05-19-phase-3-verify-report-human.md | Phase 3: Verify+Report+Human | ✅ 已完成 |
| P7 | 2026-05-19-phase-4-docs-migration.md | Phase 4: 文档迁移 | ✅ 已完成 |
| P8 | 2026-05-25-phase-5-runbook-and-cleanup.md | Phase 5: Runbook+Cleanup | - |
| P9 | 2026-05-25-phase-5-task-3-and-4-l1-test-prompt.md | Phase 5 任务 3-4 L1 测试 | - |
| P10 | 2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md | Phase 5 P4-5 Cleanup+Guards | - |
| P11 | 2026-05-26-roledrop-judge-pilot.md | RoleDrop Judge 试点 | - |
| P12 | 2026-06-03-scan-to-deploy-e2e-l1-test-prompt.md | Scan-to-Deploy E2E L1 测试 | - |
| P13 | 2026-06-16-service-type-inference.md | 服务型推理实施计划 | - |

## FIXES (45 份 — 架构改善事实链)

### ✅ 已闭环 (42 份)

| Fix ID | 日期 | 级别 | 一句话 | 闭环方式 |
|--------|------|------|--------|----------|
| 001 | 05-19 | P0 | 定下了"用 cron 定时驱动自动部署"的整体架构，和 R1-R9 九条硬规则 | CC时代实现 |
| 002 | 05-21 | P0 | 主 agent 亲自跑 bash 干 SubAgent 的活 | CC时代实现 |
| 003 | 05-21 | P0 | SongGen 跑不通:torch/cuda/flash-attn | CC时代实现 |
| 004 | 05-21 | P0 | AI 反复 sleep 等进度,103min里 sleep 占97% | CC时代实现 |
| 005 | 05-22 | P1 | RTX 5090 sm_12 架构 wheel 编译失败 | CC时代实现 |
| 006 | 05-22 | P1 | SongGen 缺 torchcodec + repo 里损坏的 symlink | CC时代实现 |
| 007 | 05-25 | P1 | Phase 5 L1 测试 SKILL.md 约束不够硬 | 归入026 |
| 008 | 05-26 | P0 | L1 测试复盘一口气修 15 个问题 | CC时代实现(14/15) |
| 009 | 05-26 | P1 | runs/ 目录下残留 22GB 的 .cache | CC时代实现 |
| 010 | 05-26 | P0 | 所有 SKILL.md 加反模式段 + PostToolUse hook | CC时代实现 |
| 011 | 05-27 | P1 | pip 缓存泄漏到系统级 Python | 归入018 |
| 012 | 05-27 | P1 | 定了"先写 fix.md 再改 spec/SKILL"的规则 | CC时代实现 |
| 013 | 05-27 | P1 | 定了"正文只写结论不写历史"的规则 | CC时代实现 |
| 014 | 05-27 | P1 | verify.json 字段名不统一,需 6 字段强约束 | CC时代实现 |
| 015 | 05-29 | P1 | 每次 run 独立缓存,torch 2GB wheel 下3遍存3份 | 方案A:边界改项目级 |
| 016 | 05-29 | P2 | completed_at 写字面量而非实际时间 | CC时代实现 |
| 017 | 05-29 | P0 | 没 cron/supervisord,"每天自动跑"全是空话 | cron已装 |
| 018 | 05-29 | P1 | 还没建 venv 就先装 huggingface_hub | 方案B+C双保险 |
| 019 | 05-29 | P1 | verify 只认 ndjson 格式,交互式 session 产 jsonl 被误拒 | CC时代实现 |
| 020 | 05-29 | P2 | 第一阶段 poll 次数带到第二阶段 | CC时代实现 |
| 021 | 05-29 | P0 | 权重下完了没人知道该装环境,等了18.7小时 | MVP档:handoff sentinel |
| 022 | 05-29 | P2 | 写着"修复0次"实际有修复 | 规范层实现 |
| 023 | 05-29 | P1 | state.json 记3分钟前的进度而非现在的 | CC时代实现 |
| 024 | 05-29 | P1 | 主 agent 自己干所有活,没分给5个小 agent | 归入032 |
| 025 | 05-29 | P1 | 只检查"有声音"不管对不对 | 规范层实现 |
| 026 | 06-02 | P1 | 3个 hf download 进程同时写同一目录 | CC时代实现 |
| 027 | 06-02 | P1 | 新版 hf CLI 移除 --resume-download flag | CC时代实现 |
| 028 | 06-02 | P0 | SessionStart hook 覆盖了 run-id | CC时代实现 |
| 029 | 06-02 | P2 | runbook cost=0.0 实际不可用 | CC时代实现 |
| 030 | 06-03 | P2 | 打扫只做了比划没真扫 | toonflow e2e验证 |
| 031 | 06-03 | P1 | 下载完文件不检查大小,坏文件当好的用 | **Hermes版:HF API校验+.incomplete检测** |
| 032 | 06-03 | P1 | 165次Bash 0次Task,报告都没按格式写 | **Hermes迁移天然解决** |
| 033 | 06-03 | P1 | "选品"环节从来没真正跑过 | CC时代实现 |
| 034 | 06-08 | P1 | 下载路径没传给工人,工人自己瞎猜 | **Hermes迁移天然解决** |
| 035 | 06-08 | P1 | monitor 角色,记录不干预 | CC时代实现 |
| 036 | 06-08 | P1 | 下载被公司代理拦住报503 | **Hermes版:unset proxy+no_proxy** |
| 037 | 06-08 | P1 | runs/ 目录迁移到 workspace 内 | CC时代实现 |
| 038 | 06-09 | P2 | git submodule未初始化+权重路径对不上 | **Hermes版:submodule init+路径映射** |
| 039 | 06-10 | P2 | CLAUDE.md从23页压成1页 | CC时代实现 |
| 040 | 06-10 | P0+P1 | sentinel 僵尸对账 + R3 兜底 + runs 清理 | **Hermes版:+timeout 120min** |
| 041 | 06-10 | P0+P1 | no_proxy 污染导致 gated 403 | CC时代实现 |
| 042 | 06-11 | P1 | 4颗螺丝拧错孔+3条新规矩贴在看不到的墙上 | CC时代实现 |
| 043 | 06-12 | P1 | 续跑假退出:后台下载空转4次run | **Hermes迁移天然解决** |
| 044 | 06-16 | P0 | F9 错误分类自动修复会毁 entry_script | **Hermes版:Python heredoc替代sed** |

### 🟡 部分落地 (3 份)

| Fix ID | 日期 | 级别 | 一句话 | 缺口 |
|--------|------|------|--------|------|
| 045 | 06-16 | P2 | CC 快赢批 #2: H3/F7/F8/F10 | CC版SKILL.md已改,实战验证待做 |
| 046 | 06-16 | P1 | CC版同步 Q4/Q5/F2/F9 安全集 | 安全集已同步,F9仅加红线未加修复 |
| 047 | 06-16 | P0 | 服务型推理支持(entry_type=service) | 设计+SKILL已完成,实战L1验证待做 |

---

## 治理纪律 (D1-D7)

| 规则 | 大白话 | 说明 |
|------|--------|------|
| **D1** Fix→Spec 先后顺序 | 先写病历再改处方 | 不许跳过fix直接改spec/SKILL |
| **D2** ChangeLog 条目 | 改了什么必须留记录 | 被改文件末尾追加,引fix路径 |
| **D3** 正文只写结论 | 法律只写现行规定 | 历史变更写ChangeLog,不残留"以前是..." |
| **D4** Fix命名与唯一性 | 一个病一份病历 | 同一topic只一份fix |
| **D5** 经验库自动增长 | 踩过的坑所有人能查 | 多项目复现的fix提升到memory/lessons/ |
| **D6** 新Skill创建义务 | 新建工具必须有说明书 | SKILL.md既是LLM指令也是人的文档 |
| **D7** Git commit纪律 | commit写清楚改了什么 | `[fix] <topic>: <一句话>` |

## Fix 闭环流程

```
试跑出问题
  → ① 写 fix.md (按_template-fix.md格式)
  → ② 改 spec/SKILL/phase脚本
  → ③ 加 ChangeLog (引fix路径)
  → ④ 验证 (bash -n + e2e)
  → ⑤ 回填 fix 修复结果段
  → ⑥ git commit
  → ⑦ 更新 Master Plan 索引
```

## 跨项目数据流

```
ai-daily-scan                         ai-auto-harness
├── config/company_profile.jsonl      ├── hermes/scripts/phase-*.sh (7个)
├── state/findings.jsonl ─────────→   ├── AGENTS.md (Hermes入口)
│                                     ├── CLAUDE.md (CC入口)
├── state/outcomes.jsonl ←────────    ├── docs/superpowers/ (spec/plan/fix)
│   record_outcome                    ├── memory/lessons/ (经验库)
└── output/ 日报                       ├── workspace/<slug>/ (项目隔离)
                                      └── reports/ (部署报告)
```

## Claude Code 审阅指引

请重点检查以下方面:

1. **Spec 与 Fix 的一致性**: Spec 正文是否反映了 Fix 的修改?有没有 Fix 已闭环但 Spec 未更新的?
2. **Plan 与 Fix 的引用**: 每个 Fix 是否被 Master Plan 索引?有没有孤立的 Fix?
3. **Fix 闭环证据的充分性**: 标记"已闭环"的 Fix 是否有足够验证证据?有没有只改了 SKILL.md 没测的?
4. **部分落地 Fix 的缺口**: 3个部分落地 Fix 的缺口是否需要补?优先级?
5. **R 规则覆盖度**: R1-R10 是否在最新 phase 脚本中都有对应实现?
6. **服务型推理(047)**: 设计是否完善?有无遗漏场景?

文件位置: /root/ai-auto-harness/docs/superpowers/
