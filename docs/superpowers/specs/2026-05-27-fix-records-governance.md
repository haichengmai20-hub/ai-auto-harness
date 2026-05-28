# Fix 记录管控设计 — 2026-05-27

> ai-auto-harness 项目的**架构 Fix 记录**管理规则。
> 配套文档:[spec-plan-governance.md](2026-05-27-spec-plan-governance.md)(spec/plan 管控)。
> 总入口:[../plans/2026-05-19-ai-auto-harness-master.md](../plans/2026-05-19-ai-auto-harness-master.md)

---

## 1. 目的与范围(读这一节就懂)

### 1.1 Fix 是什么(关键定义)

**Fix = 对 ai-auto-harness 平台/架构/流程的改善的事实链**。

⚠️ **Fix 不是**:
- ❌ **项目内** LLM 对部署项目(SongGen / Hunyuan3D-2 / OmniVoice)的运行时修复
  → 那个走 `workspace/<slug>/logs/fixes.log`(LLM 自动 append),不是这里
- ❌ Phase 完成后的主动复盘 → 那个走 `docs/superpowers/retros/<date>-<phase>-retro.md`
- ❌ 跨项目通用技术经验(torch sm_120 等) → 那个走 `memory/lessons/<topic>.md`
- ❌ 未闭环卡点 → 那个走 `pending_human/<topic>.md`
- ❌ Git commit message → 那个是变更行为本身,不是事实链

✅ **Fix 是**:**从试跑或讨论里看出来的、影响 spec/plan/SKILL/CLAUDE.md 的、平台级**改善的事实链。

**例(都是已发生但未正式记录的真实 fix)**:
| Fix 主题 | 触发源 | 影响 |
|---|---|---|
| 禁 sleep loop | SongGen run2 实测 sleep 占 97% wall-clock | `.claude/CLAUDE.md` R4 |
| 主 / 子 agent 严格隔离 | SongGen run2 主 agent 越权亲自 bash | `.claude/CLAUDE.md` R9 |
| `huggingface-cli` → `hf` | L1 测试 runbook 输出违规 | `CLAUDE.md` R7 + `write-deploy-runbook/SKILL.md` |
| `runs/.cache` 清理选 A | 实测 22GB 残留 | `cleanup-deployed-workspace/SKILL.md` 第 2.5 步 |
| `verify.json` 6 字段强约束 | hunyuan3d-2 / omnivoice verify 自创 schema | `verify/SKILL.md` + `scripts/validate-verify.sh` |

### 1.2 痛点(为什么必须有 fix 记录)

| 痛点 | 后果 |
|---|---|
| 试跑出问题直接改 spec/plan/SKILL | 没有事实链,半年后没人记得"为什么 R4 是这样" |
| 多 session 并发修改同一 spec | **和正在跑的开发任务冲突**(用户原话) |
| 改善结论散落在 git commit / retro / handoff / 用户记忆 | 接手 AI 必须 grep 10 个地方才能拼出完整故事 |
| 修复方案缺验证标准 | 改完没人验,下次同问题再撞 |

### 1.3 fix 解决的问题

1. **变更前置事实链**:**先写 fix → 再改 spec/plan/SKILL**,变更冲突可见
2. **可追溯**:任何 spec/SKILL 上的硬约束都能反查到 fix 证据
3. **可复现**:fix 必含部署项目 + run_id + 路径,后人能 grep 到当时的真相

---

## 2. fix 触发条件(什么时候必须写 fix)

| 场景 | 是否写 fix |
|---|---|
| **试跑(任一阶段)看出架构性改善点** | ✅ 写 |
| 比如:"看到 sleep 这么浪费 turn,平台层该禁" | ✅ 写 |
| **讨论 / brainstorming 出架构决策** | ✅ 写 |
| 比如:"runs/.cache 选 A/B/C/D" 决策完后 | ✅ 写 |
| **Phase L1/L2 测试 retro 里的改善点逐条实施** | ✅ 每条改善点对应一份 fix(retro 里指向各 fix) |
| **多个项目都撞同一个问题** | ✅ 写 1 份 fix(归纳),同时也写 memory/lessons/ |
| **平台层 bug 修复** | ✅ 写(例:PostToolUse hook 漏检测某场景) |
| --- | --- |
| **单个项目部署中 LLM 修 requirements.txt** | ❌ 不写(走 workspace/.../fixes.log) |
| **改 SKILL.md 错字 / 排版** | ❌ 不写(走 git commit) |
| **开发期初始实现某 skill** | ❌ 不写(没有"改善"语义,纯 feature) |
| **复盘整个 phase** | ❌ 不写(走 retro;retro 里指向具体 fix) |

**判定原则**(给犹豫时用):
> "如果不写 fix,我能不能在改 spec/SKILL 时不感到心虚?"
> - 不能(改的理由说不清) → **必须写 fix**
> - 能(改的理由很显然,如初始实现) → 不写

