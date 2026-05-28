# Spec / Plan 管控设计 — 2026-05-27

> ai-auto-harness 项目的设计文档 (spec) 和实施计划 (plan) 的**管理规则**。
> 配套文档:[fix-records-governance.md](2026-05-27-fix-records-governance.md)(fix 记录管理)。
> 总入口:[../plans/2026-05-19-ai-auto-harness-master.md](../plans/2026-05-19-ai-auto-harness-master.md)

---

## 1. 目的

定义 ai-auto-harness 项目中所有 spec / plan 文件的**生命周期与变更纪律**,解决以下问题:

- ❌ **痛点**:试跑出问题或讨论出改善点后,直接改 spec/plan/SKILL,**没有事实链**记录,导致后续追溯不了"为什么这条规则存在"。
- ❌ **痛点**:开发期间多人/多 session 并行改 spec,**冲突隐性化** — 谁改了什么,基于什么动机,看不出来。
- ❌ **痛点**:spec 越改越长,**结论 + 历史变更混在一起**,新读者抓不到当前真相。

---

## 2. 文件分类与位置

| 类型 | 位置 | 性质 |
|---|---|---|
| **Spec** | `docs/superpowers/specs/*.md` | **设计文档** — 正文只保留最新结论。每个独立设计/架构决策一份 |
| **Plan(主索引)** | `docs/superpowers/plans/2026-05-19-ai-auto-harness-master.md` | **全局活索引** — 当前状态 / 全局索引 / 待办 / 里程碑 |
| **Plan(分阶段)** | `docs/superpowers/plans/2026-05-19-phase-*.md` 等 | **phase 级实施计划** — checkbox 跟踪 task 完成度 |
| **CLAUDE.md** | `.claude/CLAUDE.md` / 根 `CLAUDE.md` | **高层运行时 spec** — R1-R9 硬规则,凌驾各 SKILL.md |
| **SubAgent SKILL** | `.claude/skills/*/SKILL.md` | **双重身份**:既是 spec 又是 implementation(LLM 通过读 SKILL 直接执行) |
| **SKILL 模板** | `.claude/skills/*/_template.md` | **填空骨架** — 配 SKILL.md 使用 |

---

## 3. 正文 + ChangeLog 二分原则

### 3.1 正文(永远是最新结论)

- 不写历史:之前是什么样、改过几次 — 都不写
- 不写动机:为什么这么定 — 不写(或一句话带过)
- 只写结论:**当下应该这么做**

### 3.2 ChangeLog(末尾追加,只写摘要 + 证据指针)

每个 spec / plan / CLAUDE.md / SKILL.md 文件末尾**统一**加 `## ChangeLog` 章节,变更时追加一行条目:

```markdown
## ChangeLog

- **YYYY-MM-DD** — <变更摘要,一句话>
  - 变更类型: 规则 / 流程 / 阈值 / 结构 / 约束 / schema / 反模式
  - 影响范围: <章节 / 字段名 / 反模式条目>
  - 动机: <为何修改,简短>
  - 证据: <fixes/...md 路径>
  - 验证: 已验证 / 待验证(含验证方式,如 `bash scripts/validate-*.sh`)
```

**关键约束**:
- ✅ 摘要 + 证据指针,**不复制 fix 细节**(fix 细节在 `docs/superpowers/fixes/<date>-<topic>-fix.md`)
- ✅ 每条变更都要有 fix 证据指针(若变更没有 fix → 该变更很可能没必要)
- ❌ 不允许"我改了规则但不记 ChangeLog"

### 3.3 触发规则(什么时候必须加 ChangeLog 条目)

