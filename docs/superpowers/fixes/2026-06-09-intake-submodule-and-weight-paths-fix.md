# intake git submodule 未初始化 + weight_target_paths 捕获不足

## 元信息

- **Fix ID**: `2026-06-09-intake-submodule-and-weight-paths-fix`
- **创建日期**: 2026-06-09
- **级别**: P2
- **状态**: 进行中
- **负责人 / session**: Claude session @ 2026-06-09

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：克隆代码时漏拉子模块，下载权重后路径也对不上

**打比方**：买了个宜家家具，但配件包没拆封（子模块），而且安装图上的螺丝孔位和实际孔位对不上（权重路径）

**现在怎样**：git clone --depth=1 不拉 submodule 导致运行时报 ModuleNotFoundError；HF 下载的权重目录结构与模型代码期望的路径不一致，靠 SubAgent 即兴建 symlink 修复

**要做什么**：intake 阶段 clone 后自动 git submodule update；intake 的 weight_target_paths 步骤加强推理逻辑

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | magenta-realtime |
| **触发 run_id** | e2e-magenta-20260608-111127 |
| **触发时间** | 2026-06-08 11:11(+08:00) |
| **触发阶段** | run-and-repair |
| **workspace 路径** | `workspace/magenta-realtime/` |
| **runs 路径** | `workspace/magenta-realtime/runs/e2e-magenta-20260608-111127/` |

---

## 现象

### 现象 A：git submodule 未初始化

- 现象 A1: `ModuleNotFoundError: No module named 'sequence_layers'`
  - 证据: `workspace/magenta-realtime/logs/run_and_repair.log` — `import sequence_layers.jax as sl` 失败
  - 证据: `workspace/magenta-realtime/logs/fixes.log` — `round=1 | fix=Initialized git submodule sequence-layers (was empty dir)`
- 现象 A2: 项目 vendored 了 `sequence_layers` 作为 git submodule（`magenta_rt/_vendor/sequence-layers`），但 `git clone --depth=1` 默认不拉 submodule，目录为空

### 现象 B：权重路径与模型加载路径不一致

- 现象 B1: 模型加载代码期望 `$MAGENTA_HOME/magenta-rt-v2/checkpoints/mrt2_small.safetensors`，但 HF 下载后权重在 `.cache/hf_models/google/magenta-realtime-2/` 下
  - 证据: `workspace/magenta-realtime/logs/run_and_repair.log` — `FileNotFoundError: No such file or directory: .../.cache/magenta-rt-v2/checkpoints/mrt2_small.safetensors`
- 现象 B2: intake.json 的 `weight_target_paths` 为空，标了 `warnings: ["weight_paths_unknown"]`
  - 证据: `workspace/magenta-realtime/results/intake.json` — 无 weight_target_paths 字段
- 现象 B3: run-and-repair SubAgent 即兴创建了两层 symlink 修复
  - 证据: `workspace/magenta-realtime/results/run.json` fixes_applied — "Created symlink .cache/magenta-rt-v2 -> .cache/models; Symlinked mrt2_base.safetensors from hf_models into .cache/models/checkpoints/"

---

## 触发条件 / 复现步骤

### 现象 A 复现

1. 任何含 git submodule 的项目
2. intake SKILL.md 第 2 步只执行 `git clone --depth=1`，无 `git submodule update`
3. 运行时代码 `import` submodule 内的模块 → ModuleNotFoundError

### 现象 B 复现

1. 任何 inference 代码 hardcode 权重相对路径的项目
2. intake SKILL.md 第 5.5 步用 `grep -rnE "ckpt/|weights/|models/|checkpoints/"` 搜索 hardcode 路径
3. magenta-realtime 的加载路径 `magenta-rt-v2/checkpoints/` 不在 grep pattern 里（是项目特有的子目录名）
4. intake 无法捕获 → weight_target_paths 为空 → fetch 下载到默认路径 → run 时找不到

---

## 影响