---

## 3. 文件位置 + 命名

### 3.1 目录

```
docs/superpowers/fixes/
├── README.md                                   # 索引 + 速查
├── _template-fix.md                            # 模板
├── 2026-05-21-sleep-loop-discipline-fix.md     # 历史 fix(回填)
├── 2026-05-26-runs-cache-cleanup-decision-fix.md
├── 2026-05-27-verify-schema-enforcement-fix.md # 当下 fix
└── ...
```

### 3.2 命名规则

`<YYYY-MM-DD>-<topic-kebab-case>-fix.md`

- 日期:**fix 写下来的日期**(不是问题首次发生的日期 — 那个写进文件 §时间字段里)
- topic:**问题主题**,不是项目名。例:
  - ✅ `2026-05-26-runs-cache-cleanup-decision-fix.md`(架构决策)
  - ✅ `2026-05-21-sleep-loop-discipline-fix.md`(规则建立)
  - ❌ `2026-05-21-songgen-run2-fix.md`(项目名 — 这种命名是 workspace/fixes.log 的语义)

### 3.3 唯一性

- 同一 topic 只写一份 fix(用日期前缀避免冲突,但 topic 唯一)
- fix 落地后该 fix 文件**作为永久档案**,后续不再追加问题(新问题写新 fix)
- 例外:同一架构主题但**多次演进**(如 R4 sleep 规则后续加细则)可在原 fix 末尾追加"演进记录"段,或新写一份引旧 fix

---

## 4. Fix 模板(每条 fix 必填字段)

完整模板见 `docs/superpowers/fixes/_template-fix.md`。结构:

```markdown
# <topic>:<一句话问题摘要>

## 元信息

- **Fix ID**: `<YYYY-MM-DD>-<topic>-fix`
- **创建日期**: YYYY-MM-DD
- **级别**: P0 / P1 / P2
- **状态**: 进行中 / 已闭环 / 已废弃
- **负责人 / session**: <人/AI session 标识>

## 部署项目来源(必填,精确到 run)

- **部署项目 slug**: <song-generation-run2 / hunyuan3d-2 / omnivoice / N/A 仅平台讨论>
- **触发 run_id**: <songgen-e2e-run3-resume-20260522-094040 / N/A>
- **触发时间**: YYYY-MM-DD HH:MM
- **触发阶段**: intake / fetch-weights / install-env / run-and-repair / verify / cleanup / runbook / ops / phase-L1-test

## 现象

- 现象 1: <可复述的错误 / 异常行为>
- 现象 2: <若多个,逐条列>

## 触发条件 / 复现步骤

1. <步骤>
2. <步骤>

## 影响

- 影响范围: <功能 / 性能 / 成本 / 可靠性 / 数据完整性>
- 影响下游: <哪些 spec / SKILL / 哪个 SubAgent 因此误判 / 半成品>
- 严重程度: <为什么是 P0 / P1 / P2>

## 根因

- 是否已确认: ✅ / ❌
- 简述: <一段话>

## 修复方案

### 设计层修改(spec / plan / SKILL.md)
- [ ] 改 `<file>` 的 `<section>`:<动作>
- [ ] 改 `<file>` 的 `<section>`:<动作>

### 实现层修改(代码 / 脚本)
- [ ] 新建 `<file>`:<动作>
- [ ] 修 `<file>`:<动作>

### 文档层修改(retro / memory / lessons)
- [ ] 在 retro / lessons 加注

## 验证步骤(可复现)

1. <如何验证 — 给可执行命令>
2. <预期输出>

## 修复结果

- 状态: 成功 / 失败 / 部分成功
- 验证证据: <运行 validate 脚本的输出 / 重跑 L1 测试的结论>
- commit: <hash>

## 证据指针(必填)

- workspace: `workspace/<slug>/`(若适用)
- runs: `runs/<run-id>/`(若适用)
- 日志:`workspace/<slug>/logs/<phase>.log` 或 `runs/<run-id>/harness.stdout.ndjson`
- 报告:`reports/<date>-<slug>.md` 或 `reports/runbooks/<slug>-<date>.md`
- 相关 SKILL: `.claude/skills/<name>/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R<N>

## 关联

- 关联 fix: <若该 fix 是另一个 fix 的延伸>
- 关联 retro: `docs/superpowers/retros/<date>-<phase>-retro.md`(若来源于 retro)
- 关联 spec/plan ChangeLog 条目:<被改文件路径 + 该 ChangeLog 条目日期>

## 后续动作

