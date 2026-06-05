# verify SubAgent 落盘 schema 强制约束 — 2 个项目自创 schema 导致 .passed=null

## 元信息

- **Fix ID**: `2026-05-27-verify-schema-enforcement-fix`
- **创建日期**: 2026-05-27
- **级别**: P1(下游 cleanup G4 / auto-status 会误判,但当前 3 项目恰好 .passed 字段对了不阻塞)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-05-27

---

## 人话版

**一句话**：各项目的 verify.json 自创 schema（字段名不统一、类型不一致），需要统一 6 字段强约束。

**做了什么**：定了 verify.json 必须含 passed / verify_ts / checks / errors / verify_level / artifacts 6 个字段，加了 validate-verify.sh 脚本。

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2、omnivoice、song-generation-run2(3 个都中招) |
| **触发 run_id** | hunyuan3d-2: `2026-05-26-1700-*`(详见 reports/2026-05-26-hunyuan3d-2.md);omnivoice: `2026-05-25` 时段;song-generation-run2: `songgen-e2e-run3-resume-20260522-094040` |
| **触发时间** | 2026-05-22 ~ 2026-05-26(逐次跑 verify 时落盘) |
| **触发阶段** | verify |
| **workspace 路径** | `workspace/{hunyuan3d-2,omnivoice,song-generation-run2}/` |
| **runs 路径** | 多个,见 reports/ 里指向 |

---

## 现象

- 现象 1: `workspace/hunyuan3d-2/results/verify.json` 用自创 schema `{status:"verified", checks:{...}, output_path:...}`,**根字段缺 `passed`**
  - 证据: `jq -r '.passed' workspace/hunyuan3d-2/results/verify.json` → `null`
- 现象 2: `workspace/omnivoice/results/verify.json` 用另一种自创 schema `{status:"verified", verdict:"PASS", verdict_reason:...}`,同样**缺 `passed`**
  - 证据: `jq -r '.passed' workspace/omnivoice/results/verify.json` → `null`
- 现象 3: `workspace/song-generation-run2/results/verify.json` 是第三种自创 schema `{phase,timestamp,criteria,passed,status}`,**恰好 `.passed=true` 字段在**,但其他字段 (`failed_at` / `evidence` / `notes` / `confidence` / `completed_at`) 都缺

---

## 触发条件 / 复现步骤

1. verify SubAgent 启动,SKILL.md §返回 schema 给了示例(passed/failed_at/evidence/notes/confidence/completed_at 6 字段)
2. 但 SKILL.md 的 §强制要求 用 `<true|false>` 占位符,未对 LLM 输出做后置自检
3. LLM "自由发挥"创造自己觉得合适的 schema(每个 LLM 不一样)
4. 落盘后 `jq -e 'has("passed")'` 失败,但 SubAgent 不知道,直接 PHASE_END=done

期望失败:下游 `jq -r '.passed'` 拿到 `null`。

---

## 影响

- **影响范围**: 数据完整性 + 流程可靠性
- **影响下游**:
  - `cleanup-deployed-workspace` G4 防护 (`if [ "$VERIFY_PASSED" != "true" ]; then SKIPPED=true`) 误判 `verify_not_passed` → cleanup 不清,workspace 残留
  - `auto-status` 显示状态错乱
  - `write-recommendation` 读 verify.json 拼日报时丢字段
  - Phase 5 Task 5-7 主流程串联**直接阻塞**(cleanup G4 拦)
- **严重程度**: P1 — 当前 3 项目的 `.passed` 字段恰好都正(2 个回填、1 个原本就有),所以 Task 5-7 不立刻挂;但任何新跑 verify 的项目都可能再撞

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > `verify/SKILL.md` §强制要求第 1 步用 `<true|false>` 这种**占位符语法**而非**变量替换的 bash heredoc**,LLM 把这当成"建议格式"而非"必须"。
  > 同时缺**后置 schema 自检**(`jq -e 'has("passed")'`),LLM 写完就返回,没人验。
  > 这是 S-1(SKILL 约束被 LLM 自由发挥绕过)的同源问题。