- **影响范围**: 可靠性 — run-and-repair 第 1 轮必失败，浪费 1 轮修复预算
- **影响下游**: run-and-repair（需要即兴修复）、verify（如果 run 阶段修不好就 fail）
- **严重程度**: P2 — 不致命（SubAgent 能即兴修），但浪费修复轮次和 token

---

## 根因

- **是否已确认**: ✅

### 现象 A 根因

intake SKILL.md 第 2 步只执行 `git clone --depth=1 "$GITHUB_URL" repo`，没有 `git submodule update --init --recursive`。这是**所有含 git submodule 的项目的共性问题**。

### 现象 B 根因

intake SKILL.md 第 5.5 步的 grep pattern `ckpt/|weights/|models/|checkpoints/|pretrained/` 覆盖了常见路径，但项目特有的子目录名（如 magenta-rt-v2）无法穷举。更深层的根因是：**weight_target_paths 的推理依赖静态 grep，无法理解项目代码的运行时路径拼接逻辑**（如 `$MAGENTA_HOME/magenta-rt-v2/checkpoints/`）。

---

## 修复方案

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [ ] 改 `intake/SKILL.md` 第 2 步: clone 后加 `git submodule update --init --recursive 2>&1 | tee -a "$LOG"`
- [ ] 改 `intake/SKILL.md` 第 5.5 步: 加"读 README/代码中的环境变量路径映射"子步骤（如 `MAGENTA_HOME`、`TRANSFORMERS_CACHE` 等环境变量影响权重加载路径的，要提取出来写入 weight_target_paths）
- [ ] 改 `fetch-weights/SKILL.md`: 加"intake 的 weight_target_paths 非空时，下载完成后按映射建 symlink"步骤

### 实现层修改(代码 / 脚本 / 配置)

- 无代码修改（纯 SKILL.md 修改）

### 文档层修改(retro / lessons / handoff)

- [ ] 不提升到 lessons — git submodule 是通用问题但修复简单，weight_target_paths 是已知弱项

---

## 验证步骤(必须可复现)

1. 读 intake SKILL.md 第 2 步，确认 clone 后有 `git submodule update`
2. 读 intake SKILL.md 第 5.5 步，确认有环境变量路径映射子步骤
3. 重跑 magenta-realtime 或其他含 submodule 的项目，确认 intake 阶段 submodule 已初始化

---

## 修复结果

- **状态**: ⬜ 待实施
- **验证证据**: 待改后重跑验证
- **commit hash**: `<pending>`
- **commit message**: `<pending>`

---

## 证据指针(必填)

- workspace: `workspace/magenta-realtime/`
- runs: `workspace/magenta-realtime/runs/e2e-magenta-20260608-111127/`
- 日志: `workspace/magenta-realtime/logs/run_and_repair.log`（ModuleNotFoundError + FileNotFoundError）
- 日志: `workspace/magenta-realtime/logs/fixes.log`（git submodule init 修复记录）
- 结果: `workspace/magenta-realtime/results/run.json`（fixes_applied 字段）
- 结果: `workspace/magenta-realtime/results/intake.json`（weight_target_paths 缺失）
- 相关 SKILL: `.claude/skills/intake/SKILL.md`
- 相关 SKILL: `.claude/skills/fetch-weights/SKILL.md`

---

## 关联

- **关联 fix**: 2026-06-08-fetch-dest-path-not-injected-fix（同一次 magenta-realtime 部署暴露的 DEST 路径问题）
- **关联 fix**: 2026-06-08-proxy-hf-download-503-fix（同一次部署的代理问题）
- **关联 spec/plan ChangeLog 条目**: 待改 intake SKILL.md 时加

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加（实施时加到 intake SKILL.md）
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否（git submodule 是已知通用问题，修复简单）
- [ ] **是否需要 L1 / L2 重测验证** → 是（重跑 magenta-realtime 或其他含 submodule 项目）
- [ ] **是否需要写 pending_human** → 否