- [ ] 是否需要更新 spec/plan ChangeLog → 已更新 / 待更新
- [ ] 是否需要更新 Master Plan 索引 → 已更新 / 待更新
- [ ] 是否提升到 memory/lessons → 是 / 否(理由)
- [ ] 是否需要 L1 / L2 重测验证 → 是 / 否(测试 prompt 路径)
```

---

## 5. fix 闭环流程(给 future Claude / 接手 AI)

```
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 1: 试跑/讨论里看出架构改善点                                   │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 2: 写 fix.md(用 _template-fix.md,先填部署项目 + run 来源)    │
│   位置: docs/superpowers/fixes/<YYYY-MM-DD>-<topic>-fix.md          │
│   状态: 进行中                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 3: 改 spec/plan/SKILL/CLAUDE.md(基于 fix.md 的修复方案)        │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 4: 在被改文件末尾加 ChangeLog 条目,引 fix.md 路径              │
│   规则见 spec-plan-governance §3.3                                  │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 5: 验证(跑 validate 脚本 / 重测 / 烟测)                       │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 6: 回填 fix.md 的"修复结果"段 + 标"已闭环"                     │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 7: git commit                                                  │
│   message: [fix] <topic>: <一句话>                                   │
│   body: fix: <fix path>; affected: <spec/skill path>; closes: <... > │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ 步骤 8: 更新 Master Plan 的 "Fix 索引区"                            │
│   加一行: - [fix path] — <一句话> — 状态: 已闭环 — commit: <hash>   │
└─────────────────────────────────────────────────────────────────────┘
```

**关键纪律**:
- ❌ **不许跳过步骤 2 直接改 spec/SKILL**(这是当前的痛点)
- ❌ **不许在 fix.md 里复制 spec/SKILL 正文**(写指针即可)
- ✅ fix.md 与 spec/SKILL ChangeLog 形成**双向引用**:fix 指向被改文件,文件 ChangeLog 指回 fix

---

## 6. 与其他记录的边界

| 记录类型 | 写者 | 触发 | 与 fix 关系 |
|---|---|---|---|
| `git log` | 人/agent | 每次 commit | fix 闭环时引 commit hash |
| `workspace/<slug>/logs/fixes.log` | LLM 试跑时 | 部署项目内修复 | **不重叠** — 那是项目级 raw,fix 是平台级升级版。但 fix.md "现象"段可引 fixes.log 行号 |
| `runs/<run-id>/decisions.md` | SubAgent | per-run 决策 | fix.md "证据指针"可引 |
| `docs/superpowers/retros/*.md` | 人 | phase 完成时 | retro 列改善点 → 每条改善点闭环时**生成一份 fix.md** → retro 末尾追加"修复实施记录"指向各 fix |
| `memory/lessons/*.md` | 人 | 跨项目通用知识 | **同一根因多次复现** → fix.md 完后**提升**到 lessons |
| `pending_human/*.md` | SubAgent / 人 | 未闭环卡点 | **fix 是已闭环、pending 是未闭环**;pending 闭环时可升级为 fix |

---

## 7. Master Plan 中的"Fix 索引区"

Master Plan 加新小节:

```markdown
## 🔧 Fix 索引(架构改善事实链)

- [docs/superpowers/fixes/2026-05-21-sleep-loop-discipline-fix.md](...) — 禁 sleep loop,R4 来源 — 状态: 已闭环 — commit: `43e453e`
- [docs/superpowers/fixes/2026-05-26-runs-cache-cleanup-decision-fix.md](...) — runs/.cache 选 A — 状态: 已闭环 — commit: `42bdc5c`
- ...
```

**纪律**:每次写完 fix.md + 闭环后**必更新此索引区**(否则 Master Plan 就失去全局索引价值)。

---

## 8. 验收标准

- ✅ 任何 spec / SKILL.md 的硬约束(R 规则 / schema / 反模式条目)都能反查到 fix.md
- ✅ fix.md 必含部署项目 + run_id + 触发时间(无法回避"哪次跑出来的")
- ✅ Master Plan Fix 索引区与 fixes/ 目录一致(无漏)
- ✅ retro 里的每条改善点闭环时都有对应 fix.md
- ✅ 接手 AI 通过 fix.md 能完整理解"为什么这条规则存在 + 是怎么验证的"

---

## 9. 非目标

- ❌ 不替代 git log(fix 是事实链,git log 是变更行为本身)
- ❌ 不替代 workspace/.../fixes.log(那是项目级 raw)
- ❌ 不要求每个 commit 都对应一个 fix(只架构改善才需要)
- ❌ 不要求 fix.md 写得像论文(模板填空 + 证据指针即可,通常 < 200 行)

---

## ChangeLog

- **2026-05-27** — 立此文档,定义 fix 记录规则
  - 变更类型: 流程
  - 影响范围: 所有架构改善的事实链记录方式
  - 动机: 用户痛点 — "试跑得出改善结论直接改 spec/plan 容易和开发冲突"
  - 证据: 用户原话 + 项目实情(R1-R9 / runs/.cache / verify schema 等都未正式记录)
  - 验证: 待验证(完成历史 fix 回填后)
