# ai-auto-harness 框架问题全清单 + 修复状态（给 CC）

> 日期: 2026-06-16
> 来源: Qwen3-TTS 全流程试跑 + Khala 深度踩坑 + PaddleOCR 试跑 + CC/Hermes 双版对比
> 状态标记: [已修] = Hermes 手动修了; [待CC] = 需要 CC 实现; [低优] = 不紧急

---

## 环境前置（CC 必读）

1. 本机**无直连外网**，一切外网经代理（`.env` 的 http_proxy）。no_proxy 只放内网。
2. Privoxy 会拦截 localhost HTTP（必须 `export no_proxy="127.0.0.1,localhost"`）。
3. GPU 8×RTX5090 32GB，状态随时变化。训练/vLLM 常驻占用多卡。
4. 容器 PID 1 是 `tail -f /dev/null` 不收尸：僵尸进程 `kill -0` 误判活。
5. `.bashrc` 第 139 行语法错误，污染所有 bash 输出（不影响功能但干扰日志）。
6. `from_pretrained("org/model")` 会重新下载到 `~/.cache/huggingface/`，必须用本地路径 `$WORKSPACE/.cache/hf_models/org/model`。

---

## 一、本次 Qwen3-TTS 试跑新发现（6 个）

### Q1. verify 脚本 Python heredoc `null` 泄漏 [已修]

**现象**: `NameError: name 'null' is not defined`，verify smoke test 全崩
**根因**: `phase-verify.sh` 第 238 行，bash 变量 `FAILED_AT=null` 直接内插到 Python heredoc，Python 不认识 `null`（应为 `None`）
**修复**: 改用 `'PYEOF'`（不插值）+ 环境变量传参（`os.environ["V_FAILED_AT"]`），Python 侧 `== "null"` → `None`
**文件**: `hermes/scripts/phase-verify.sh`

### Q2. cleanup G4 规则误判 verify 结果 [已修-根因]

**现象**: cleanup.json `skipped_reason: "G4_verify_failed"`，但推理实际成功
**根因**: verify 脚本 Bug Q1 导致 verify.json 没写出来，cleanup 读不到 `.passed` 默认 false
**修复**: Q1 修好后 verify.json 正常写出，cleanup 自然正确
**文件**: 无需额外修

### Q3. run-and-repair entry_command 换行导致 SyntaxError [已修]

**现象**: `SyntaxError: unterminated string literal`，run_and_repair.json 写失败
**根因**: `"$ENTRY_SCRIPT"` 含换行符，内插到 Python 字符串截断
**修复**: 同 Q1 方案——环境变量 + `'PYEOF'`
**文件**: `hermes/scripts/phase-run-and-repair.sh`

### Q4. from_pretrained 用 HF model id 重复下载 [待CC]

**现象**: 权重已下载到 `workspace/.cache/hf_models/`，但 entry_script 里写 `"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"` 导致 from_pretrained 重新下载到 `~/.cache/huggingface/`
**根因**: intake 记录了 `weight_target_paths`（本地路径映射），但 run-and-repair 的 entry_script 不做替换
**建议**: run-and-repair.sh 在写 entry_script.py 前，扫描 intake.json 的 weight_target_paths，替换所有 HF model id 为本地绝对路径
**预估**: 0.5 天

### Q5. phases_done 重复写入 [已修]

**现象**: `["intake","fetch-weights","install-env","run-and-repair","verify","verify","write-deploy-runbook","write-deploy-runbook","cleanup"]`
**根因**: `+= ["verify"]` 追加不去重；run-and-repair.sh 旧版用 `list(set(...))`（丢失顺序）
**修复**: 统一改 `list(dict.fromkeys(...))`（去重保序）
**文件**: 所有 phase 脚本的落盘部分

### Q6. run-and-repair 超时 600s 不够 [待CC]

**现象**: 模型加载 + tokenizer 初始化 + generate 总耗时 >600s，0.6B 模型就超时
**建议**: 按模型参数量分级超时：≤1B 900s / ≤3B 1200s / ≤10B 1800s / ≤30B 3600s
**预估**: 0.3 天

---

## 二、之前已记录的问题（F1-F20，来源 framework-improvements-for-cc.md）

### F1. 服务型推理支持（entry_type=service）[待CC] P0

当前只认 `python3 script.py`，不支持「启动服务→调API→取结果→停止」。vLLM/Gradio/Flask 后端类全挂。
预估: 2 天

### F2. Privoxy 拦截 localhost [已部分修复] P0

- Hermes 版: 所有 phase 脚本已加 `export no_proxy="127.0.0.1,localhost"`
- CC 版: 需要在 CLAUDE.md / phase 脚本里统一加
预估: CC 版 0.5 天

### F3. GPU 资源竞争检测 [已部分修复] P0

- Hermes intake: 已查 `nvidia-smi` 选空闲卡（已用<25GB）
- CC 版: intake 阶段需要同样逻辑
预估: CC 版 0.5 天

### F4. 后台进程 PID 注册 [待CC] P1

R-guard 要求 kill 的 PID 必须在 `$WORKSPACE/.cache/*.pid` 登记过，但项目自带脚本的后台进程不在体系内。
预估: 0.5 天

