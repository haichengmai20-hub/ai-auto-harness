# LLM 内联执行所有阶段,Task() 隔离未实际落地 — task_called=0

## 元信息

- **Fix ID**: `2026-05-29-task-dispatch-not-isolated-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P1(SubAgent 上下文隔离未实现,verify 独立性无结构保证)
- **状态**: 进行中(根因明确,修复方案待实施)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice + hunyuan3d-2(两个项目都 task_called=0) |
| **触发 run_id** | omnivoice: `2026-05-25-1401-2293813`;hunyuan3d-2: `2026-05-25-1752-*` |
| **触发时间** | 2026-05-25 ~ 2026-05-26 |
| **触发阶段** | 全阶段(5 个阶段都内联执行) |
| **workspace 路径** | `workspace/omnivoice/`、`workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/`、`runs/2026-05-25-1752-*/` |

---

## 现象

- 现象 1: OmniVoice 部署 `.hook_state.json` 记录 `task_called=0`——全程未通过 `Task()` 派发隔离子 agent
  - 证据: `jq .task_called runs/2026-05-25-1401-2293813/.hook_state.json` → `0`
- 现象 2: Hunyuan3D-2 同样 `task_called=0`,transcript 里 `"name":"Task"` 出现 0 次
  - 证据: `jq .task_called runs/2026-05-25-1752-*/.hook_state.json` → `0`
- 现象 3: 5 个阶段由主 agent 在同一会话(或多个手动会话)里**内联执行**,PHASE_START/END 仅为日志边界标记,非进程/上下文隔离
- 现象 4: verify 与 run-and-repair 同处一个会话上下文——verify 能看到 run 的结果,违背"独立验证"原则

---

## 触发条件 / 复现步骤

1. `/auto-deploy` 或 `/auto-daily` 启动主 agent
2. 主 agent SKILL.md 用自然语言描述"dispatch SubAgent via Task()"
3. LLM 倾向于直接内联执行(更省 token、更快、更省心)
4. headless `--bare` 模式下 Task() 可能有额外限制或行为差异
5. 结果:5 个阶段揉在同一个 context 里执行

---

## 影响

- **影响范围**: 架构隔离 + 验证独立性 + 多 run 并存可靠性
- **影响下游**: verify 的"独立判定"在结构上没有保证(能看到 run 结果);前面阶段引入的全局状态污染(环境变量、临时文件)可能影响后续阶段;与 [2026-05-21-agent-isolation-fix.md](2026-05-21-agent-isolation-fix.md) 记录的"主 agent 越权亲自 bash"是同一问题的不同层次
- **严重程度**: P1 — 当前 3 个项目 verify 结论均正确(产物确实有效),但独立性未达标,需正视

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 两层问题:
  > 1. **SKILL.md 层**:auto-deploy/auto-daily SKILL.md 用自然语言描述"dispatch SubAgent",但 LLM 倾向直接内联执行——R9 规则用自然语言描述,没有代码级强制
  > 2. **平台层**:headless `--bare` 模式下 Task() 的实际行为与设计文档(进程内派发)可能有偏差;PostToolUse hook 检测了 R9 违规(主 agent 亲自 bash)但没有检测"应该用 Task() 但没用"

---

## 修复方案

### 设计层修改

- [ ] 改 `auto-deploy/SKILL.md` 和 `auto-daily/SKILL.md`:加硬约束——"每个阶段必须经 Task() dispatch,禁止内联",反模式加"❌ 不要在同一个 context 里跑多个阶段"
- [ ] 改 `.claude/CLAUDE.md` R9:加"主 agent 必须用 Task() dispatch 每个阶段,task_called 必须 > 0"
- [ ] 改 `.claude/hooks/post-tool-use.sh`:加检测——主 agent 在 PHASE_START 后直接调 Bash(非 Task())时注入告警

### 实现层修改

- [ ] 调研 headless `--bare` 模式下 Task() 的实际行为,确认是否可用
- [ ] 若 Task() 在 --bare 下不可用 → 改 launch_worker.sh 启动姿势(去掉 --bare 或换隔离方式)
- [ ] 若 Task() 可用 → 在 SKILL.md 中加强约束 + hook 检测

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 改后重跑 `/auto-deploy`,检查 `.hook_state.json` 的 `task_called`:
   ```bash
   jq .task_called runs/<new-run-id>/.hook_state.json
   # 期望: > 0(至少 5,每阶段一次 Task())
   ```
2. 检查 transcript 中 `"name":"Task"` 出现次数:
   ```bash
   grep -c '"name":"Task"' runs/<new-run-id>/transcript.jsonl
   # 期望: ≥ 5
   ```
3. verify 阶段应在独立 context 中执行,不能直接读 run_result

---

## 修复结果

- **状态**: ❌ 未落地(根因明确,需先调研 --bare 下 Task() 行为)
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/omnivoice/`、`workspace/hunyuan3d-2/`
- runs: `runs/2026-05-25-1401-2293813/`、`runs/2026-05-25-1752-*/`
- 相关 SKILL: `.claude/skills/auto-deploy/SKILL.md`、`.claude/skills/auto-daily/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R9
- 相关 hook: `.claude/hooks/post-tool-use.sh`

---

## 关联

- **关联 fix**: [2026-05-21-agent-isolation-fix.md](2026-05-21-agent-isolation-fix.md)(本 fix 是其延伸——那修的是"主 agent 不亲自 bash",本修的是"主 agent 必须用 Task() dispatch 而非内联")
- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §4
- **关联 retro**: `workspace/hunyuan3d-2/results/2026-05-27-hunyuan3d-2-deploy-retrospective.md` §4

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(平台特定)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后重跑 auto-deploy 验证 task_called > 0)
- [ ] **是否需要写 pending_human** → 否
