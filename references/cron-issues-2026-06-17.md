# ai-auto-harness 框架改进记录 — 2026-06-17 Cron 实测

## 来源
- 09:00 ai-daily-scan cron (第2次自动触发)
- 10:00 ai-auto-harness cron (第1次自动触发，VoxCPM2 项目)

---

## 一、已确认的老问题（再次复现）

### F13/P0: entry_script 推断不准（Gradio vs 推理脚本）

**复现次数**: 3 次（audiox-turbo 06-16, voxcpm 06-17 两次）

**现象**: intake 把 `app.py`/`run_gradio.py` 推断为 entry_script，但这些是 Gradio Web UI，不是独立推理脚本。run-and-repair 用它们直接跑 → `NameError: name 'app' is not defined`。

**实际修复路径**: run-and-repair agent 自己写了 custom entry_script（调用 `voxcpm.core.VoxCPM.from_pretrained()` + `.generate()` + `sf.write()`），但 verify 的 smoke test 默认还用原始 app.py。

**改进方案**:
1. intake 加 `entry_type` 分类: `script/gradio/service/docker`，Gradio 项目自动标记需 custom script
2. run-and-repair 生成 custom script 后，verify 阶段应读 run_and_repair.json 的 entry_script 字段（而非 intake 的原始推断）
3. verify 阶段传入 `CUDA_VISIBLE_DEVICES` 从 gpu_picks — 这次 cron agent 临时 patch 了 phase-verify.sh

### F16/P1: 磁盘估算偏差

**复现**: audiox-turbo 预估 5GB 实际 22GB（4.4x），voxcpm 4.96GB（较准）。F16 建议 1.5-2x 乘数仍不够，应查 HF API 获取实际 repo size。

---

## 二、新发现的问题

### F20/P1: verify 不读 run-and-repair 的 custom entry_script

**现象**: run-and-repair 成功写了 custom script（`inference_passed=true`），但 verify 的 smoke test 还用 intake 推断的 `app.py` → 第一次 verify failed。Cron agent 手动 patch phase-verify.sh 加了 `CUDA_VISIBLE_DEVICES` 后重跑才 passed。

**根因**: phase-verify.sh 读 state.json 的 entry_script（来自 intake），没读 run_and_repair.json 里的 custom script。

**改进**: verify 阶段应优先读 `results/run_and_repair.json` 的 `entry_script` 字段，fallback 到 intake 的。

### F21/P1: phase-fetch-weights.sh HF_TOKEN 变量展开问题

**现象**: setsid nohup bash -c 里 `'\\$HF_TOKEN'` 用单引号 → 变量不展开，变成字面 `$HF_TOKEN`。公开仓库能跑（不需要 token），但 gated repo 会失败。

**改进**: 改用双引号或环境变量传递方式。

### F22/P2: Hermes cron agent 迭代上限 vs pipeline 耗时

**现象**: ai-daily-scan cron 跑了 ~52 API calls 就耗尽 90 上限，pipeline 还在 Verifier 阶段。调到 150 后 harness cron 用了 150 次才跑完一个项目。

**改进**:
1. max_turns 150 已生效，但 harness 一个项目就用满 — 如果要跑多个项目需要更高上限
2. scan prompt 已优化为 background+wait 模式（不再轮询），但 harness prompt 还没被 agent 严格执行 — agent 仍轮询了多次 process poll

### F23/P2: cleanup.json 缺 slug 字段

**现象**: validate-artifacts 报 `cleanup.json missing root field: slug`

**改进**: phase-cleanup.sh 写 cleanup.json 时加 slug 字段。

---

## 三、Cron 基础设施验证结果

| 检查项 | 结果 |
|---|---|
| Gateway 自动启动 | ✅ setsid 启动，SSH 断开不受影响 |
| hooks_auto_accept | ✅ terminal 命令免审批 |
| Cron 定时触发 | ✅ 9:00 和 10:00 正常触发 |
| Scan 全流程 | ✅ 采集→Scanner→Explorer→Analyst→Verifier→Renderer 全跑完 |
| Scan 飞书同步 | ⚠️ agent 迭代用尽没跑飞书同步（手动补上） |
| Harness 全流程 | ✅ VoxCPM2 intake→fetch→install→run→verify→runbook→cleanup→archived |
| Harness record_outcome | ⚠️ agent 用满迭代，可能没回填 |
| deliver=origin 无交互会话 | ⚠️ 投递失败但结果存本地 output 目录 |
