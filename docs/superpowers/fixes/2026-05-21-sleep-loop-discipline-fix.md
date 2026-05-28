# SubAgent sleep 浪费 turn — 引入 R4 sleep loop 禁止规则

## 元信息

- **Fix ID**: `2026-05-21-sleep-loop-discipline-fix`
- **创建日期**: 2026-05-21(回填于 2026-05-27)
- **级别**: P0(成本 + 可靠性核心)
- **状态**: 已闭环
- **负责人 / session**: 用户实测发现 + 后续 session 加固

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(SongGen run2) |
| **触发 run_id** | `songgen-e2e-run2-20260521-132245`(SongGen 第二次试跑) |
| **触发时间** | 2026-05-21(run2 跑挂期间) |
| **触发阶段** | fetch-weights / install-env(SubAgent 在等长任务时陷入 sleep loop) |
| **workspace 路径** | `workspace/song-generation-run2/` |
| **runs 路径** | `runs/songgen-e2e-run2-20260521-132245/` |

---

## 现象

- 现象 1: SongGen run2 一次部署 wall-clock 103 min,**sleep 占 97%**(19 个空转 turn × full-context token 重发)
- 现象 2: 单 turn 内连续 `sleep 120 && tail` → 下个 turn 又 `sleep 300 && tail`,LLM 无意义重复
- 现象 3: 每个 sleep > 5min 必触发 prompt cache miss,token 成本指数级上升

---

## 触发条件 / 复现步骤

1. fetch-weights / install-env / run-and-repair 等阶段启动长任务(`nohup ... &`)
2. SubAgent 不知道"什么时候完成",采用 `sleep N && tail` 轮询
3. tail 看到 log 没新行 → 又 sleep → 又 tail → 循环
4. **无人拦截**:SubAgent 不知道 sleep loop 烧钱也烧 turn

---

## 影响

- **影响范围**: 成本 + 可靠性 + turn 预算
- **影响下游**: 一次部署 turn 数失控,$1 部署变 $10+;cron 接续机制形同虚设(SubAgent 不退出让 cron 接管)
- **严重程度**: P0 — 单次成本爆炸 + 跨 cron 接续失效

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > SubAgent 设计时没明确"长任务怎么等"。LLM 自然倾向 `sleep && tail` 模式(从训练数据来的人类常用 shell 模式),
  > 但 LLM turn 不是免费的 — 每个 turn = 一次完整推理 + full-context token 重发。
  > 一个空转 turn 比 cron 下次接续(0 token)贵 1000 倍。

---

## 修复方案

### 设计层修改

- [x] `.claude/CLAUDE.md` 新加 **R4 禁止 foreground sleep > 60s + 连续 sleep + sleep loop**,含 5 个子规则:
  - R4.1 单次 sleep 上限 60s
  - R4.2 连续 sleep 绝对禁止(最硬规则)
  - R4.3 sleep loop 检测自检
  - R4.4 长任务正确姿势(setsid nohup + tail 判活 + 不连续 sleep)
  - R4.5 turn 预算上限(同 phase 内 poll 操作 ≤ 8 turn)

### 实现层修改

- [x] `.claude/hooks/post-tool-use.sh` 加 R4 实时检测:LLM 调 Bash 含 sleep → 通过 `hookSpecificOutput.additionalContext` 注入"上次也是 sleep,这次再 sleep 就是 sleep loop"提醒

---

## 验证步骤

1. 模拟 SubAgent 跑连续两个 sleep 命令
2. 期望:第二个 sleep 被 PostToolUse hook 拦截 + 注入告警 context

---

## 修复结果

- **状态**: ✅ 已落地;v1.1 加固期间生效
- **commit hash**: `43e453e`("v1.1 硬约束加固")

---

## 证据指针

- workspace: `workspace/song-generation-run2/`
- runs: `runs/songgen-e2e-run2-20260521-132245/`(含实测 sleep 占 97% 的 ndjson)
- 相关 R 规则: `.claude/CLAUDE.md` R4
- 相关 hook: `.claude/hooks/post-tool-use.sh`(R4 检测逻辑)

---

## 关联

- **关联 fix**: [2026-05-21-agent-isolation-fix.md](2026-05-21-agent-isolation-fix.md)(同 run2 暴露的同期问题)
- **关联 lessons**: 无(SubAgent 行为规则,非通用技术)

---

## 后续动作

- [x] **CLAUDE.md ChangeLog 已加** → 见 CLAUDE.md 末尾 ChangeLog 章节(本 session 后续动作)
- [x] **不提升 lessons**(SubAgent 行为规则)
