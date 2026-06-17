# R9 Task() 分派仍被绕过——主 agent 内联全阶段，Phase 5 artifacts 全缺

## 元信息

- **Fix ID**: `2026-06-03-r9-task-dispatch-still-bypassed-fix`
- **创建日期**: 2026-06-03
- **级别**: P1
- **状态**: ✅ 已闭环(Hermes迁移解决)
- **负责人 / session**: Claude session @ 2026-06-03（ControlFoley e2e retro）

---

## 人话版

**一句话**：经理又自己干活了，165 次 Bash 0 次 Task，报告都没按格式写。

**打比方**：工厂流水线本来设计成每个工人干一个工位，但厂长把 7 个工位的活全自己干了，结果最后出货单也没填、质检章也没盖——不是他不会干，是他不按流程干。

**现在怎样**：ControlFoley 全流程跑通了，但主 agent 全程自己 bash（165 次），没有一次调用 Task() 分派给 SubAgent。后果：(1) Phase 5 的 verify.json / runbook.json / cleanup.json 全部缺失——因为这些 JSON 是 SKILL.md 要求 SubAgent 落盘的，主 agent 自己 bash 不走 SKILL 规范 (2) R4 sleep loop 34 次 + poll 78 次——因为没有后台进程 + PID 管理 (3) 所有阶段的 context 揉在一起，做"先装还是先下"的拍脑袋决策

**要做什么**：运行中实时检测 R9 违规（而非事后审计），Bash 超过 N 次且 Task=0 → 强制注入警告或阻断。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | controlfoley（但此问题是框架级——4/4 项目都遇到） |
| **触发 run_id** | `controlfoley-resume-20260603-130210` |
| **触发时间** | 2026-06-03 13:02 ~ 15:36 |
| **触发阶段** | 全阶段（intake → cleanup，贯穿整个 session） |
| **workspace 路径** | `workspace/controlfoley/` |
| **runs 路径** | `runs/controlfoley-resume-20260603-130210/` |

---

## 现象

- 现象 1: 主 agent Bash 调用 165 次，Task() 调用 0 次
  - 证据: `runs/controlfoley-resume-20260603-130210/discipline-report.json` → `bash_count=165, task_called=0`
- 现象 2: Phase 5 artifacts 全部缺失
  - 证据: `workspace/controlfoley/results/` 中无 `verify.json`、`runbook.json`、`cleanup.json`
  - 只有手写 `RUNBOOK.md`（非 SKILL.md 规范的 JSON + md 组合）
- 现象 3: R4 违规——sleep loop 34 次，poll 78 次
  - 证据: `discipline-report.json` → `max_sleep_streak=34, poll_count=78`
- 现象 4: 与 Fix #19（song-generation-run2）完全相同的模式——task_called=0 是系统性问题
  - 证据: 4/4 项目都有 R9 违规（SongGen baseline, SongGen run2, ControlFoley run1, ControlFoley run2）

---

## 触发条件 / 复现步骤

1. 启动任何 `/auto-deploy` 或 `/auto-recover` session
2. 主 agent 读 SKILL.md 后选择自己 bash 而非 Task() 分派
3. 所有阶段在同一 context 内完成
4. SubAgent 专属的 JSON schema 落盘要求被忽略

---

## 影响

- **影响范围**: 所有项目的全流程质量 / Phase 5 artifacts 可用性 / R4 成本
- **影响下游**:
  - verify.json 缺失 → auto-status 无法读验证结果
  - runbook.json 缺失 → 后人无法消费标准化 runbook
  - cleanup.json 缺失 → 无法追踪清理了什么
  - R4 sleep loop → 每次下载多花 $3-5 API 成本
- **严重程度**: P1 — 4/4 项目都遇到，Phase 5 的 SKILL.md 约束形同虚设

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 这和 Fix #19 是同一根因（S-1）：SubAgent 无法传 `--append-system-prompt`（CC 平台限制），
  > SKILL.md 的硬约束被 LLM 当成"建议"。主 agent 觉得自己干更快、更可控，就不分派。
  > Fix #19 和 #26（hook-runid-clobber）都没有解决 S-1 本身。
  > **新发现**：R9 违规不只是"谁干活"的问题，还导致**下游消费链断裂**——
  > Phase 5 的 verify.json / runbook.json / cleanup.json 是 SKILL.md 要求 SubAgent 产出的标准格式，
  > 主 agent 自己 bash 产出的文件不遵循这些 schema，下游工具（auto-status / auto-recover）读不到。

