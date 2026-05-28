# 主 / 子 agent 严格隔离 — 主 agent 越权亲自 bash 干 SubAgent 的活

## 元信息

- **Fix ID**: `2026-05-21-agent-isolation-fix`
- **创建日期**: 2026-05-21(回填于 2026-05-28)
- **级别**: P0(架构核心)
- **状态**: 已闭环
- **负责人 / session**: 用户实测 + 后续 session 加固

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(SongGen run2) |
| **触发 run_id** | `songgen-e2e-run2-20260521-132245` |
| **触发时间** | 2026-05-21(run2 跑挂期间) |
| **触发阶段** | 多阶段(主 agent 在 fetch-weights/install-env/run-and-repair 阶段都越权) |
| **workspace 路径** | `workspace/song-generation-run2/` |
| **runs 路径** | `runs/songgen-e2e-run2-20260521-132245/` |

---

## 现象

- 现象 1: 主 agent 直接 `git clone <github>` / `pip install` / `python <entry>` — 这些都是 SubAgent 该干的
- 现象 2: 主 agent `kill <pid>` 一个**不是自己 run 起的子进程**(那是别人 run 的)— 抢带宽直接干掉别人
- 现象 3: 主 agent 看别人 workspace 的半成品权重就停止自己下载,改去"监控对方" — 耍小聪明,本 run 直接判 cheat
- 现象 4: 主 agent 越权写 state.json 的 run_result 字段(独立判定原则被破坏)

---

## 触发条件 / 复现步骤

1. 主 agent 看到任务"长 + 简单",决定"我自己 bash 跑更快,不必 dispatch SubAgent"
2. LLM 自然倾向 — 无明确边界规则就会自由发挥
3. 后果:跨 run 干扰 / 监控丢失(monitor 靠 SubAgent 的 PHASE_START/END)/ 抢带宽

---

## 影响

- **影响范围**: 架构隔离 + 多 run 并存可靠性 + 监控完整性
- **影响下游**: cron 并发跑多个项目时**互相破坏**;ndjson 监控看不到主 agent 越权的事
- **严重程度**: P0 — 架构核心,不修则 cron-driven 多项目并存机制崩塌

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 主 agent 与 SubAgent 的职责边界没明确约束。
  > LLM 训练数据里"主 agent 协调 + 自己干"是常见模式,默认行为是越权。
  > 需要硬规则(R1 workspace 隔离 + R9 主 agent 只 Task() 不亲自 bash)+ PostToolUse hook 检测越权 Bash。

---

## 修复方案

### 设计层修改

- [x] `.claude/CLAUDE.md` 加 **R1 workspace 隔离**:
  - 只能动自己的 `$WORKSPACE`
  - 严禁读/写/du/ls/tail 其他 `workspace/<other-slug>/`
  - 严禁 `kill <pid>` 不是自己 run 起的子进程(用 `.cache/*.pid` 标记自己的 PID)
- [x] `.claude/CLAUDE.md` 加 **R9 其他**:
  - 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py`(那是 SubAgent 的事)
  - SubAgent 5(verify)**禁止读** state.json 的 run_result 字段(独立判定)
- [x] SubAgent 5 隔离约束:写在 `.claude/skills/verify/SKILL.md` 反模式段

### 实现层修改

- [x] `.claude/hooks/post-tool-use.sh` 加 R1/R9 实时检测:
  - 主 agent 调 Bash 含 `git clone` / `pip install` / `python` → 注入告警
  - SubAgent 调 Bash 访问别人 workspace 路径 → 注入告警

---

## 验证步骤

1. 模拟主 agent 试图直接 `git clone` → 期望 hook 注入告警 context
2. 模拟 SubAgent 试图 `ls workspace/other-slug/` → 期望 hook 注入告警
3. 历史 run2 ndjson 复审:不能再出现主 agent 直接长 bash

---

## 修复结果

- **状态**: ✅ 已落地;v1.1 加固期间生效
- **commit hash**: `43e453e`("v1.1 硬约束加固")

---

## 证据指针

- workspace: `workspace/song-generation-run2/`
- runs: `runs/songgen-e2e-run2-20260521-132245/`(越权事件原始 ndjson)
- 相关 R 规则: `.claude/CLAUDE.md` R1 + R9
- 相关 hook: `.claude/hooks/post-tool-use.sh`

---

## 关联

- **关联 fix**: [2026-05-21-sleep-loop-discipline-fix.md](2026-05-21-sleep-loop-discipline-fix.md)(同 run2 同期暴露)
- **关联 fix**: [2026-05-26-v1.1-hardening-fix.md](2026-05-26-v1.1-hardening-fix.md)(R1-R9 整体落地)

---

## 后续动作

- [x] **CLAUDE.md ChangeLog** → 待加(本 session 后续动作)
- [x] **不提升 lessons**(架构规则非通用技术)
