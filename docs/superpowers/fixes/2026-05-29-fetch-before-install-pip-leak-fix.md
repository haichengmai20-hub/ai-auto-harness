# fetch 先于 install 导致系统级 pip 泄漏 — fetch 阶段无 venv,pip 写入系统目录

## 元信息

- **Fix ID**: `2026-05-29-fetch-before-install-pip-leak-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P1(违反 R6 缓存隔离规则)
- **状态**: 进行中(根因明确,修复方案待实施)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：还没建 venv 就先装 huggingface_hub，装到系统 Python 里了，可能污染别人的环境。

**打比方**：像在自己家装修前先把工具借来放公共走廊，别人走路可能绊倒。

**现在怎样**：fetch 阶段需要 hf 命令，但 venv 要 install 阶段才建，就先 `pip install` 装到全局了。omnivoice 的 fetch 阶段装了 3 次 huggingface_hub。

**要做什么**：改顺序：先建最小 venv 再 fetch，或提前设 PIP_CACHE_DIR 隔离，或 fetch 阶段硬约束"绝不调 pip install"。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice(首发) |
| **触发 run_id** | `2026-05-25-1401-2293813` |
| **触发时间** | 2026-05-25 14:14(fetch_weights 阶段) |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/omnivoice/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/` |

---

## 现象

- 现象 1: OmniVoice transcript 中 `pip install -U huggingface_hub` 出现 **3 次**——全在 fetch_weights 阶段
  - 证据: `grep -c 'pip install -U huggingface_hub' runs/2026-05-25-1401-2293813/transcript.jsonl` → 3
- 现象 2: fetch_weights 排在 install_env 之前执行,此时 venv 尚未创建,pip 只能装到**系统级 Python**(`/usr/lib/python3*/site-packages/`)
  - 证据: install_env 阶段又重新在 venv 里装了一遍 huggingface_hub
- 现象 3: 系统级 pip 安装破坏了隔离——系统 Python 环境被污染,且与 install 阶段 venv 内的版本可能不一致

---

## 触发条件 / 复现步骤

1. auto-deploy/auto-daily 流水线按 `intake → fetch → install → run → verify` 顺序
2. fetch-weights 阶段需要 `huggingface_hub` / `hf` 等下载工具
3. 此时 install-env 阶段尚未执行,venv 不存在
4. fetch SubAgent 调 `pip install -U huggingface_hub` → 写入系统级 Python
5. install-env 阶段建 venv 后又装一遍 → 重复下载 + 版本可能不一致

---

## 影响

- **影响范围**: 缓存隔离 + 环境一致性
- **影响下游**: 系统级 Python 被污染(影响其他项目);重复下载浪费带宽和时间;系统级和 venv 内版本不一致可能导致运行时 import 混乱
- **严重程度**: P1 — 不阻塞部署(omnivoice 跑通了),但违反 R6 缓存隔离规则,且每次 fetch 都泄漏

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 流水线阶段顺序(intake → **fetch** → **install**)导致 fetch 在 install 之前执行。fetch 需要下载工具(hf/huggingface_hub),但此时 venv 未建,只能装到系统级 Python。
  > `launch_worker.sh` 的 `PIP_CACHE_DIR` / `HF_HOME` 环境变量隔离只在 install 阶段生效(R6 来源),fetch 阶段调用 pip 时这些变量尚未设置,缓存直接写入系统 `~/.cache/pip`。

---

## 修复方案

### 设计层修改

- [ ] **方案 A(改阶段顺序)**:把 install-env 提到 fetch-weights 之前 → `intake → install → fetch → run → verify`。fetch 阶段在 venv 内调 `hf download`,不碰系统 pip
  - 优点:彻底消除泄漏;缺点:install 可能装不需要的包(如果 fetch 失败决定不部署)
- [ ] **方案 B(提前设 env 变量)**:在 `launch_worker.sh` 中,fetch 阶段之前就设置 `PIP_CACHE_DIR` / `HF_HOME`,即使 fetch 阶段调 pip 也不会写系统目录
  - 优点:不改阶段顺序;缺点:fetch 仍然用系统 pip(只是缓存隔离了)
- [ ] **方案 C(fetch 不调 pip)**:fetch-weights SKILL.md 加硬约束——"绝不调 pip install",只用系统已有的 `hf` 命令或 Python stdlib。如果 `hf` 不存在 → 写 pending_human 让人装
  - 优点:最干净;缺点:依赖系统预装 `hf`
- [ ] `.claude/CLAUDE.md` R6 扩展:fetch 阶段也不允许系统级 pip install

### 实现层修改

- [ ] (方案 B)修 `cron/launch_worker.sh`:把 `PIP_CACHE_DIR` / `HF_HOME` 设置提前到 fetch 阶段之前(目前只在 install 阶段生效)
- [ ] (方案 A)改 `auto-deploy/SKILL.md` 和 `auto-daily/SKILL.md` 的阶段顺序表
- [ ] (方案 C)改 `fetch-weights/SKILL.md` 加"绝不调 pip"硬约束

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 改后重跑 omnivoice `/auto-deploy`
2. 检查 transcript 中 fetch-weights 阶段是否还有 `pip install`:
   ```bash
   grep 'pip install' runs/<new-run-id>/transcript.jsonl | grep -c fetch
   # 期望: 0
   ```
3. 检查系统级 pip 是否被污染:
   ```bash
   pip list --path /usr/lib/python3*/site-packages/ | grep huggingface
   # 期望: 空(或仅预装版本)
   ```

---

## 修复结果

- **状态**: ❌ 未落地(三种方案待选)
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/omnivoice/`
- runs: `runs/2026-05-25-1401-2293813/`(transcript 含 pip install ×3)
- 相关 SKILL: `.claude/skills/fetch-weights/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R6
- 相关脚本: `cron/launch_worker.sh`

---

## 关联

- **关联 fix**: [2026-05-21-baseline-3-blockers-fix.md](2026-05-21-baseline-3-blockers-fix.md)(R6 pip 反模式来源,但那修的是 install 阶段的隔离,没修 fetch 阶段的泄漏)
- **关联 fix**: [2026-05-29-cache-isolation-boundary-level-fix.md](2026-05-29-cache-isolation-boundary-level-fix.md)(缓存边界问题相关)
- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §5 + §7 P1

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(平台特定)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后重跑 omnivoice 验证无系统级 pip)
- [ ] **是否需要写 pending_human** → 否