---

## 修复方案

### 短期（运行中检测 + 注入）

- [ ] 改 PostToolUse hook：当 `bash_count > 10` 且 `task_called == 0` → 向 stderr 注入警告
  ```
  ⚠️ R9 VIOLATION: You have used Bash {n} times but Task() 0 times.
  SKILL.md requires dispatching to SubAgents via Task().
  Phase 5 artifacts (verify.json, runbook.json, cleanup.json) WILL be missing if you inline all work.
  ```
- [ ] 在 `auto-deploy` / `auto-recover` SKILL.md 开头加醒目块：
  ```
  ⛔ MANDATORY: Each phase MUST be dispatched via Task(subagent_type="<phase>-agent").
  Inlining all work in one context violates R9 and causes downstream artifact loss.
  ```

### 中期（验证脚本检测）

- [ ] 新建 `scripts/validate-artifacts.sh`：检查 `results/` 中 verify.json / runbook.json / cleanup.json 是否存在且 schema 合法
- [ ] 在 run-and-repair → verify 过渡前自动调用此脚本

### 长期（S-1 根本解）

- [ ] 需要 CC 平台层支持：SubAgent 传 `--append-system-prompt`，让 SKILL.md 约束真正硬起来
- [ ] 状态：搁置，等 CC 上游支持

---

## 验证步骤

1. 启动 `/auto-deploy` 跑一个项目
2. 观察 PostToolUse hook 是否在 Bash >10 且 Task=0 时注入警告
3. 检查 `results/` 中是否产出 verify.json / runbook.json / cleanup.json
4. 期望：主 agent 在收到警告后开始调用 Task()

---

## 修复结果

- **状态**: ✅ 已闭环(Hermes迁移解决)
- **闭环方式**: Hermes 版架构彻底绕开了 CC SubAgent Task dispatch 机制——改用 phase 脚本直跑（`hermes/scripts/phase-*.sh`），主 agent 只做调度/路由/读写 state/cp 快照，无法内联 bash 绕过 dispatch。CC 平台层 S-1 限制（SubAgent 拿不到 `--append-system-prompt`）在 Hermes 版中不再存在，因为根本不使用 CC SubAgent。
- **验证证据**:
  - 2026-06-04 `PostToolUse` 已在 `bash_count > 10 && task_called == 0` 无条件注入 R9 强警告,`>20` 注入立即停止内联提示
  - `scripts/validate-artifacts.sh`（artifact gate）现有 **committed 回归测试** `scripts/tests/test-validators.sh`（2026-06-05）：valid set → PASS、verify.json 缺失 → FAIL、`.passed` 非 bool → FAIL（3/3）
  - `auto-deploy` / `auto-daily` / `auto-recover` 已要求写报告前跑 artifact gate
  - hook fixture 已验证普通 Bash 在第 11 次也会触发 R9 warning
- **硬阻断方案评估（2026-06-05，拒绝）**：
  > 考虑过把 hook 从"警告"升级为"硬阻断"(超阈值 deny Bash) 来强制 Task() 分派，但**评估后主动放弃**：
  > (1) PostToolUse 在工具执行**之后**触发，无法阻止已执行的 Bash，只能注入 context（现状已做到极限）；
  > (2) 真要 deny 需 PreToolUse 无差别拒绝 Bash —— 但主 agent 的**合法**路由/状态机推进/写 state.json 也是 Bash，无差别阻断会**搞挂每一次 run**（R9 允许主 agent 做轻量路由 bash，只是不许干 SubAgent 的活，而"是不是 SubAgent 的活"hook 无法可靠判别）；
  > (3) 根因 S-1（SubAgent 拿不到 `--append-system-prompt`，SKILL 硬约束被当建议）是 CC 平台层限制，非框架可解。
  > 结论：当前 hook 警告 + artifact gate 是**可安全落地的上限**；本 fix 维持 🟡，等 CC 上游支持 SubAgent system-prompt 注入再推进长期解。
