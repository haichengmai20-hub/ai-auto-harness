# cleanup 只做 dry_run + state 终态不是 archived——Phase 5 实际未生效

## 元信息

- **Fix ID**: `2026-06-03-cleanup-no-real-cleanup-and-state-mismatch-fix`
- **创建日期**: 2026-06-03
- **级别**: P2
- **状态**: ✅ 已闭环（toonflow-app e2e 验证 cleanup 真清 + 终态 archived + cleanup.json 落盘）
- **负责人 / session**: Claude session @ 2026-06-03（ControlFoley e2e retro）；2026-06-05 闭环回填

---

## 人话版

**一句话**：打扫只做了比划没真扫，而且完工章盖错了位置。

**打比方**：清洁工拿着扫把比划了一圈（dry_run），地上还是一地灰。而且签收单上写的是"complete"而不是"archived"（归档），后面的人不知道这房子是已经交钥匙还是还在装修。

**现在怎样**：(1) cleanup 阶段没有真正清理 `.cache/`（478MB 还在），没有调 `cleanup-deployed-workspace` skill，而是主 agent 自己 bash 删了几个临时文件 (2) state.json 最终 `phase=complete` 而非 SKILL.md 定义的 `archived` (3) cleanup.json 缺失

**要做什么**：Phase 5 Task 9（cleanup 切 dry_run=false）还没做，需要先验证 cleanup SKILL 正确再切真清。state 终态统一为 `archived`。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | controlfoley（但此问题是框架级——所有项目都会遇到） |
| **触发 run_id** | `controlfoley-resume-20260603-130210` |
| **触发时间** | 2026-06-03 15:00 ~ 15:36 |
| **触发阶段** | cleanup |
| **workspace 路径** | `workspace/controlfoley/` |
| **runs 路径** | `runs/controlfoley-resume-20260603-130210/` |

---

## 现象

- 现象 1: cleanup 只删了临时文件，没清 `.cache/`（478MB 仍在）
  - 证据: `du -sh workspace/controlfoley/.cache/` = 478MB
  - 证据: 主 agent 用 Bash `rm -rf model_weights/.cache/` 等命令手动清理，未调 `cleanup-deployed-workspace` skill
- 现象 2: state.json `phase=complete` 而非 `archived`
  - 证据: `workspace/controlfoley/state.json` → `phase=complete`
  - 但 `cleanup-deployed-workspace/SKILL.md` 定义终态为 `archived`
- 现象 3: cleanup.json 缺失
  - 证据: `workspace/controlfoley/results/cleanup.json` 不存在
- 现象 4: 磁盘 97% 满，17GB workspace 未真正清理
  - 证据: `df -h /` → 97% used

---

## 触发条件 / 复现步骤

1. 任何项目跑完 verify → 进入 cleanup
2. 主 agent 自己 bash 做清理（不调 cleanup skill）
3. cleanup 不按 SKILL.md 的 JSON schema 落盘
4. state 写成 `complete` 而非 `archived`

---

## 影响

- **影响范围**: Phase 5 的 cleanup 实际未生效，磁盘会持续增长
- **影响下游**:
  - `auto-status` / `auto-recover` 看到非 `archived` 终态可能误判
  - cleanup.json 缺失 → 无法追踪清了什么、释放了多少空间
  - 17GB × N 个项目 → 磁盘很快爆
- **严重程度**: P2 — 功能存在但未真正生效，不阻塞但累积问题严重

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 根因还是 R9（Fix #31）——主 agent 不调 Task() dispatch cleanup SubAgent，
  > 自己 bash 清理不走 SKILL.md 流程。cleanup.json 缺失和 state 终态错误都是副产品。
  > 另外还有个独立问题：cleanup 目前默认 dry_run=true（安全优先），Task 9（切 dry_run=false）在 Phase 5 待办中但未执行。

---

## 修复方案

### 设计层修改

- [ ] 统一 state 终态命名：所有 SKILL.md 中 cleanup 完成后写 `phase=archived`（不是 `complete`/`done`）
  - 检查 `cleanup-deployed-workspace/SKILL.md`、`auto-deploy/SKILL.md`、`auto-daily/SKILL.md`、`auto-recover/SKILL.md`