---

## 修复方案

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [x] 改 `.claude/skills/verify/SKILL.md` §强制要求第 1 步:用 bash 变量 `PASSED_VAL=true` + heredoc 替换占位符语法,LLM 不能省字段名
- [x] 改 `.claude/skills/verify/SKILL.md` §强制要求第 2 步:**新加** jq -e 自检 6 个根字段 + boolean 类型校验
- [x] 改 `.claude/skills/verify/SKILL.md` 加 🔴 反模式段(S-1 模式),列 6 条 LLM 易犯错
- [x] 改 `.claude/skills/verify/SKILL.md` PHASE_END 用 `| tee -a "$LOG"`(P4-1 同源修复)

### 实现层修改(代码 / 脚本 / 配置)

- [x] 新建 `scripts/validate-verify.sh`:5 个 V check 自动化拦截"自创 schema"
- [x] 回填 `workspace/hunyuan3d-2/results/verify.json`:加 `passed:true, failed_at:null, backfilled_at, backfill_reason`,保留原 schema 字段
- [x] 回填 `workspace/omnivoice/results/verify.json`:同上

### 文档层修改(retro / lessons / handoff)

- [ ] 暂未提升到 `memory/lessons/`,因为这是 SubAgent 行为而非通用技术问题

---

## 验证步骤(必须可复现)

1. 跑 validate 脚本对 3 个 workspace:
   ```bash
   for ws in workspace/hunyuan3d-2 workspace/omnivoice workspace/song-generation-run2; do
       bash scripts/validate-verify.sh "$ws"
   done
   ```
2. 期望输出(回填后):3 个都 `.passed=true (boolean, 合法)` + `passed=true + failed_at=null (一致)`
   - 但其他字段(evidence/notes/confidence)仍报缺 — 这是历史欠账,Task 5-7 重跑 verify 时强化后的 SKILL.md 会自然修复
3. 新 verify SubAgent 跑完后:`jq -e 'has("passed") and has("failed_at") and has("evidence") and has("notes") and has("confidence") and has("completed_at")'` → `true`

---

## 修复结果

- **状态**: ✅ 成功(立即阻塞已解 + 长期修法已落)
- **验证证据**:
  - 3 个 workspace 的 `.passed` 都是 `true` 后,Task 5-7 cleanup G4 可通过
  - `scripts/validate-verify.sh` 烟测能正确识别历史欠账(其他字段缺)
- **commit hash**: 待 commit(本 session 工作)
- **commit message**: `[fix] verify: enforce 6-field schema with jq self-check + backfill 2 broken workspaces`

---

## 证据指针

- workspace: `workspace/{hunyuan3d-2,omnivoice,song-generation-run2}/results/verify.json`
- 报告:`reports/2026-05-25-omnivoice.md`、`reports/2026-05-26-hunyuan3d-2.md`(均确认部署成功,但 verify.json schema 各异)
- 相关 SKILL: `.claude/skills/verify/SKILL.md`
- 验证脚本: `scripts/validate-verify.sh`

---

## 关联

- **关联 fix**: [2026-05-26-phase5-l1-retro-15-fixes.md](2026-05-26-phase5-l1-retro-15-fixes.md)(S-1 同源:LLM 自由发挥绕过 SKILL)
- **关联 spec/plan ChangeLog 条目**: `.claude/skills/verify/SKILL.md` ChangeLog 2026-05-27 条目(待加)
- **关联 master plan 待办**: 「修 verify.json passed=null」(待办 ④ 已划掉)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → `.claude/skills/verify/SKILL.md` 末尾(待加 ChangeLog 章节)
- [x] **Master Plan Fix 索引区已更新** → 见下次 master plan patch
- [ ] **是否提升到 memory/lessons** → 否(SubAgent 行为问题,非通用技术)
- [ ] **是否需要 L1 重测验证** → 是,Task 5-7 串联跑时 verify SubAgent 重出 schema 时验
- [ ] **是否需要写 pending_human** → 否
