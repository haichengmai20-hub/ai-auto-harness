# Phase 5 L1 测试发现的问题 — runbook-agent / cleanup-agent 初版 SKILL.md 缺陷

## 元信息

- **Fix ID**: `2026-05-25-phase5-l1-test-retro-fixes`
- **创建日期**: 2026-05-25(回填于 2026-05-29)
- **级别**: P1(Phase 5 新功能阻塞性问题)
- **状态**: 已闭环(大部分修复归入 2026-05-26-phase5-l1-retro-15-fixes.md)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：Phase 5 的 L1 测试跑出了 SKILL.md 约束不够硬的问题，归入了统一修复。

**打比方**：像验收房子发现 15 个问题，先列清单再统一修。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(L1 测试用项目) |
| **触发 run_id** | L1 测试 run |
| **触发时间** | 2026-05-25 |
| **触发阶段** | runbook-agent / cleanup-agent(L1 测试阶段) |
| **workspace 路径** | `workspace/song-generation/` |
| **runs 路径** | L1 测试 runs |

---

## 现象

- 现象 1: runbook-agent 产出的 runbook 节编号与模板不一致,validate-runbook.sh 靠 `^## N\.` 抓节,错号导致验收脚本误判
- 现象 2: Stage 标题自由发挥/错字(如"腅环境")
- 现象 3: cleanup-agent 漏写 PHASE_END 到日志
- 现象 4: cleanup-agent dry_run 字段混用(removed vs would_remove)

---

## 触发条件 / 复现步骤

1. 运行 Phase 5 L1 测试
2. runbook-agent / cleanup-agent 执行
3. SKILL.md 规则不够硬,LLM 自由发挥

---

## 影响

- **影响范围**: Phase 5 新功能质量
- **影响下游**: validate 脚本误判;runbook 消费者拿到不规范的文档
- **严重程度**: P1 — 阻塞 L1 测试通过

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > SKILL.md 约束不够硬,LLM 自由发挥。节编号、Stage 标题、PHASE_END 日志、dry_run 字段等都需要硬约束 + 反模式列表。

---

## 修复方案

> 修复已归入更详细的 [2026-05-26-phase5-l1-retro-15-fixes.md](2026-05-26-phase5-l1-retro-15-fixes.md)(15 条修复清单)。

---

## 验证步骤

1. 见 [2026-05-26-phase5-l1-retro-15-fixes.md](2026-05-26-phase5-l1-retro-15-fixes.md) 验证步骤
2. 摘要:`bash scripts/validate-runbook.sh <runbook> <runbook.json>` + `bash scripts/validate-cleanup.sh <workspace> dry_run`

---

## 修复结果

- **状态**: ✅ 已闭环(归入 2026-05-26-phase5-l1-retro-15-fixes.md)
- **验证证据**: L1 测试通过
- **commit hash**: 见关联 fix

---

## 证据指针

- 相关 SKILL: `.claude/skills/runbook-agent/SKILL.md`、`.claude/skills/cleanup-deployed-workspace/SKILL.md`

---

## 关联

- **关联 fix**: [2026-05-26-phase5-l1-retro-15-fixes.md](2026-05-26-phase5-l1-retro-15-fixes.md)(完整修复清单)
- **关联 fix**: [2026-05-26-v1.1-hardening-fix.md](2026-05-26-v1.1-hardening-fix.md)(SKILL.md 硬化)

---

## 后续动作

- [x] 修复归入关联 fix
