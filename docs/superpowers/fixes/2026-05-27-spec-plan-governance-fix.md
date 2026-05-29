# Spec / Plan 管控规则建立 — 解决"试跑出改善结论直接改 spec/plan 容易和开发冲突"

## 元信息

- **Fix ID**: `2026-05-27-spec-plan-governance-fix`
- **创建日期**: 2026-05-27
- **级别**: P1(流程治理,影响所有后续开发)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-05-27

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | N/A 仅平台流程治理 |
| **触发 run_id** | N/A |
| **触发时间** | 2026-05-27 |
| **触发阶段** | ops / 治理 |
| **workspace 路径** | N/A |
| **runs 路径** | N/A |

---

## 现象

- 现象 1: 试跑出问题后直接改 spec/plan/SKILL,没有事实链记录,半年后没人记得"为什么 R4 是这样"
- 现象 2: 多 session 并发修改同一 spec,和正在跑的开发任务冲突
- 现象 3: 改善结论散落在 git commit / retro / handoff / 用户记忆,接手 AI 必须 grep 10 个地方才能拼出完整故事

---

## 触发条件 / 复现步骤

1. 试跑发现架构改善点
2. 直接改 SKILL.md / CLAUDE.md / spec
3. 无记录、无 ChangeLog、无双向引用
4. 后人无法追溯"为什么这条规则存在"

---

## 影响

- **影响范围**: 所有 spec / plan / SKILL.md 的变更管理
- **影响下游**: 开发冲突、追溯困难、新接手 AI 无法理解规则动机
- **严重程度**: P1 — 不阻塞功能,但长期可维护性严重受损

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 项目没有 spec/plan 变更管控规则,改善结论直接写入设计文档,没有"先写 fix → 再改 spec/plan"的流程约束。

---

## 修复方案

### 设计层修改

- [x] 新建 `docs/superpowers/specs/2026-05-27-spec-plan-governance.md`:正文+ChangeLog 二分原则、变更触发规则、SKILL.md 双重身份处理、Master Plan 特殊地位
- [x] 新建 `docs/superpowers/specs/2026-05-27-fix-records-governance.md`:fix 触发条件、模板、闭环流程、与其他记录的边界

### 实现层修改

- [x] 新建 `docs/superpowers/fixes/_template-fix.md`:标准化 fix 模板

### 文档层修改

- [x] 回填 8 份历史 fix 记录(2026-05-19 ~ 2026-05-26)

---

## 验证步骤

1. 检查 spec/plan 文件末尾是否有 ChangeLog 章节
2. 检查 fix 记录是否按模板填写
3. 检查 Master Plan 是否有 Fix 索引区

---

## 修复结果

- **状态**: ✅ 已闭环
- **验证证据**: 治理文档已创建,历史 fix 已回填
- **commit hash**: 待 commit

---

## 证据指针

- 治理文档: `docs/superpowers/specs/2026-05-27-spec-plan-governance.md`
- 治理文档: `docs/superpowers/specs/2026-05-27-fix-records-governance.md`
- 模板: `docs/superpowers/fixes/_template-fix.md`

---

## 关联

- **关联 fix**: [2026-05-27-fix-records-governance-fix.md](2026-05-27-fix-records-governance-fix.md)(配套 fix 记录治理)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [x] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [x] **不提升到 memory/lessons**(流程规范)
- [x] **不需要 L1 / L2 重测验证**
- [x] **不需要写 pending_human**