- **Hermes 迁移闭环（2026-06-17）**：
  > 上述 S-1 根因在 Hermes 版中不再适用。Hermes 版不使用 CC SubAgent Task dispatch，而是通过 phase 脚本（`hermes/scripts/phase-*.sh`）直跑各阶段。
  > 主 agent 的 `terminal` 调用只做调度（跑 phase 脚本、读写 state、cp 快照、跑 validator），无法内联 bash 绕过 dispatch——
  > 因为 phase 脚本是自包含的，主 agent 只是调度者（R9 明确"跑 phase-*.sh 不算亲自做"）。
  > CC 平台层 S-1 限制（SubAgent 拿不到 `--append-system-prompt`）在 Hermes 版中根本不存在，问题从架构层面消除。
  > 本 fix 状态从 🟡 升级为 ✅ 已闭环。
- **commit hash**: N/A（本 session 提交 artifact gate 回归测试）

---

## 证据指针

- runs: `runs/controlfoley-resume-20260603-130210/`
- discipline: `runs/controlfoley-resume-20260603-130210/discipline-report.json`
- 缺失 artifacts: `workspace/controlfoley/results/`（无 verify.json / runbook.json / cleanup.json）
- 相关 SKILL: `.claude/skills/{auto-deploy,auto-recover,verify,write-deploy-runbook,cleanup-deployed-workspace}/SKILL.md`
- 相关 R 规则: R9（主 agent 不亲自 bash）+ R4（poll 预算纪律）
- validator: `scripts/validate-artifacts.sh`

---

## 关联

- **关联 fix**: [2026-05-29-task-dispatch-not-isolated-fix.md](2026-05-29-task-dispatch-not-isolated-fix.md)（Fix #19，同一根因 S-1，本 fix 是其实测延伸——发现 R9 违规不只是"谁干活"还导致 Phase 5 artifacts 全缺）
- **关联 fix**: [2026-05-21-agent-isolation-fix.md](2026-05-21-agent-isolation-fix.md)（Fix #2，SongGen baseline 的 R9 违规）
- **关联 fix**: [2026-06-02-hook-runid-clobber-fix.md](2026-06-02-hook-runid-clobber-fix.md)（Fix #26，PostToolUse hook 修复，本 fix 的运行中检测方案复用同一 hook 基础设施）

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加(下个 session)
- [x] **Master Plan Fix 索引区已更新** → 2026-06-05 状态更新为 🟡 部分落地,e2e 证据补充;2026-06-17 升级为 ✅ 已闭环(Hermes迁移解决)
- [ ] **是否提升到 memory/lessons** → 否（已有 S-1 记录）
- [x] **e2e 验证结果** → 2026-06-05 toonflow-app: bash_count=77/task_called=0,hook R9 警告触发但被忽略,S-1 根因确认
- [ ] **是否需要写 pending_human** → 否

---

## ChangeLog

- **2026-06-05** — 补充 e2e 验证证据: bash_count=77/task_called=0(5/5 项目),hook 警告触发但被忽略,S-1 根因确认
  - 变更类型: 证据补充
  - 影响范围: 本文件修复结果段
  - 动机: toonflow-app e2e 证实 R9 违规模式仍在,PostToolUse hook 检测有效但纠正无效
  - 证据: `runs/e2e-scan-full-20260605-105555/discipline-report.json`

- **2026-06-05** — 硬阻断方案评估并拒绝 + artifact gate 补 committed 回归测试；状态维持 🟡（标注为"可安全落地上限"）
  - 变更类型: 决策记录 / 测试
  - 影响范围: 本文件修复结果段 + 新增 `scripts/tests/test-validators.sh`（覆盖 validate-artifacts.sh）
  - 动机: 明确 hook 硬阻断不可行（PostToolUse 事后无法阻断 + PreToolUse 无差别 deny 会搞挂合法路由 bash），根本解 S-1 待 CC 平台，避免后人重复尝试危险方案
  - 证据: `scripts/tests/test-validators.sh`（artifact gate 3/3 PASS）
  - 验证: ✅ 已验证(测试通过)；R9 纠正本身仍 ⬜ 待 CC 上游

- **2026-06-17** — 状态从 🟡 升级为 ✅ 已闭环(Hermes迁移解决)
  - 变更类型: 状态升级 / 闭环
  - 影响范围: 本文件元信息状态 + 修复结果段
  - 动机: Hermes 版架构彻底绕开 CC SubAgent Task dispatch，改用 phase 脚本直跑，主 agent 无法内联 bash 绕过 dispatch，S-1 根因从架构层面消除
  - 证据: Hermes 版 R9 规则明确"跑 phase-*.sh 不算亲自做"，主 agent 只做调度/路由/读写 state/cp 快照