### F5. Megatron/TE 隐式依赖链 [待CC] P1

`six → pybind11 → Transformer Engine → Apex`，requirements.txt 不含。需要深度 import 探针。
预估: 1 天

### F6. --use-checkpoint-args 不兼容 [待CC] P1

checkpoint 里的 TE 参数和本地环境冲突。需要自动追加兼容参数。
预估: 0.5 天

### F7. 批量依赖修复 [待CC] P2

当前逐个装，Khala 光装依赖就花了 5 轮。应收集所有 ModuleNotFoundError 后批量装。
预估: 0.5 天

### F8. 子进程错误日志丢失 [待CC] P2

one-shot 子进程崩溃时 stderr 为空，worker 只报 "exited with code 1"。需要 dmesg 捕获。
预估: 0.5 天

### F9. 错误分类扩展 [待CC] P1

当前只有 5 种分类（dep_missing/file_not_found/paddle_onednn/cuda_oom/unknown）。Khala 遇到 3 种新错误全归 unknown。建议增加: te_missing / te_spec_missing / incompatible_checkpoint_arg / distributed_env_missing / port_conflict / shell_config_corrupt
预估: 1 天

### F10. .bashrc 污染检测 [已修-间接] P2

- install-env.sh 的 heredoc 已改为 `'PYEOF'` + 环境变量，不受 .bashrc 污染影响
- 但根因 `.bashrc` 语法错误仍在，建议 preflight 增加检测
预估: 0.2 天

### F11. verify 服务型验证 [待CC] P2（依赖 F1）

verify 只做 import check + smoke test，对服务型项目需要 health check + 推理请求。
预估: 1 天

### F12. cleanup 清理后台进程 [待CC] P2（依赖 F4）

cleanup 不清理后台服务进程，GPU 和端口被占。
预估: 0.5 天

### F13. intake 项目类型推断 [待CC] P2（依赖 F1）

intake 不区分 script/service/api-skeleton。
预估: 0.5 天

### F14. setsid nohup 统一模板 [待CC] P3

跨 cron 后台进程需统一用 setsid nohup + PID 文件 + sentinel。
预估: 0.5 天

### F15-F20. 历史遗留 [待CC] P3

- F15: CC/Hermes 双引擎互斥
- F16: Hermes cron 续跑机制
- F17: outcomes 回填验证（本次 Qwen3-TTS 已验证通过 ✅）
- F18: validate-artifacts.sh 未写
- F19: reconcile-state.sh / enforce-wallclock.sh 未验证
- F20: 多模型策略
预估: 各 0.5 天

---

## 三、本次已修的文件清单

| 文件 | 修改内容 |
|---|---|
| `hermes/scripts/phase-verify.sh` | Python heredoc 改 `<<'PYEOF'` + 环境变量传参，修 null 泄漏 |
| `hermes/scripts/phase-run-and-repair.sh` | Python heredoc 改 `<<'PYEOF'` + 环境变量，修 entry_command SyntaxError + phases_done 去重 |
| `hermes/scripts/phase-install-env.sh` | Python heredoc 改 `<<'PYEOF'` + 环境变量 + 新增 6d apt 系统依赖检测 + phases_done 去重 |
| `hermes/scripts/phase-intake.sh` | Python heredoc 改 `<<'PYEOF'` + 环境变量，修 entry_script 换行截断 |

**共同模式**: 所有 `<< PYEOF`（bash 变量内插）→ `<< 'PYEOF'`（纯 Python）+ 环境变量传参。这是系统性修复，杜绝了 null/引号/换行三类 bash-Python 边界 bug。

---

## 四、优先级排序（给 CC 的建议）

| 优先级 | 编号 | 一句话 | 预估 |
|---|---|---|---|
| **P0** | F1 | 服务型推理支持 | 2天 |
| **P0** | Q4 | from_pretrained HF id → 本地路径替换 | 0.5天 |
| **P0** | Q6 | 推理超时分级 | 0.3天 |
| **P1** | F9 | 错误分类扩展 | 1天 |
| **P1** | F5 | Megatron/TE 隐式依赖链 | 1天 |
| **P1** | F4 | 后台进程 PID 注册 | 0.5天 |
| **P1** | F6 | --use-checkpoint-args 兼容 | 0.5天 |
| **P2** | F7 | 批量依赖修复 | 0.5天 |
| **P2** | F8 | 子进程错误日志 | 0.5天 |
| **P2** | F11 | verify 服务型验证 | 1天 |
| **P2** | F12 | cleanup 清理后台 | 0.5天 |
| **P2** | F13 | intake 项目类型推断 | 0.5天 |
| **P3** | F14-F20 | 历史遗留 | 各0.5天 |

---

## 五、Qwen3-TTS 试跑数据

| 指标 | 值 |
|---|---|
| 项目 | Qwen3-TTS (0.6B-CustomVoice) |
| 总耗时 | ~2h (10:12→12:08) |
| 下载量 | 18.4GB (6 repos) |
| GPU | GPU 4, 2237 MiB |
| 推理输出 | sr=24000Hz, 1.36s wav |
| Hermes 介入次数 | 2 (sox 安装 + 本地路径替换) |
| 阶段成功率 | 5/7 自动, 2 需人工介入 |
