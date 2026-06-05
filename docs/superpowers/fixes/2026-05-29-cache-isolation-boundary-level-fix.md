# 缓存隔离边界选错级 — 按 run 隔离应按项目级/共享,跨 run 重复 + resume 冷重下

## 元信息

- **Fix ID**: `2026-05-29-cache-isolation-boundary-level-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-26/27 retro)
- **级别**: P1(磁盘浪费 + resume 体验差,不阻塞部署)
- **状态**: 进行中(问题已证实,方案待选)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：每次 run 都建一个独立缓存，torch 的 2GB wheel 下了 3 遍存了 3 份，白占 40GB 磁盘。

**打比方**：像每个员工各自买了一整套工具箱放自己工位，而不是共享一个工具房。同样的锤子买了 5 把。

**现在怎样**：`runs/<run-id>/.cache/` 是 run 级隔离，同一个项目跑 3 次就存 3 份相同的权重和 wheel。SongGen 两个 run 分别存了 9GB 和 13GB 相同的模型。

**要做什么**：改成 `workspace/<slug>/.cache/` 项目级共享，或全局共享。同一个项目的多次 run 复用缓存。用 flock 防并发冲突就行。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(跨 run 重复实锤) + hunyuan3d-2 + omnivoice |
| **触发 run_id** | songgen: `songgen-e2e-20260521-124245` + `songgen-e2e-run2-20260521-132245` |
| **触发时间** | 2026-05-21 ~ 2026-05-26(累积发现) |
| **触发阶段** | fetch-weights / install-env(缓存使用阶段) |
| **workspace 路径** | `workspace/song-generation/`、`workspace/song-generation-run2/`、`workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/songgen-e2e-*/`、`runs/2026-05-25-1752-*/` |

---

## 现象

- 现象 1: SongGen 两个 run 的 `.cache/` 分别占 13GB 和 9GB,**经核对装的是同两个模型**(`lglg666/SongGeneration-Runtime` + `SongGeneration-v2-large`)——同项目跨 run 各下一份
  - 证据: `du -sh runs/songgen-e2e-20260521-124245/.cache/` → `9.0G`;`du -sh runs/songgen-e2e-run2-20260521-132245/.cache/` → `13G`;两目录下模型目录名相同
- 现象 2: resume = 新 run = 空 cache = 重下。Hunyuan3D-2 跨 `/auto-recover` 接续时,新 run 的 cache 为空,如果不用 `--local-dir` 绕过就得重下 19GB
- 现象 3: 实际执行不统一(songgen 走标准 HF→落 per-run cache;hunyuan 用 `--local-dir`→绕过;全局默认缓存还混进 126GB)
  - 证据: `du -sh /root/.cache/huggingface/` → `126G`(含非 harness 的 gemma 49GB + 归属不明的 t5-xxl 45GB)

---

## 触发条件 / 复现步骤

1. `launch_worker.sh` 把所有缓存指向 `runs/<run-id>/.cache/`:
   ```
   HF_HOME / HF_HUB_CACHE / PIP_CACHE_DIR / ... → runs/<run-id>/.cache/*
   ```
2. 每跑一次 run,连模型权重缓存、pip wheel 都各开一份新的
3. 同项目跑第二次 → 重新下载全部权重 + wheel(尽管内容完全相同)
4. resume 接续 → 新 run ID → 新空 cache → 又重下

---

## 影响

- **影响范围**: 磁盘 + 带宽 + 时间
- **影响下游**: 每跑一次 cron 累积 ~20GB;跑 5 次就 100GB;resume 体验极差(冷重下);磁盘满可能触发 R3 磁盘阈值误判
- **严重程度**: P1 — songgen 跨 run 重复 22GB 是实锤,但不阻塞当前部署

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 三层分析(见 polling-handoff-analysis.md §7):
  > 1. **规则(要不要隔离缓存)**——可辩护的权衡,不算错(当初隔离是为了躲并发下载的锁竞争)
  > 2. **边界/粒度(隔到哪一级)**——**这是主要错误**:把下载缓存隔到了 run 级,应该隔到项目级或共享全局。后果:跨 run 重复 + resume 重下
  > 3. **执行(隔离有没有守住)**——有小泄漏(部分下载漏进全局默认缓存),但量级小,不是主要矛盾

---

## 修复方案

### 设计层修改

- [ ] **理想布局**:
  - venv:维持每项目隔离(对)
  - HF 权重 / pip wheel:把隔离边界从 run 级改成**全机一份共享 CAS 缓存 + 各项目 symlink**(存一份、各看各的)
  - 并发下载:用**文件锁 / 排程串行**协调(R5 已要求串行),而不是靠按 run 多复制几份来躲并发
- [ ] `.claude/CLAUDE.md` R6 扩展:缓存隔离边界应为项目级或共享,不是 run 级

### 实现层修改

- [ ] 修 `cron/launch_worker.sh`:
  - 方案 A:HF 权重缓存指向 `workspace/<slug>/.cache/huggingface/`(项目级)
  - 方案 B:HF 权重缓存指向全局 `/root/.cache/huggingface/`(共享),加 flock 防并发冲突
  - pip wheel 缓存同理
- [ ] 修 `cleanup-deployed-workspace/SKILL.md`:清理目标调整(项目级 cache 归 workspace 清理,全局 cache 不动)

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 改后跑 SongGen 两次(同项目不同 run):
   ```bash
   # 第二次 run
   du -sh runs/<run2-id>/.cache/
   # 期望:远小于 13GB(不再重复存权重)
   ```
2. 验证共享缓存不冲突:两个 run 同时 fetch 不同项目 → 无锁竞争错误

---

## 修复结果

- **状态**: ❌ 未落地(方案待选:A 项目级 vs B 全局共享)
- **验证证据**: songgen 跨 run 重复 22GB 已证实
- **commit hash**: 待落地

---

## 证据指针

- runs: `runs/songgen-e2e-20260521-124245/.cache/`(9GB) + `runs/songgen-e2e-run2-20260521-132245/.cache/`(13GB)
- 全局缓存: `/root/.cache/huggingface/`(126GB,含非 harness 内容)
- 相关脚本: `cron/launch_worker.sh`
- 相关 R 规则: `.claude/CLAUDE.md` R5(串行带宽) + R6(pip 反模式)
- 相关 SKILL: `.claude/skills/cleanup-deployed-workspace/SKILL.md`

---

## 关联

- **关联 fix**: [2026-05-21-baseline-3-blockers-fix.md](2026-05-21-baseline-3-blockers-fix.md)(R5/R6 来源,修了 per-run 隔离实现,但没修"边界应在哪级")
- **关联 fix**: [2026-05-26-runs-cache-cleanup-decision-fix.md](2026-05-26-runs-cache-cleanup-decision-fix.md)(修了 runs/.cache 残留清理,但没修"为什么 run 级隔离导致重复")
- **关联 fix**: [2026-05-29-fetch-before-install-pip-leak-fix.md](2026-05-29-fetch-before-install-pip-leak-fix.md)(pip 泄漏相关)
- **关联分析**: `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md` §7

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(缓存隔离策略选择是通用架构教训)
- [ ] **是否需要 L1 / L2 重测验证** → 是(改后验证跨 run 不重复 + resume 不重下)
- [ ] **是否需要写 pending_human** → 否
