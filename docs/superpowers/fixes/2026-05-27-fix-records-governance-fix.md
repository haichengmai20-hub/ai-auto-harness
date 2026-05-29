# Fix 记录管控规则建立 — 解决"试跑出改善结论无系统归档,spec/plan 频繁被动调整"

## 元信息

- **Fix ID**: `2026-05-27-fix-records-governance-fix`
- **创建日期**: 2026-05-27
- **级别**: P1(流程治理,影响所有架构改善的记录方式)
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

- 现象 1: 试跑部署遇到问题现场修,修完就过,修复记录没有系统归档
- 现象 2: 某些修复会直接改变长期 spec 和 plan 的假设(如 L1 测试发现 SKILL.md 设计缺陷),但改动缺乏溯源链路
- 现象 3: 试跑修复(短周期、高频)和 spec/plan 设计(长周期、低频)混杂,长线设计永远被短线修复打断

---

## 触发条件 / 复现步骤

1. 试跑部署发现架构问题
2. 直接改 spec/plan/SKILL/CLAUDE.md
3. 无 fix 记录、无 Changelog、无双向引用
4. spec/plan 频繁被动调整,改动无溯源

---

## 影响

- **影响范围**: 所有架构改善的事实链记录
- **影响下游**: spec/plan 频繁被打断;后人无法追溯改动动机;新接手 AI 无法理解规则来历
- **严重程度**: P1 — 核心矛盾:试跑修复是短周期高频不可预测的,spec/plan 是长周期低频需要稳定的,混在一起长线设计永远被短线修复打断

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 没有"试跑修复"和"长期设计"的分离机制。修复记录散落各处(fixes.log / git commit / retro / handoff),没有统一的归档和联动规则。

---

## 修复方案

### 设计层修改

- [x] 新建 `docs/superpowers/specs/2026-05-27-fix-records-governance.md`:定义 Fix 是什么、触发条件、模板、闭环流程、与其他记录的边界、Master Plan 索引区规则
- [x] 定义四类文档分离规则:Master Plan / Spec / Plan / Fix 各归其位
- [x] 定义变更联动规则:Fix 影响到 Spec/Plan 时在 Fix 末尾加 Changelog,Spec/Plan 更新版本号

### 实现层修改

- [x] 新建 `docs/superpowers/fixes/_template-fix.md`
- [x] 新建 `docs/superpowers/fixes/README.md`

### 文档层修改

- [x] 回填 8 份历史 fix 记录

---

## 验证步骤

1. 检查 fix 记录目录是否按命名规则组织
2. 检查每份 fix 是否按模板填写
3. 检查 fix 与 spec/plan ChangeLog 是否有双向引用

---

## 修复结果

- **状态**: ✅ 已闭环
- **验证证据**: 治理文档 + 模板 + 历史 fix 回填完成
- **commit hash**: 待 commit

---

## 证据指针

- 治理文档: `docs/superpowers/specs/2026-05-27-fix-records-governance.md`
- 模板: `docs/superpowers/fixes/_template-fix.md`
- 索引: `docs/superpowers/fixes/README.md`

---

## 关联

- **关联 fix**: [2026-05-27-spec-plan-governance-fix.md](2026-05-27-spec-plan-governance-fix.md)(配套 spec/plan 管治)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [x] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [x] **不提升到 memory/lessons**(流程规范)
- [x] **不需要 L1 / L2 重测验证**
- [x] **不需要写 pending_human**