- [ ] 在 `auto-status` / `auto-recover` 中加 `archived` 终态处理逻辑

### 实现层修改

- [ ] 执行 Phase 5 Task 9：验证 cleanup SKILL 正确后切 `dry_run=false`
- [ ] 对已完成的 4 个项目手动补 cleanup（或写一个 `scripts/retroactive-cleanup.sh`）

---

## 验证步骤

1. 对 controlfoley 手动调 `cleanup-deployed-workspace` skill（dry_run=false）
2. 期望：`results/cleanup.json` 存在、`state.json` phase=archived、磁盘释放若干 GB
3. 验证 `auto-status` 能正确读取 `archived` 状态

---

## 修复结果

- **状态**: ✅ 已闭环（2026-06-05 toonflow-app e2e 验证三处问题全修复）
- **验证证据**:
  - **cleanup 真清（非 dry_run）**：`workspace/toonflow-app/results/cleanup.json` → `bytes_freed=1806883264`（~1.68GB）、`items_removed=["repo/", ".cache/"]`、`dry_run` 已切 false
  - **终态 archived**：`workspace/toonflow-app/state.json` → `phase=archived`、`status=done`（不再是 `complete`）
  - **cleanup.json 落盘**：含 `slug/phase/status/bytes_before/bytes_after/bytes_freed/items_removed/items_kept` 完整 schema
  - controlfoley 原始 case 已另行手动补清（`.cache/` + `model_weights/` 已清理）
  - 关联闭环：[scan-to-deploy-never-e2e-verified-fix](2026-06-03-scan-to-deploy-never-e2e-verified-fix.md)（#32，同一 toonflow-app e2e 覆盖 cleanup→archived 终段）
- **残留**：原始触发的根因 R9（[#31](2026-06-03-r9-task-dispatch-still-bypassed-fix.md)）本身未解（主 agent 仍可能内联 cleanup），但 cleanup 机制本身已验证可真清 + 落盘 + 写正确终态
- **commit hash**: N/A（本 session 提交）

---

## 证据指针

- workspace: `workspace/controlfoley/`（17GB 未清理）
- 相关 SKILL: `.claude/skills/cleanup-deployed-workspace/SKILL.md`
- 相关 SKILL: `.claude/skills/auto-status/SKILL.md`
- Phase 5 待办: `docs/superpowers/plans/2026-05-25-phase-5-runbook-and-cleanup.md`（Task 9-13）

---

## 关联

- **关联 fix**: [2026-06-03-r9-task-dispatch-still-bypassed-fix.md](2026-06-03-r9-task-dispatch-still-bypassed-fix.md)（R9 违规导致 cleanup skill 未被调用，本 fix 的根因）
- **关联 fix**: [2026-05-26-runs-cache-cleanup-decision-fix.md](2026-05-26-runs-cache-cleanup-decision-fix.md)（Fix #9，runs cache 清理决策，本 fix 是 workspace 级清理）
- **关联 plan**: `plans/2026-05-25-phase-5-runbook-and-cleanup.md`（Task 9: cleanup 切 dry_run=false）

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → 2026-06-05 Master Plan Fix 索引 #33 状态 → ✅
- [x] **Master Plan Fix 索引区已更新** → 2026-06-05 #33 标 ✅，Phase 5 Task 9 已 ✅
- [ ] **是否提升到 memory/lessons** → 否（单项目特定问题，机制已并入 cleanup SKILL）
- [x] **是否需要 L1 重测验证** → 2026-06-05 toonflow-app e2e 真清 1.68GB + 终态 archived 验证通过
- [ ] **是否需要写 pending_human** → 否

---

## ChangeLog

- **2026-06-05** — 状态 未落地 → ✅ 已闭环：toonflow-app e2e 验证 cleanup 真清(1.68GB)+ 终态 archived + cleanup.json 落盘
  - 变更类型: 状态 / 证据补充
  - 影响范围: 本文件 元信息/修复结果/后续动作段
  - 动机: cleanup 机制三处问题(真清/终态/JSON)已被 toonflow-app e2e 全部验证修复，doc 滞后于现实
  - 证据: `workspace/toonflow-app/results/cleanup.json` + `workspace/toonflow-app/state.json`(phase=archived)
  - 验证: ✅ 已验证(toonflow-app e2e)
