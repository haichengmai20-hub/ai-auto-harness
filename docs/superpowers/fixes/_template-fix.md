# <Topic 一句话标题>:<问题摘要>

<!--
模板使用说明:
1. 复制本文件到 fixes/<YYYY-MM-DD>-<topic-kebab-case>-fix.md
2. 删除 HTML 注释和占位提示
3. "部署项目来源" 段必填(若纯平台讨论无具体 run,标 "N/A 仅平台讨论" 并说明)
4. 完成所有步骤(governance §5)后,把状态改为 "已闭环"
5. **必填"人话版"段**——用大白话解释问题，让非技术的人也能一眼看懂
-->

## 元信息

- **Fix ID**: `<YYYY-MM-DD>-<topic>-fix`
- **创建日期**: YYYY-MM-DD
- **级别**: P0 / P1 / P2
- **状态**: 进行中 / 已闭环 / 已废弃
- **负责人 / session**: <人/AI session 标识,可写 "Claude session @ <date>">

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：<用大白话描述核心问题，不超过 20 字>

**打比方**：<用一个日常生活比喻，让人秒懂>

**现在怎样**：<当前的症状，大白话>

**要做什么**：<修复方向，大白话>

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | <song-generation-run2 / hunyuan3d-2 / omnivoice / N/A 仅平台讨论> |
| **触发 run_id** | <songgen-e2e-run3-resume-20260522-094040 / N/A> |
| **触发时间** | YYYY-MM-DD HH:MM(+08:00) |
| **触发阶段** | intake / fetch-weights / install-env / run-and-repair / verify / cleanup / runbook / ops / phase-L1-test / phase-L2-test |
| **workspace 路径** | `workspace/<slug>/` 或 N/A |
| **runs 路径** | `runs/<run-id>/` 或 N/A |

---

## 现象

> 可复述的错误 / 异常行为,引具体日志行。

- 现象 1: <一句话>
  - 证据: `<file>:<line>` 或 `<command>` 输出
- 现象 2: <若多个,逐条列>

---

## 触发条件 / 复现步骤

> 给后人一份能 grep / 重跑的复现路径。

1. <环境前提>
2. <步骤 1>
3. <步骤 2>
4. 期望失败/异常:<现象>

---

## 影响

- **影响范围**: <功能 / 性能 / 成本 / 可靠性 / 数据完整性>
- **影响下游**: <哪些 spec / SKILL / SubAgent 因此误判 / 输出半成品>
- **严重程度**: <为什么是 P0 / P1 / P2 — 数值化为佳,如 "wall-clock 占 97%"、"22GB 残留">

---

## 根因

- **是否已确认**: ✅ / ❌
- **简述**: <一段话>
  > 例:`launch_worker.sh` 创建 `runs/$RUN_ID/.cache/` 作为 isolated cache,
  > `cleanup-deployed-workspace/SKILL.md` 只清 `workspace/<slug>/{venv,.cache,repo}`,
  > 不动 `runs/<run-id>/.cache/`,导致跨 cron run 残留累积。

---

## 修复方案

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [ ] 改 `<file>` 的 `<section>`:<具体动作>
- [ ] 改 `<file>` 的 `<section>`:<具体动作>

### 实现层修改(代码 / 脚本 / 配置)

- [ ] 新建 `<file>`:<动作>
- [ ] 修 `<file>`:<动作>

### 文档层修改(retro / lessons / handoff)

- [ ] 在 retro 加注:<>
- [ ] 提升到 `memory/lessons/<topic>.md`:<>

---

## 验证步骤(必须可复现)

1. <命令>
2. 期望输出:<>
3. <命令>
4. 期望输出:<>

**自动化验收**(推荐):

```bash
bash scripts/validate-<topic>.sh <args>
# 期望:✅ 全部通过 / FAIL=0
```

---

## 修复结果

- **状态**: ✅ 成功 / ⚠️ 部分成功 / ❌ 失败
- **验证证据**: <粘贴 validate 输出 / L1 重测结论 / 数据指标对比>
- **commit hash**: `<short hash>`
- **commit message**: `<message>`

---

## 证据指针(必填)

> 让后人能 grep 到当时的事实,不必依赖记忆。

- workspace: `workspace/<slug>/`
- runs: `runs/<run-id>/`
- 日志:`workspace/<slug>/logs/<phase>.log` / `runs/<run-id>/harness.stdout.ndjson`
- 报告:`reports/<date>-<slug>.md` / `reports/runbooks/<slug>-<date>.md`
- 相关 SKILL:`.claude/skills/<name>/SKILL.md`
- 相关 R 规则:`.claude/CLAUDE.md` R<N>(若适用)

---

## 关联

- **关联 fix**:<若该 fix 延伸另一个 fix,引路径>
- **关联 retro**:`docs/superpowers/retros/<date>-<phase>-retro.md`(若来源于 retro 的某条改善点)
- **关联 spec/plan ChangeLog 条目**:被改文件路径 + ChangeLog 该条目日期
- **关联 lessons**:`memory/lessons/<topic>.md`(若提升)
- **关联 pending_human**:`pending_human/<topic>.md`(若从 pending 闭环)

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ✅ / ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ✅ / ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是 / 否(理由:<>)
- [ ] **是否需要 L1 / L2 重测验证** → 是 / 否(测试 prompt 路径:<>)
- [ ] **是否需要写 pending_human** → 是 / 否(若部分修复待人决策)
