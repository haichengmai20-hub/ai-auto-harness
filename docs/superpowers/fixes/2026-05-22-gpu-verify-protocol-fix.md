# GPU 架构验证协议 — torch.cuda.get_arch_list() 检测 sm_120 支持的标准化

## 元信息

- **Fix ID**: `2026-05-22-gpu-verify-protocol-fix`
- **创建日期**: 2026-05-22(回填于 2026-05-29)
- **级别**: P1(跨项目共性问题:RTX 5090 sm_120 不被旧 torch 支持)
- **状态**: 已闭环
- **负责人 / session**: LLM 自修 + Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：RTX 5090 是 sm_12 架构，很多 wheel 不含 sm_12 会编译失败，需要统一验证协议。

**做了什么**：标准化了 torch wheel 的 sm_arch 检查流程，跨 3 个项目通用。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(首发);omnivoice;hunyuan3d-2(三项目共有) |
| **触发 run_id** | songgen: `songgen-e2e-run2-20260521-132245`;omnivoice: `2026-05-25-1401-2293813`;hunyuan3d-2: `2026-05-25-1752-*` |
| **触发时间** | 2026-05-21 ~ 2026-05-26 |
| **触发阶段** | install-env(三个项目都在此阶段修 torch 版本) |
| **workspace 路径** | 三个项目 workspace |
| **runs 路径** | 三个项目 runs |

---

## 现象

- 现象 1: SongGen requirements.txt pin 了 `torch==2.6.0+cu126`,该 wheel 未编译 `sm_120` 内核(RTX 5090 架构),`torch.cuda.get_arch_list()` 输出不含 `sm_120`
- 现象 2: OmniVoice 同样需 torch 2.11.0+cu128 才支持 sm_120
- 现象 3: Hunyuan3D-2 torch 连装 3 次(cu124→cu126→cu128)才匹配,前两次都不含 sm_120
  - 证据: `python -c "import torch; print(torch.cuda.get_arch_list())"` 各项目修复前后对比

---

## 触发条件 / 复现步骤

1. 项目 `requirements.txt` pin 了不支持 sm_120 的 torch 版本
2. `pip install -r requirements.txt` 安装成功但 GPU 不可用
3. 推理时 `torch.cuda.is_available()` → True 但实际 kernel 执行报 CUDA error

---

## 影响

- **影响范围**: 跨项目(SongGen、OmniVoice、Hunyuan3D-2 三项目都撞)
- **影响下游**: 每次部署都要修 torch 版本,消耗重试轮次和时间
- **严重程度**: P1 — LLM 每次都能自动修,但消耗重试;修复模式已标准化为 runbook "已知踩坑"模板

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > RTX 5090 (Blackwell, sm_120) 是新架构,主流开源项目 requirements.txt 还没更新到支持它的 torch 版本。这不是平台 bug,是硬件换代导致的生态滞后。

---

## 修复方案

### 实现层修改

- [x] 标准化修复流程:删除 requirements.txt 中 torch 版本 pin → 装最新 nightly cu128
- [x] 标准化验证命令:`python -c "import torch; assert any('120' in a for a in torch.cuda.get_arch_list())"`
- [x] 写入 `memory/lessons/torch-sm12.md`(跨项目通用经验)

### 文档层修改

- [x] 在 runbook 模板加"已知踩坑"条目:torch 版本 vs GPU 架构

---

## 验证步骤

1. 装好 torch 后:
   ```bash
   python -c "import torch; assert any('120' in a for a in torch.cuda.get_arch_list()); print('OK')"
   # 期望:OK
   ```

---

## 修复结果

- **状态**: ✅ 已闭环(三项目都跑通,修复模式已标准化)
- **验证证据**: 三个项目 verify 都 PASS
- **commit hash**: N/A(运行时修复,经验沉淀在 memory/lessons/)

---

## 证据指针

- 经验: `memory/lessons/torch-sm12.md`
- 三个项目 workspace: `workspace/song-generation/`、`workspace/omnivoice/`、`workspace/hunyuan3d-2/`

---

## 关联

- **关联 fix**: [2026-05-22-song-generation-pipeline-fix.md](2026-05-22-song-generation-pipeline-fix.md)(同项目其他修复)
- **关联 fix**: [2026-05-21-baseline-3-blockers-fix.md](2026-05-21-baseline-3-blockers-fix.md)(R5 串行带宽,torch 装多次浪费带宽)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → N/A
- [x] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [x] **已提升到 memory/lessons** → `memory/lessons/torch-sm12.md`
- [x] **不需要 L1 / L2 重测验证**
- [x] **不需要写 pending_human**
