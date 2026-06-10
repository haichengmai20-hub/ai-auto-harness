# run.json 过程字段失真 — 标称 0 修复 vs 实际有脚本适配

## 元信息

- **Fix ID**: `2026-05-29-run-json-process-field-inaccurate-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P2(数据失真,不阻塞部署但误导后人)
- **状态**: ✅ 已闭环(规范层;transcript 交叉校验为可选增强未做)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：写着"修复 0 次"，实际有修复；写着"耗时 0 分钟"，实际跑了 2 小时。

**打比方**：像工作报告写"今天没加班"，实际上加班到凌晨 2 点。后人看报告以为项目很简单。

**现在怎样**：run.json 的 `fixes_count` 和 `duration_min` 字段没正确统计。LLM 修改了脚本 52 次，但 repair_log 是空的。

**要做什么**：在 SubAgent return 时正确计算并写入。repair_log 的定义要扩大到"任何改变运行时代码/配置的动作"。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice(首发) |
| **触发 run_id** | `2026-05-25-1401-2293813` |
| **触发时间** | 2026-05-25 ~15:55 |
| **触发阶段** | run-and-repair |
| **workspace 路径** | `workspace/omnivoice/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/` |

---

## 现象

- 现象 1: `workspace/omnivoice/results/run.json` 写 `rounds_attempted=1 / repair_log=[] / error=null`,但 transcript 显示有真实脚本适配(soundfile×52 次)
  - 证据: `jq '.rounds_attempted, .repair_log' workspace/omnivoice/results/run.json` → `1, []`;transcript grep `soundfile` → 52 hits
- 现象 2: install_env 3 次暂停重入的过程在 result JSON 中不可见——只看 JSON 会以为一帆风顺
  - 证据: `workspace/omnivoice/results/install.json` 无暂停/重入记录

---

## 触发条件 / 复现步骤

1. run-and-repair 阶段,LLM 修改了脚本(soundfile 适配)但没记录到 repair_log
2. install-env 阶段暂停 3 次重入,但结果 JSON 只记终态
3. run.json 写"0 修复"美化真实过程

---

## 影响

- **影响范围**: 数据完整性 + 可观测性
- **影响下游**: 后人读 run.json 以为"一次跑通",低估项目难度;runbook 抽取时漏踩坑;report 的修复轮数不准
- **严重程度**: P2 — 不阻塞功能,但数据失真

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > run-and-repair SKILL.md 的 repair_log 记录规则不够细致:LLM 的"脚本层适配"(改 import / 换 library)不算"修复轮次"(SKILL 只计数 `python entry_script.py` 的失败重试),但实质上改变了运行时行为。repair_log 的定义需要扩大到"任何改变运行时代码/配置的动作"。

---

## 修复方案

### 设计层修改

- [ ] 改 `run-and-repair/SKILL.md` §返回 schema:repair_log 定义扩大——不只记录"重试 python entry",也记录"脚本适配"(修改 import / 换 library / 改 config / patch 代码)
- [ ] 改 `run-and-repair/SKILL.md` 加反模式:"❌ 不要把有真实适配的部署写成 0 修复"

### 实现层修改

- [ ] 修 `scripts/validate-*.sh`:加 repair_log 与 transcript 交叉校验(检测"transcript 有代码修改但 repair_log 为空"的不一致)

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 改后重跑 omnivoice run-and-repair
2. 检查 `run.json`:
   ```bash
   jq '.repair_log | length' workspace/omnivoice/results/run.json
   # 期望: > 0(至少 1 条 soundfile 适配)
   ```

---

## 修复结果

- **状态**: ✅ 成功(统计口径已定义)
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/omnivoice/`(run.json 标称 0 修复 vs transcript soundfile×52)
- 相关 SKILL: `.claude/skills/run-and-repair/SKILL.md`

---

## 关联

- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §6 P2

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(数据记录规范)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后重跑验证 repair_log 非空)
- [ ] **是否需要写 pending_human** → 否

---

## 闭环补记(2026-06-10)

- **run-and-repair/SKILL.md**:返回 schema 后加统计口径硬规定 — 任何适配动作(改 import/换版本/改 config/patch 代码/改 batch_size/写 wrapper)都计入 `fixes_applied`,`repair_count`=修复轮数;引 omnivoice 52 处适配记 0 的实测翻车
- **反模式** +1:"有真实适配却写 repair_count=0"
- **残留(可选增强,不阻塞)**:repair_log 与 transcript 的自动交叉校验脚本未做 — 口径靠 SKILL 约束 + review
