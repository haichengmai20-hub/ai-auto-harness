# 产物 completed_at 字段是未求值的 shell 字面量 — "$(date -Iseconds)" 原样写入 JSON

## 元信息

- **Fix ID**: `2026-05-29-completed-at-literal-not-evaluated-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P2(数据字段失真,不阻塞功能)
- **状态**: 进行中
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2(首发) |
| **触发 run_id** | `2026-05-25-1752-*` |
| **触发时间** | 2026-05-26 16:57 |
| **触发阶段** | install-env |
| **workspace 路径** | `workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/2026-05-25-1752-*/` |

---

## 现象

- 现象 1: `workspace/hunyuan3d-2/results/install.json` 的 `completed_at` 字段值是**未求值的字面量** `"$(date -Iseconds)"`,而非实际时间戳
  - 证据: `jq -r '.completed_at' workspace/hunyuan3d-2/results/install.json` → `$(date -Iseconds)`(字符串,不是 ISO 时间)

---

## 触发条件 / 复现步骤

1. install-env SubAgent 写 `install.json` 时,用了单引号或 heredoc 中的 `$(date -Iseconds)`
2. Shell 不求值 → 字面量写入 JSON
3. 下游读 `completed_at` 期望 ISO 时间格式,实际拿到 shell 语法

---

## 影响

- **影响范围**: 数据完整性
- **影响下游**: auto-status 读 `completed_at` 计算用时可能报错;report 显示时间戳为乱码;时间线分析不准
- **严重程度**: P2 — 不阻塞部署,但数据字段无效

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > SubAgent 写 JSON 时用了单引号 heredoc 或 `jq` 之外的字符串拼接,`$(date -Iseconds)` 没被 shell 求值。正确做法是用双引号让 shell 展开,或用 `jq --arg ts "$(date -Iseconds)" '.completed_at = $ts'`。

---

## 修复方案

### 设计层修改

- [ ] 改 `install-env/SKILL.md` §返回 schema:写 JSON 时必须用 `jq --arg` 注入时间戳,禁止 heredoc 内写 `$(date)` 等待求值表达式
- [ ] 改所有 SKILL.md 的落盘步骤:统一用 `jq --arg ts "$(date -Iseconds)"` 模式

### 实现层修改

- [ ] 修 `scripts/validate-*.sh`:加 `completed_at` / `updated_at` 字段校验——值必须是 ISO 8601 格式,不能含 `$(`

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 修后重跑,检查 result JSON:
   ```bash
   jq -r '.completed_at' workspace/<slug>/results/install.json
   # 期望:2026-05-29T... (ISO 格式,不是 $(date -Iseconds))
   ```
2. validate 脚本:
   ```bash
   bash scripts/validate-cleanup.sh workspace/<slug>
   # 期望:completed_at 格式合法
   ```

---

## 修复结果

- **状态**: ❌ 未落地
- **验证证据**: `jq -r '.completed_at' workspace/hunyuan3d-2/results/install.json` → `$(date -Iseconds)`
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/hunyuan3d-2/results/install.json`(completed_at 为字面量)
- 相关 SKILL: `.claude/skills/install-env/SKILL.md`

---

## 关联

- **关联 fix**: [2026-05-27-verify-schema-enforcement-fix.md](2026-05-27-verify-schema-enforcement-fix.md)(同属"SubAgent 落盘 schema 不严谨"类问题)
- **关联 retro**: `workspace/hunyuan3d-2/results/2026-05-27-hunyuan3d-2-deploy-retrospective.md` §6 P2

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(实现细节)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后验证 completed_at 为合法 ISO 时间)
- [ ] **是否需要写 pending_human** → 否
