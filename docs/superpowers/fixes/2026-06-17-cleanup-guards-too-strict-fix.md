# Cleanup 门太死:archived/force 项目无法重跑 cleanup 清残余

## 元信息

- **Fix ID**: `2026-06-17-cleanup-guards-too-strict-fix`
- **创建日期**: 2026-06-17
- **级别**: P1 (磁盘累积: audiox-turbo 27G / qwen3-tts 26G / omnivoice 3.1G 无法回收)
- **状态**: ✅ 已闭环
- **负责人 / session**: Hermes session @ 2026-06-17

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：清场规则太死，已完工的工位也不让打扫。

**打比方**：工厂有 3 道安检门：1) 必须有完整生产记录 2) 必须有操作手册 3) 必须质检通过。已经完工搬走的工位，生产记录可能不全、操作手册可能没写、质检可能没过，但垃圾确实还在。结果是 56G 垃圾堆在工位上清不掉。

**现在怎样**：audiox-turbo (27G) 因 paused_for_human + 无 verify 被 G2/G3 拦; qwen3-tts (26G) 因 verify 未过被 G4 拦; omnivoce (3.1G) 因无 runbook 被 G3 拦。三个项目总计 ~56G 磁盘无法回收。

**要做什么**：对已 archived/done 的项目放宽 G2/G3/G4; force 模式下 3 阶段结果也可清; 加删除验证防止静默漏删。

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | audiox-turbo / qwen3-tts / omnivoice |
| **触发 run_id** | manual-2026-06-17 (手动重跑 cleanup) |
| **触发时间** | 2026-06-17 |
| **触发阶段** | cleanup |
| **workspace 路径** | `workspace/{audiox-turbo,qwen3-tts,omnivoice}/` |
| **runs 路径** | N/A |

---

## 现象

- 现象 1: qwen3-tts status=done/archived, cleanup 因 G4_verify_failed 跳过,26G 残留
  - 证据: `workspace/qwen3-tts/results/cleanup.json` → `skipped:true, skipped_reason:"G4_verify_failed"`
- 现象 2: audiox-turbo status=paused_for_human, 无 cleanup 结果,27G 残留
  - 证据: `ls workspace/audiox-turbo/results/cleanup.json` → 不存在
- 现象 3: omnivoce status=archived, cleanup 删了 venv/.cache/repo 但漏删 weights/ (3.1G)
  - 证据: `workspace/omnivoice/results/cleanup.json` → `removed:["venv",".cache","repo"]`, weights 不在列表
- 现象 4: workspace 总占用 ~63G, 其中 ~56G 是可回收的残余

---

## 触发条件 / 复现步骤

1. 部署项目中途失败或 paused_for_human,未走完 verify
2. 或 verify 未通过但 state 已标记 done/archived
3. 运行 cleanup → G2/G3/G4 任一门拦住
4. venv/.cache/weights 残留无法回收

---

## 影响

- **影响范围**: 磁盘 (56G 残留)
- **影响下游**: 磁盘满导致新项目部署失败; fetch-weights 下载空间不足
- **严重程度**: P1 — 56G 残留,8×RTX5090 机器磁盘有限

---

## 根因

- **是否已确认**: ✅
- **简述**: cleanup 的 G2/G3/G4 门是为"正常完工"设计的,没有考虑"已 archived 但 verify 没过"或"paused_for_human 但要清场"的场景。结果是已不再活跃的项目无法清场。

  omnivoce 的 weights 漏删是 CC 时代 Agent 执行遗漏 — 白名单里有 weights 但 Agent 没删。

---

## 修复方案

### 实现层修改

- [x] G2 放宽: archived/done 状态只要求 1 阶段结果; force 模式下 3 阶段也可清
- [x] G3 放宽: archived/done + force 模式允许跳过 runbook
- [x] G4 放宽: archived/done 状态直接放行,不要求 verify 通过
- [x] 删除验证: 白名单删除后检查目标是否真的不存在,防止 rm 静默失败

### 文档层修改

- [x] 本 fix 文件
- [ ] Master Plan Fix 索引区更新

---

## 验证步骤

1. `bash hermes/scripts/phase-cleanup.sh omnivoice manual-2026-06-17` → freed=3.1G, removed=1 (weights)
2. `bash hermes/scripts/phase-cleanup.sh qwen3-tts manual-2026-06-17` → freed=26G, removed=3
3. `bash hermes/scripts/phase-cleanup.sh audiox-turbo manual-2026-06-17 false true` → freed=27G, removed=3
4. `du -sh workspace/{audiox-turbo,qwen3-tts,omnivoice}/` → 188K / 280K / 488K

---

## 修复结果

- **状态**: ✅ 已闭环
- **验证证据**: 3 项目手动重跑 cleanup 成功; 总回收 ~56G; workspace 总占用 7.1G(其中 khala 6.7G 在跑不碰)
- **commit hash**: 待 commit

---

## 证据指针

- workspace: `workspace/{audiox-turbo,qwen3-tts,omnivoice}/`
- cleanup 结果: `workspace/*/results/cleanup.json`
- cleanup 日志: `workspace/*/logs/cleanup.log`
- 相关 R 规则: R6 (缓存隔离)

---

## 关联

- **关联 fix**: 2026-06-03-cleanup-no-real-cleanup-and-state-mismatch-fix.md (cleanup 不真清)
- **关联 fix**: 2026-05-26-runs-cache-cleanup-decision-fix.md (runs 缓存清理决策)
- **关联 fix**: 2026-06-17-r6-global-cache-leak-fix.md (同日发现的 R6 缓存泄漏)

---

## 后续动作

- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是 (cleanup 门设计: archived/done 项目应允许宽松清理)
- [ ] **是否需要 L1 / L2 重测验证** → 否 (下次 cron 自动验证)
- [ ] **是否需要写 pending_human** → 否