| 文件类型 | 加 ChangeLog 的触发条件 | 不加 ChangeLog 的情况 |
|---|---|---|
| `specs/*.md` | 任何正文修改 | 排版/错字修正 |
| `plans/*.md` 主索引 | 状态字段变化、待办/里程碑增减 | 单次工作的进度勾选 |
| `plans/2026-05-19-phase-*.md` | checkbox 完成时不必,但 plan 结构性改动必加 | checkbox 勾选 |
| `CLAUDE.md` (R1-R9) | 任何 R 规则增减 / 阈值改 / 表述实质性改 | 错字 / 重新排版 |
| `SKILL.md` | **由 fix 驱动的改动**(改 schema / 字段名 / 硬约束 / 反模式) | 开发期初始实现 / 改错字 / 加示例(走 git commit message 即可) |

**SKILL.md 判定标准**:
> 这次改 SKILL.md 是不是因为某个 fix.md(架构改善)触发的?
> - **是** → SKILL.md 末尾加 ChangeLog 条目,引 fix 路径
> - **否** → 直接 git commit,commit message 写明 `[skill] <slug>: <改动一句话>`

---

## 4. 命名与生命周期

### 4.1 命名规则

| 类型 | 命名 | 例 |
|---|---|---|
| Spec(主设计) | `<YYYY-MM-DD>-<topic>.md` | `2026-05-19-ai-auto-harness-design.md` |
| Spec(增量 / addendum) | `<YYYY-MM-DD>-<topic>-addendum.md` | `2026-05-25-runbook-and-cleanup-addendum.md` |
| Spec(治理 / governance) | `<YYYY-MM-DD>-<topic>-governance.md` | `2026-05-27-spec-plan-governance.md` |
| Plan(主索引) | `<YYYY-MM-DD>-ai-auto-harness-master.md`(唯一) | 同 |
| Plan(分 phase) | `<YYYY-MM-DD>-phase-<N>-<topic>.md` | `2026-05-25-phase-5-runbook-and-cleanup.md` |
| Plan(测试 prompt) | `<YYYY-MM-DD>-phase-<N>-<purpose>-prompt.md` | `2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md` |

### 4.2 生命周期

```
                   ┌─ 增量/演进 ──→ addendum spec(引原 spec 不动正文)
                   │
[Spec 立项] ───────┤
                   └─ 颠覆性改 ──→ 改正文 + ChangeLog(同一文件累积)

[Plan 立项] ─→ phase plan(checkbox)─→ phase 完成 ─→ 状态留档 + retro
                                                         │
[Master Plan] ────────────────────────── 永远活索引(每 session 更新)
```

**关键纪律**:
- ❌ **不要**为同一主题写第二份 spec(造成"哪份是真"困惑)
- ✅ **要**用 addendum 增量,或改原 spec 正文(并加 ChangeLog 标志结论变了)
- ❌ **不要**在 spec 正文里保留"过时但有故事的旧版本"
- ✅ **要**把旧版本细节写进 fix 记录,正文只保留最新

---

## 5. SubAgent SKILL.md 的特殊处理(双重身份)

SubAgent SKILL.md 既是 spec(规则)又是 implementation(LLM 通过读它执行),与传统 spec/code 分离不同。

### 5.1 改动类别(决定走什么流程)

| 改动类别 | 例 | 流程 |
|---|---|---|
| **A. 改 schema / 字段名** | verify.json 加 `failed_at` 字段 | **加 ChangeLog**(影响下游消费者) |
| **B. 改硬约束 / 阈值** | "Stage 2 必须用 hf" "passed 必须 boolean" | **加 ChangeLog** |
| **C. 加反模式条目** | ❌ "huggingface-cli 不许写" | **加 ChangeLog**(fix 驱动) |
| **D. 改文字表达 / 排版** | 改 "执行" → "运行" | 不加 ChangeLog,git commit 即可 |
| **E. 加示例** | 多加一个 trap 4 字段示例 | 不加 ChangeLog |
| **F. 错字** | "腅环境" → "装环境"(但 hardcode 在模板) | 不加 ChangeLog(走 git commit) |

### 5.2 ChangeLog 在 SKILL.md 里的位置

`SKILL.md` 末尾 + frontmatter 不动。例:

```markdown
---
name: write-deploy-runbook
description: ...
---

# write-deploy-runbook

[正文 ...]

## ChangeLog

- **2026-05-27** — Stage 2 命令强制 `hf download`,反模式加 R7 违反扫描
  - 变更类型: 反模式 + schema 约束
  - 影响范围: 第 3 步抽取表 / 第 7 步敏感扫描 / 反模式段
  - 动机: L1 实测产出 runbook 含 4 处 `huggingface-cli download`
  - 证据: [fixes/2026-05-26-runbook-deprecated-cmds-fix.md](../../../docs/superpowers/fixes/2026-05-26-runbook-deprecated-cmds-fix.md)
  - 验证: `bash scripts/validate-runbook.sh <runbook> <runbook.json>` V7 通过
```

---

## 6. Master Plan 的特殊地位

Master Plan(`plans/2026-05-19-ai-auto-harness-master.md`)是**全局活索引**,与其他 plan 不同:

- **每次工作结束必更新**(不是触发式)
- **包含 3 类索引**:当前生效 spec / 当前生效 plan / fix 记录索引
- **包含运行时状态**:当前版本 / 一句话 / 真实战绩 / 风险 / 下一步候选
- **不写细节**:所有细节链接到对应 spec / plan / fix

具体结构见 master plan 本体的开头几节。

---

## 7. 实际操作流程(给 future Claude / 接手 AI)

### 7.1 当你试跑出问题或讨论出改善点时

1. **先写 fix.md**(不直接改 spec/plan!)
   - 位置: `docs/superpowers/fixes/<YYYY-MM-DD>-<topic>-fix.md`
   - 模板: `docs/superpowers/fixes/_template-fix.md`
2. **再改 spec/plan/SKILL.md**(基于 fix.md 的结论)
3. **被改文件末尾加 ChangeLog 条目**,引 fix.md 路径
4. **commit message** 引用两边:`[fix] <topic>: <一句话>` + body 写 `fix: <path>; affected: <spec/skill path>`
5. **Master Plan 更新**:在"Fix 索引"区追加一行(下一节 fix-records-governance 详述)

### 7.2 当你开发新功能时(没有 fix 触发)

1. 改 SKILL.md / 加 phase plan / 写新 spec — 正常 commit
2. 不需要写 fix.md
3. **不需要**加 ChangeLog 条目(初始实现期间)
4. 但 commit message 必须能说清"做了什么"

### 7.3 当你做 phase 复盘时

1. 写 `docs/superpowers/retros/<date>-<phase>-retro.md`(主动周期性产物)
2. retro 里列改善点
3. 每个改善点逐条做的时候 → 触发 7.1 流程(写 fix → 改 spec/SKILL → ChangeLog)
4. retro 末尾追加"修复实施记录",指向各 fix.md

---

## 8. 验收标准

- ✅ 任何 spec / SKILL.md 的实质性改动,都能通过 ChangeLog 条目找到 fix.md
- ✅ 正文永远是最新结论,不残留"过时但有故事的"段落
- ✅ Master Plan 是唯一全局索引,任何 spec / plan / fix 都能从这里找到
- ✅ 新接手 AI 读 Master Plan + 配套 governance 文档就能上手,不必追问

---

## 9. 非目标

- ❌ 不强制每次 commit 都加 ChangeLog(开发期没有 fix 触发的不需要)
- ❌ 不重写所有历史 spec / plan(只追加 ChangeLog,不动正文)
- ❌ 不在 spec / plan 里复制 fix 细节(细节留在 fix.md)

---

## ChangeLog

- **2026-05-27** — 立此文档,定义 spec/plan 管控规则
  - 变更类型: 流程
  - 影响范围: 全部 spec / plan / SKILL.md 后续变更
  - 动机: 参考用户 `/root/ai-auto-harness-masterplan-and-fix.md` 文档 + 项目实情(SKILL.md 双重身份等)
  - 证据: 本文档 §1 痛点
  - 验证: 待验证(后续 fix 流程跑通后回填)
