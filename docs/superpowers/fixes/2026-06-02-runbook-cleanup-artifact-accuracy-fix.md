# 部署产物准确性:runbook cost=0.0/duration 失真 + cleanup weights 白名单泄漏

## 元信息

- **Fix ID**: `2026-06-02-runbook-cleanup-artifact-accuracy-fix`
- **创建日期**: 2026-06-02
- **级别**: P2
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-02(回填另一 session 已完成的 P6/P7 改动)

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2(cost/duration)+ omnivoice(weights 泄漏) |
| **触发 run_id** | `runbook-hunyuan3d-20260529-1927` / `cleanup-omnivoice-20260529-1948` |
| **触发时间** | 2026-05-29(实测)→ 2026-06-02(回填记录) |
| **触发阶段** | runbook / cleanup |
| **workspace 路径** | `workspace/hunyuan3d-2/` / `workspace/omnivoice/` |
| **runs 路径** | `runs/runbook-hunyuan3d-20260529-1927/` / `runs/cleanup-omnivoice-20260529-1948/` |

---

## 现象

- 现象 1(P6-1): hunyuan3d-2 runbook frontmatter 写 `total_cost_usd: 0.0`,实为交互式 session 无 cost 数据,`0.0` 误导成"免费"。
- 现象 2(P6-3): 同 runbook `duration_min: 1469`(~24h),实际是时间戳来源选错(混用 AI prompt 节里的"预计耗时")。
- 现象 3(P7-1/问题13): omnivoice cleanup `freed 7.9GB` 但留下 `weights/` 3.1GB —— 白名单只有 4 项(`venv .cache hf_cache repo`),`weights/` 不在内,可重建产物泄漏。

---

## 触发条件 / 复现步骤

1. 交互式 session(无 `result` 事件 cost)跑完 → runbook agent 取不到 cost → 模仿模板示例写 `0.0`。
2. runbook agent 计算 duration 时取了 AI prompt 节的"预计耗时"而非 `state.json` 实际时间戳。
3. fetch-weights 把权重落在 `workspace/<slug>/weights/`,cleanup 白名单未含 `weights` → 跳过未清。

---

## 影响

- **影响范围**: 部署产物(runbook / cleanup.json)数据准确性 + 磁盘回收完整性。
- **影响下游**: runbook 读者据 `0.0` 误判成本;`weights/` 残留每项目泄漏 ~3GB。
- **严重程度**: P2 — 不阻断流水线,但产物失真 + 渐进式磁盘泄漏。

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 1. runbook `_template.md` 用 `{{TOTAL_COST_USD}}` 占位符本身没问题,但 SKILL.md 没规定"取不到时写 `null` 不写 `0.0`",LLM 自由发挥成 `0.0`。
  > 2. SKILL.md 没规定 duration 唯一权威来源 = `state.json.started_at/updated_at`,LLM 混用预估值。
  > 3. cleanup 白名单是写死枚举(防 `rm -rf` 事故的正确设计),但漏列了 `weights` 这个可重建目录。

---

## 修复方案

### 设计层修改(SKILL.md)

- [x] `write-deploy-runbook/SKILL.md` 第 2 步加 `total_cost_usd` 填写规则:取不到写 `null`,严禁 `0.0`。
- [x] `write-deploy-runbook/SKILL.md` 第 2 步加 `duration_min` 填写规则:唯一来源 `state.json` 时间戳,严禁用 AI prompt 的"预计耗时"。
- [x] `cleanup-deployed-workspace/SKILL.md` 白名单 `venv .cache hf_cache repo` → 加 `weights`(4→5 targets),同步反模式段与 return schema 示例。
- [x] 两 SKILL 末尾加 `## ChangeLog` 章节(本 fix 驱动)。

### 实现层修改

- 无(纯 prompt 规则 + 白名单枚举改动)。

---

## 验证步骤

1. 重跑一次交互式 runbook 生成 → frontmatter `total_cost_usd: null`(非 0.0)。
2. `duration_min` 与 `state.json` 时间戳差值一致(分钟)。
3. 含 `weights/` 的 workspace 跑 cleanup → `cleanup.json.removed` 含 `weights`,workspace 残留无 `weights/`。
4. `bash scripts/validate-runbook.sh <runbook> <runbook.json>` 通过。

---

## 修复结果

- **状态**: ✅ 成功(改动由前序 session 完成,本 fix 回填记录 + 补 ChangeLog + commit)。
- **commit hash**: <填 WS0 commit>
- **commit message**: `ai-auto: P6/P7 收尾 — cleanup weights 白名单 + runbook cost=null/duration + e2e 脚本入库`

---

## 证据指针

- workspace: `workspace/hunyuan3d-2/` / `workspace/omnivoice/`
- runs: `runs/runbook-hunyuan3d-20260529-1927/` / `runs/cleanup-omnivoice-20260529-1948/`
- 相关 SKILL: `.claude/skills/write-deploy-runbook/SKILL.md` / `.claude/skills/cleanup-deployed-workspace/SKILL.md`
- 相关 retro: ControlFoley e2e 2026-06-02 retro(问题 11/12/13)

---

## 关联

- **关联 fix**: [2026-05-29-g2-trace-format-flexible-fix](2026-05-29-g2-trace-format-flexible-fix.md)(同属 runbook/cleanup 产物准确性簇)
- **关联 spec/plan ChangeLog 条目**: `write-deploy-runbook/SKILL.md` + `cleanup-deployed-workspace/SKILL.md` ChangeLog(2026-06-02)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [ ] **Master Plan Fix 索引区已更新** → ⬜ WS3 统一更新
- [x] **是否提升到 memory/lessons** → 否(产物规则,SKILL 已固化)
- [x] **是否需要 L1 / L2 重测验证** → 否(下次 e2e 自然覆盖)
