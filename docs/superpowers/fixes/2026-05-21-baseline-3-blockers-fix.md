# Baseline 对比 3 个阻塞点 — cache 隔离 / 禁并行 pip / GPU preflight 缺失

## 元信息

- **Fix ID**: `2026-05-21-baseline-3-blockers-fix`
- **创建日期**: 2026-05-21(回填于 2026-05-28)
- **级别**: P0(claude-haha 启动姿势 + 串行带宽核心)
- **状态**: 已闭环
- **负责人 / session**: 用户 + 后续 session

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(SongGen baseline 对比) |
| **触发 run_id** | 5/21 早期 baseline 试跑(ai-intel-deploy 参考方案对比) |
| **触发时间** | 2026-05-21 上午 |
| **触发阶段** | 多阶段(fetch-weights + install-env + intake/preflight) |
| **workspace 路径** | `workspace/song-generation/` |
| **runs 路径** | 多个 5/21 早期 runs |

---

## 现象

- **现象 1(cache 污染)**: 多个 cron run 共用同一 `HF_HOME` 全局 cache,A 跑下半成品 weights,B 跑读到 → 半成品被当成功
- **现象 2(并行 pip 损坏 venv)**: fetch-weights 还在跑时启动 `pip install torch`,2GB CUDA wheels 抢同一根管道 + 并行写同一 site-packages → venv 损坏
- **现象 3(GPU preflight 缺失)**: intake 阶段不检查 GPU 占用,启动后才发现 32GB 显存全占用 → 跑挂

---

## 触发条件 / 复现步骤

1. cron 并发跑两个项目(A + B)
2. 两个 SubAgent 共用全局 `~/.cache/huggingface/`,A 中途崩了留半成品,B 跑 import 时读到崩
3. fetch-weights 启动 background bash 后,SubAgent "顺手"也起 `pip install` → 抢带宽
4. intake 没看 nvidia-smi 直接进 fetch → fetch 完发现 GPU 没空间

---

## 影响

- **影响范围**: 跨 run 数据完整性 + 串行带宽 + 资源 preflight
- **影响下游**: 部署成功率 < 50%;同样问题反复撞
- **严重程度**: P0 — claude-haha 启动姿势 baseline 对比的根本阻塞

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 三个独立问题但**根源都是"边界没明确"**:
  > 1. cache 隔离需要 launch_worker.sh 在 env 层强制设 `HF_HOME=$LOG_DIR/.cache/huggingface`(per-run isolation)
  > 2. 串行带宽规则没写明,LLM 自由发挥并行下载/安装
  > 3. preflight 设计了 skill 但 intake 阶段没 must-call

---

## 修复方案

### 设计层修改

- [x] `.claude/CLAUDE.md` 加 **R5 串行带宽**:fetch-weights 与 install-env 不能并行
- [x] `.claude/CLAUDE.md` 加 **R6 pip 反模式**:
  - 不加 `--no-cache-dir`(launch_worker 已 env 隔离)
  - 不并行多个 `pip install` 写同一 venv
- [x] `.claude/CLAUDE.md` 加 **R7 用 `hf` 不 `huggingface-cli`**
- [x] `.claude/skills/intake/SKILL.md` 强制调用 `preflight-gpu-disk` 子能力

### 实现层修改

- [x] `cron/launch_worker.sh` 强制 `export HF_HOME=$LOG_DIR/.cache/huggingface` + `PIP_CACHE_DIR=$LOG_DIR/.cache/pip` (per-run isolation)
- [x] `preflight-gpu-disk` skill 实现 GPU 占用 + 磁盘 free + gated repo + 30B 阈值四联检查

---

## 验证步骤

1. 并发跑两个项目,验证 `runs/<run-id-A>/.cache/` 与 `runs/<run-id-B>/.cache/` 互不干扰
2. SubAgent 试图并行 `pip install` 时 hook 应拦
3. intake 阶段不调 preflight 直接进 fetch 时,后续 SubAgent 应能从 state.json 看到缺失

---

## 修复结果

- **状态**: ✅ 已落地
- **commit hash**: `8dbe1d5`("修复 3 个 baseline 对比阻塞点(cache 隔离 + 禁并行 pip + GPU pre-flight)")

---

## 证据指针

- 相关 R 规则: `.claude/CLAUDE.md` R5 + R6 + R7
- 相关脚本: `cron/launch_worker.sh`
- 相关 skill: `.claude/skills/intake/SKILL.md` + `.claude/skills/preflight-gpu-disk/SKILL.md`
- baseline 对比: `docs/songgen-e2e-test-guide.md`(参考方案重写)

---

## 关联

- **关联 fix**: [2026-05-26-v1.1-hardening-fix.md](2026-05-26-v1.1-hardening-fix.md)(R5-R7 整合到 v1.1 加固)
- **关联 lessons**: `memory/lessons/torch-sm12.md`(同期沉淀)

---

## 后续动作

- [x] **CLAUDE.md ChangeLog** → 待加(本 session 后续动作)
- [x] **已提升 lessons**: `memory/lessons/torch-sm12.md` 含 cache 隔离相关经验
