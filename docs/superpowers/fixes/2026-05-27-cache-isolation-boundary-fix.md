# OmniVoice pip 缓存隔离边界泄漏 — fetch 阶段 PIP_CACHE_DIR 未设置,泄漏到系统目录

## 元信息

- **Fix ID**: `2026-05-27-cache-isolation-boundary-fix`
- **创建日期**: 2026-05-27(回填自 OmniVoice retro)
- **级别**: P1(违反 R6 缓存隔离规则)
- **状态**: 已闭环(根因分析已记录,修复方案归入 fetch-before-install-pip-leak-fix)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice |
| **触发 run_id** | `2026-05-25-1401-2293813` |
| **触发时间** | 2026-05-25 14:14 |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/omnivoice/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/` |

---

## 现象

- 现象 1: fetch 阶段调 `pip install -U huggingface_hub` ×3,此时 venv 不存在,缓存写入系统级 `~/.cache/pip`
- 现象 2: `launch_worker.sh` 的 `PIP_CACHE_DIR` 只在 install 阶段生效,fetch 阶段未设置

---

## 触发条件 / 复现步骤

1. fetch-weights 在 install-env 之前执行
2. launch_worker.sh 只在 install 阶段设 `PIP_CACHE_DIR`
3. fetch 阶段调 pip → 写入系统 ~/.cache/pip

---

## 影响

- **影响范围**: 缓存隔离(R6 规则)
- **影响下游**: 系统级 pip 被污染;与 install 阶段 venv 内版本可能不一致
- **严重程度**: P1 — 违反 R6

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > `launch_worker.sh` 的缓存隔离依赖 `PIP_CACHE_DIR` 环境变量,但该变量只在 install 阶段生效。fetch 阶段调用 pip 时尚未设置。

---

## 修复方案

> 修复方案归入更全面的 [2026-05-29-fetch-before-install-pip-leak-fix.md](2026-05-29-fetch-before-install-pip-leak-fix.md),该 fix 解决了根本问题(阶段顺序或提前设 env)。

### 设计层修改

- [x] 根因分析已记录(见关联 fix)

### 实现层修改

- [ ] 修 `launch_worker.sh`:把 `PIP_CACHE_DIR` / `HF_HOME` 设置提前到 fetch 阶段之前(方案 B)——归入 fetch-before-install-pip-leak-fix

---

## 验证步骤

见 [2026-05-29-fetch-before-install-pip-leak-fix.md](2026-05-29-fetch-before-install-pip-leak-fix.md) 验证步骤

---

## 修复结果

- **状态**: ✅ 已闭环(根因分析完成,修复归入关联 fix)
- **验证证据**: 根因已确认
- **commit hash**: 待关联 fix 落地

---

## 证据指针

- workspace: `workspace/omnivoice/`
- runs: `runs/2026-05-25-1401-2293813/`
- 相关 R 规则: `.claude/CLAUDE.md` R6
- 相关脚本: `cron/launch_worker.sh`

---

## 关联

- **关联 fix**: [2026-05-29-fetch-before-install-pip-leak-fix.md](2026-05-29-fetch-before-install-pip-leak-fix.md)(本 fix 的修复归入该更全面的 fix)
- **关联 fix**: [2026-05-21-baseline-3-blockers-fix.md](2026-05-21-baseline-3-blockers-fix.md)(R6 来源)
- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §5

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(根因分析)
- [x] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [x] **不提升到 memory/lessons**
- [x] **不需要 L1 / L2 重测验证**(归入关联 fix)
- [x] **不需要写 pending_human**
