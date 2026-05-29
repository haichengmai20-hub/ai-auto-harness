# SongGeneration 部署流水线阻塞 — torchcodec 缺失 + symlink 损坏

## 元信息

- **Fix ID**: `2026-05-22-song-generation-pipeline-fix`
- **创建日期**: 2026-05-22(回填于 2026-05-29)
- **级别**: P1(项目级阻塞,LLM 可自行解决但每次都要修)
- **状态**: 已闭环
- **负责人 / session**: LLM 自修 + Claude session @ 2026-05-29 回填

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation |
| **触发 run_id** | `songgen-e2e-run2-20260521-132245` |
| **触发时间** | 2026-05-21 ~ 2026-05-22 |
| **触发阶段** | run-and-repair |
| **workspace 路径** | `workspace/song-generation/` |
| **runs 路径** | `runs/songgen-e2e-run2-20260521-132245/` |

---

## 现象

- 现象 1: 推理代码 `import torchcodec` 但项目 `requirements.txt` 未声明该依赖
  - 证据: `python -c "import torchcodec"` → ModuleNotFoundError;`grep torchcodec requirements.txt` → 空
- 现象 2: 仓库中 `third_party/sorted_umis` 是一个 symlink,指向不存在的路径,导致 import 失败
  - 证据: `ls -la third_party/sorted_umis` → 指向不存在目标

---

## 触发条件 / 复现步骤

1. `git clone` SongGeneration repo
2. `pip install -r requirements.txt`
3. `python entry_script.py` → `import torchcodec` 失败
4. `import third_party.sorted_umis` → symlink 损坏

---

## 影响

- **影响范围**: 项目部署(运行时 import 错误)
- **影响下游**: 推理无法启动
- **严重程度**: P1 — LLM 可自行解决(pip install + 重建 symlink),但属于项目本身的依赖声明缺陷

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 项目 requirements.txt 遗漏了 torchcodec 依赖;symlink 损坏可能是 repo 迁移或 .gitattributes 处理问题。都是项目本身的问题,不是平台缺陷。

---

## 修复方案

### 实现层修改

- [x] `pip install torchcodec` 补装缺失依赖
- [x] 重建 symlink 指向正确路径

### 文档层修改

- [x] 写入 `workspace/song-generation/logs/fixes.log`
- [x] 写入 `memory/lessons/torch-sm12.md`(作为"项目依赖声明不完整"的经验)

---

## 验证步骤

1. `python -c "import torchcodec; print('OK')"` → OK
2. `ls third_party/sorted_umis/` → 目录内容可列

---

## 修复结果

- **状态**: ✅ 已闭环(LLM 自行修复)
- **验证证据**: SongGen run3 跑通,81.7s FLAC 输出
- **commit hash**: N/A(LLM 运行时修复,非代码 commit)

---

## 证据指针

- workspace: `workspace/song-generation/`
- runs: `runs/songgen-e2e-run2-20260521-132245/`
- 修复日志: `workspace/song-generation/logs/fixes.log`
- 经验: `memory/lessons/torch-sm12.md`

---

## 关联

- **关联 fix**: [2026-05-21-baseline-3-blockers-fix.md](2026-05-21-baseline-3-blockers-fix.md)(同期 SongGen 部署问题)
- **关联 fix**: [2026-05-22-gpu-verify-protocol-fix.md](2026-05-22-gpu-verify-protocol-fix.md)(同项目 GPU 验证协议)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → N/A(项目级修复,不改 spec/plan)
- [x] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [x] **已提升到 memory/lessons** → `memory/lessons/torch-sm12.md`
- [x] **不需要 L1 / L2 重测验证**
- [x] **不需要写 pending_human**
