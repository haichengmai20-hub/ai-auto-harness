# poll_count 跨阶段累加超限 — R4 规则只在单阶段内生效,跨阶段重入不清零

## 元信息

- **Fix ID**: `2026-05-29-poll-count-accumulate-cross-phase-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P2(计数器逻辑缺陷,不阻塞部署但削弱 R4 保护)
- **状态**: 进行中
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice(poll_count=23);hunyuan3d-2(poll_count=16) |
| **触发 run_id** | omnivoice: `2026-05-25-1401-2293813`;hunyuan3d-2: `2026-05-25-1752-*` |
| **触发时间** | 2026-05-25 |
| **触发阶段** | 跨多个阶段(累加) |
| **workspace 路径** | `workspace/omnivoice/`、`workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/` |

---

## 现象

- 现象 1: OmniVoice `.hook_state.json` 记录 `poll_count=23`,远超 R4.5 的 8 次上限
  - 证据: `jq .poll_count runs/2026-05-25-1401-2293813/.hook_state.json` → `23`
- 现象 2: Hunyuan3D-2 同样 `poll_count=16`,超 8
  - 证据: `jq .poll_count runs/2026-05-25-1752-*/.hook_state.json` → `16`
- 现象 3: 单阶段内确实在 8 次时退出了(符合 R4),但跨阶段重入时计数器不清零,继续累加

---

## 触发条件 / 复现步骤

1. install-env 阶段撞 poll 预算(8 次)→ `paused_in_progress` 退出
2. `/auto-recover` 重入,进入下一阶段
3. poll_count 从上一阶段的 8 继续累加(不清零)
4. 跨多个阶段后总 poll_count 远超 8

---

## 影响

- **影响范围**: R4 规则有效性
- **影响下游**: R4 的"8 次上限保护"被削弱——跨阶段累加后,后续阶段的 poll 预算实际已用尽但仍继续轮询(本应在 8 次就退)
- **严重程度**: P2 — 当前两个项目都在单阶段内正确退出,跨阶段累加只是计数器不准,没有造成实际空转

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > PostToolUse hook 的 `poll_count` 是全局计数器,跨阶段不清零。R4.5 的设计意图是"单阶段内 poll ≤ 8",但 hook 实现没有按 PHASE 标记重置计数器。

---

## 修复方案

### 设计层修改

- [ ] 改 `.claude/CLAUDE.md` R4.5:明确"poll_count 按**阶段**计数,每进入新阶段(PHASE_START)重置为 0"

### 实现层修改

- [ ] 修 `.claude/hooks/post-tool-use.sh`:在检测到 `PHASE_START` 标记时,重置 `poll_count=0`
- [ ] 修 `.claude/hooks/post-tool-use.sh`:R4.5 判定用**本阶段** poll_count 而非全局累计

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 改后重跑,检查 `.hook_state.json`:
   ```bash
   # 每个阶段结束后
   jq '.poll_count' runs/<run-id>/.hook_state.json
   # 期望:≤ 8(本阶段计数,非跨阶段累加)
   ```

---

## 修复结果

- **状态**: ❌ 未落地
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- runs: `runs/2026-05-25-1401-2293813/.hook_state.json`(poll_count=23)
- 相关 R 规则: `.claude/CLAUDE.md` R4.5
- 相关 hook: `.claude/hooks/post-tool-use.sh`

---

## 关联

- **关联 fix**: [2026-05-21-sleep-loop-discipline-fix.md](2026-05-21-sleep-loop-discipline-fix.md)(R4 规则来源)
- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §7 P2

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(hook 实现细节)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后验证 poll_count 单阶段 ≤ 8)
- [ ] **是否需要写 pending_human** → 否
