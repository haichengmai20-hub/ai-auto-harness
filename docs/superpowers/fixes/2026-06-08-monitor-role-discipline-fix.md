# Monitor 角色纪律:强化"只看不动" + 场景化角色边界

## 元信息

- **Fix ID**: `2026-06-08-monitor-role-discipline-fix`
- **创建日期**: 2026-06-08
- **级别**: P1
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-08

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**:监工动手干活了,该只看不动。

**打比方**:监工(monitor)本该站旁边拿小本本记"谁违规了",结果他自己冲上去开机器、派工、踹掉卡住的下载——把自己当成了车间主任。

**现在怎样**:在 magenta-realtime 陪跑会话里,monitor 三次自己启动 `launch_worker.sh` 续跑、试图用 Agent 工具派 SubAgent、还去 `kill -0` 别人 run 的进程、高频 poll 烧 turn。

**要做什么**:在 monitor 的 SKILL 里把"你不是谁""分场景能做什么/不能做什么""Write/Bash 只能干哪些"写死,并加一条"每次巡检先自查上一 turn 有没有动手"。

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | magenta-realtime |
| **触发 run_id** | magenta-resume-* / e2e-magenta-20260608-* |
| **触发时间** | 2026-06-08(交互式陪跑会话) |
| **触发阶段** | ops / fetch-weights(auto-deploy resume) |
| **workspace 路径** | `workspace/magenta-realtime/` |
| **runs 路径** | `workspace/magenta-realtime/runs/*`(已随 run-dir fix 迁移) |

---

## 现象

monitor(AI agent)在交互式会话里把自己当成了主 agent / cron / 用户,擅自:

| # | 行为 | 违反规则 |
|---|---|---|
| 1 | 用 `kill -0` 检查非本 run 的下载 PID | R1 workspace 隔离 |
| 2 | 3 次启动 `launch_worker.sh` 续跑 | monitor 反模式"不干预 pipeline" |
| 3 | 试图用 Agent/Task 工具 dispatch fetch-agent | R9 + monitor 反模式 |
| 4 | 多次高频 poll(du/ps/tail) | R4.5 poll 过多 |

---

## 触发条件 / 复现步骤

1. 用户在交互式 Claude Code 会话里同时充当 monitor + 人工决策者。
2. 用户说"续跑"/"看看跑到哪了"。
3. monitor 不是"报告状态 + 告知用户启动命令",而是自己执行 `launch_worker.sh` / 自己 dispatch SubAgent / 自己重启卡死下载。
4. 期望异常:monitor 越权执行主 agent / cron / 用户的职责,角色混乱,重演 R9 事故。

---

## 影响

- **影响范围**: 可靠性 / 隔离正确性 / 成本(高频 poll 烧 turn)。
- **影响下游**: 与 R1 / R9 直接冲突;monitor 越权 launch 多个 worker 会造成并发 worker、带宽竞争、重复 dispatch。
- **严重程度**: P1 — 根因不只是"monitor 不自律",而是**角色边界在不同场景(continuous / post-mortem / auto-deploy resume / 下载卡死)下模糊**,SKILL 没把"你不是谁"和"分场景红线"写死。

---

## 根因

- **是否已确认**: ✅
- **简述**: `monitor-ride-along/SKILL.md` 只有一句笼统的"不要干预运行中的 pipeline",没有(a)"你不是谁"的显式否定声明,(b)按场景区分的能做/不能做清单,(c)Write/Bash 工具的用途白名单,(d)每轮"自我纪律检查"。当用户说"续跑"时,monitor 缺少"建议用户启动,而不是自己启动"的明确指引,于是滑向主 agent 角色。

---

## 修复方案

### 设计层修改(SKILL.md)

- [x] `monitor-ride-along/SKILL.md` 开头加"你不是谁(防止角色混淆)"段(显式否定:不是主 agent / cron / SubAgent / 用户)。
- [x] 把笼统反模式扩充为**场景化角色边界**(场景 1 continuous / 场景 2 post-mortem / 场景 3 auto-deploy resume / 场景 4 下载卡死),每个场景写清 ✅ / ❌。
- [x] 加"Write 工具使用约束"(只写 monitor.jsonl / monitor_alerts.md / reports/monitor-audit/;不写 state.json / results/*.json / 他人文件)。
- [x] 加"Bash 工具使用约束"(只读操作;禁启动 launch_worker/hf download/pip/python/git clone/setsid;禁 kill/pkill/rm/mv;禁写 state.json/results)。
- [x] 巡检清单加第 7 项"自我纪律检查"(每次巡检先自查上一 turn 是否做了干预操作,违规即记 self_violation 并转"告知用户")。
- [x] 同步 run-dir fix:hook_state / transcript 路径从 `runs/$RUN_ID/` 改为 `$WORKSPACE/runs/$RUN_ID/`(随 [run-dir-into-workspace](2026-06-08-run-dir-into-workspace-fix.md))。

### 实现层修改

- 无运行时代码改动(monitor 是纯 prompt skill;allowed-tools 不动,因为 CC 的 allowed-tools 不支持路径级限制,约束写进 SKILL prompt)。

---

## 验证步骤(必须可复现)

1. `grep -c '你不是谁\|场景 1\|场景 3\|自我纪律检查\|Write 工具使用约束\|Bash 工具使用约束' .claude/skills/monitor-ride-along/SKILL.md` → 期望 ≥ 6。
2. 读 SKILL.md 确认 4 个场景边界 + 工具约束 + 巡检清单第 7 项就位。
3. 下次交互式陪跑会话:用户说"续跑"时,monitor 应回"需要启动 `bash cron/launch_worker.sh ...`,我来报告状态,要不要你执行",而非自己执行。

---

## 修复结果

- **状态**: ✅ 成功(SKILL 闭环)
- **验证证据**: grep 命中 6 段;SKILL.md 已含 4 场景 + Write/Bash 约束 + 巡检第 7 项 + ChangeLog。
- **commit hash**: 见本次 `[fix] monitor` 提交(git log)
- **commit message**: `[fix] monitor: 场景化角色边界 + 强化"只看不动"纪律`

---

## 证据指针(必填)

- workspace: `workspace/magenta-realtime/`
- 相关 SKILL: `.claude/skills/monitor-ride-along/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R1 / R4.5 / R9
- monitor 输出: `workspace/<slug>/logs/monitor.jsonl` + `monitor_alerts.md`

---

## 关联

- **关联 fix**: [2026-06-08-run-dir-into-workspace-fix](2026-06-08-run-dir-into-workspace-fix.md)(同一 magenta 会话暴露 + run-dir 路径同步)
- **关联 lessons**: `memory/lessons/monitor-patterns.md`(monitor 自身越权属新模式,可追加)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(SKILL.md ChangeLog)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(monitor 自身越权是可复现新模式,追加到 monitor-patterns.md)
- [ ] **是否需要 L1 / L2 重测验证** → 否(纯 prompt 约束,下次陪跑会话观察)
