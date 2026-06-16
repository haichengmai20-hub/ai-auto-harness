# ai-auto-harness 框架问题全清单 — 给 Claude Code 的完整参考

> 日期: 2026-06-16
> 合并来源: Qwen3-TTS 试跑(Q1-Q6) + Khala 踩坑(F1-F14) + SCAIL 试跑(P1-P12) + CC/Hermes 双版对比 + 历史遗留(F15-F20)
> 目标: CC 下次 cron 跑能自动处理这些 case，不需要人工介入

---

## 〇、环境前置（CC 必读，所有问题的背景）

1. **无直连外网**: 一切外网经代理(`.env` 的 http_proxy)。no_proxy 只放内网。
2. **Privoxy 拦截 localhost**: 所有 HTTP 请求(含 127.0.0.1)被代理拦截。必须 `export no_proxy="127.0.0.1,localhost"`。
3. **GPU 8×RTX5090 32GB**: 状态随时变化。训练/vLLM 常驻占多卡。已用 ≥25GB 的卡严禁碰。
4. **容器 PID 1 = tail -f /dev/null 不收尸**: 僵尸进程 `kill -0` 误判活，判死要查 `/proc/<pid>/stat`。
5. **.bashrc 第 139 行语法错误**: 污染所有 bash 输出（不影响功能但干扰日志/错误检测）。
6. **from_pretrained("org/model") 会重新下载**: 到 `~/.cache/huggingface/`，必须用本地路径 `$WORKSPACE/.cache/hf_models/org/model`。intake.json 的 `weight_target_paths` 有映射。
7. **磁盘 96% 满 (6.3T/7.0T)**: free < 150GB 时不起新 cron run。
8. **磁盘 cron 门槛**: daily.sh + harness-preflight.sh 代码强制 `AI_HARNESS_MIN_FREE_GB`。

---

## 一、Hermes 已修的 bug（CC 版需同步修）

这些 bug Hermes 端已修，但 CC 版的 `.claude/skills/` 对应脚本还没同步。CC 需要把同样的修复合入 CC 版。

### H1. Python heredoc `null` 泄漏 [已修-Hermes]

**所有 phase 脚本的落盘 heredoc** 都有这个 bug。

- **现象**: `NameError: name 'null' is not defined`，verify 全链路崩
- **根因**: `<< PYEOF`（bash 变量内插），bash 变量 `FAILED_AT=null` → Python 看到 `null` 不是 `None`
- **同理**: `"$ENTRY_SCRIPT"` 含换行 → Python 字符串截断 SyntaxError；`$FIXES_APPLIED` 含引号 → `json.loads()` 崩
- **修复**: 统一改 `<< 'PYEOF'`（不插值）+ 环境变量传参（`os.environ["V_FAILED_AT"]`）

**涉及 CC 版文件**（需要同步修）:
- `.claude/skills/verify/SKILL.md` — verify 落盘 heredoc
- `.claude/skills/run-and-repair/SKILL.md` — run 落盘 heredoc
- `.claude/skills/install-env/SKILL.md` — install 落盘 heredoc
- `.claude/skills/intake/SKILL.md` — intake 落盘 heredoc

**修法模式**（4 个文件统一改）:
```bash
# 之前（有 bug）:
python3 << PYEOF
import json
result = {"passed": "$PASSED", "failed_at": "$FAILED_AT"}
PYEOF

# 之后（修好）:
export V_PASSED="$PASSED"
export V_FAILED_AT="$FAILED_AT"
python3 << 'PYEOF'
import json, os
passed = os.environ["V_PASSED"] == "true"
failed_at = os.environ["V_FAILED_AT"]
if failed_at == "null" or failed_at == "":
    failed_at = None
result = {"passed": passed, "failed_at": failed_at}
PYEOF
```

### H2. phases_done 重复写入 [已修-Hermes]

- **现象**: `["intake","fetch-weights","install-env","run-and-repair","verify","verify",...]`
- **根因**: `jq '.phases_done += ["verify"]'` 追加不去重
- **修复**: Python 侧改 `list(dict.fromkeys(...))`（去重保序），替代 `list(set(...))`（丢序）

### H3. apt 系统依赖检测 [已修-Hermes,CC已同步]

- **现象**: `pip install sox` 只装 Python wrapper，系统 `sox` 命令不存在
- **修复**: install-env.sh 新增 6d 步骤，检测 9 组 Python↔apt 映射:
  ```
  sox → sox libsox-dev
  pydub → ffmpeg
  librosa → ffmpeg
  soundfile → libsndfile1
  av → ffmpeg libavcodec-dev libavformat-dev libavdevice-dev
  cv2|opencv → libgl1-mesa-glx libglib2.0-0
  pytesseract → tesseract-ocr
  pdf2image → poppler-utils
  wand → libmagickwand-dev
  ```
- **CC 版需要同步**: install-env SKILL.md 加相同逻辑

---

## 二、Qwen3-TTS 试跑新发现（CC 版待修）

### Q4. from_pretrained 用 HF model id 重复下载 [已修-Hermes,CC已同步]

- **现象**: 权重已下载到 `workspace/.cache/hf_models/`，但 entry_script 写 `"Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"` 导致 from_pretrained 重新下载到 `~/.cache/huggingface/`（18GB 白下）
- **根因**: intake 记录了 `weight_target_paths`（HF repo → 本地路径映射），但 run-and-repair 的 entry_script 不做替换
- **修复**: phase-run-and-repair.sh 在 entry_script 写入后，读 intake.json 的 weight_target_paths，sed 替换所有 HF model id 为本地绝对路径（只替换本地目录存在的）
- **文件**: `hermes/scripts/phase-run-and-repair.sh`
  ```bash
  # 伪代码
  WEIGHT_MAP=$(jq -c '.weight_target_paths[]' "$INTAKE_JSON")
  for mapping in $WEIGHT_MAP; do
    HF_ID=$(echo "$mapping" | jq -r '.hf_repo')
    LOCAL_PATH=$(echo "$mapping" | jq -r '.target_rel')
    FULL_PATH="$WORKSPACE/$LOCAL_PATH"
    sed -i "s|\"$HF_ID\"|\"$FULL_PATH\"|g" "$ENTRY_FILE"
  done
  ```
- **预估**: 0.5 天

### Q5. 推理超时分级 [已修-Hermes,CC已同步]

- **现象**: 0.6B 模型加载+推理就超时（600s），大模型更不可能
- **修复**: phase-run-and-repair.sh 从 intake.json 读 estimated_params_b，按参数量分级:
  ```
  ≤1B → 900s / ≤3B → 1200s / ≤10B → 1800s / ≤30B → 3600s / >30B → 5400s
  ```
  无 intake.json 时回退默认 600s。timeout 命令改用 `$INFER_TIMEOUT` 变量。
- **文件**: `hermes/scripts/phase-run-and-repair.sh`

---

## 三、Khala 踩坑发现（CC 版待修）

### F1. 服务型推理支持（entry_type=service）[待CC] P0

**最大的架构缺口**。当前只认 `python3 script.py`，不支持「启动服务→调API→取结果→停止」。

- **影响**: vLLM/Ollama/Gradio/Flask 后端类项目全挂
- **方案**: intake 增加 `entry_type: script|service`；service 类型的 entry_script 改为 JSON 描述:
  ```json
  {
    "entry_type": "service",
    "start_cmd": "bash run_backend.sh --gpus 7",
    "health_check": {"url": "http://127.0.0.1:8001/health", "method": "GET", "expect": "idle"},
    "infer_cmd": "curl -s http://127.0.0.1:8001/generate -d '{...}'",
    "stop_cmd": "bash run_backend.sh stop",
    "output_path": "output.wav"
  }
  ```
- run-and-repair 对 service 类型走: start → poll health → infer → stop
- **预估**: 2 天

### F2. Privoxy 拦截 localhost [已修,CC已同步] P0

- Hermes 版: guard.env.sh 全局加 `no_proxy="127.0.0.1,localhost"`（所有 phase 脚本 source guard.env.sh 时自动生效）
- CC 版: run-and-repair/SKILL.md 第 0 步 env 加 `export no_proxy/NO_PROXY=127.0.0.1,localhost`（执行点在此 SubAgent;主 agent 只 dispatch 不做 localhost HTTP,故未进 CLAUDE.md，S-1）

### F3. GPU 资源竞争检测 [已部分修] P0

- Hermes intake: 已查 nvidia-smi 选空闲卡
- CC 版: intake 阶段需同样逻辑
- **预估**: CC 版 0.5 天

### F4. 后台进程 PID 注册 [待CC] P1

- R-guard 要求 kill 的 PID 必须在 `$WORKSPACE/.cache/*.pid` 登记过
- 项目自带脚本的后台进程不在体系内，cleanup 杀不掉
- **预估**: 0.5 天

### F5. Megatron/TE 隐式依赖链 [待CC] P1

- `six → pybind11 → Transformer Engine → Apex`，requirements.txt 不含
- 需要深度 import 探针 + 框架预设依赖套餐
- **预估**: 1 天

### F6. --use-checkpoint-args 不兼容 [待CC] P1

- checkpoint 里的 TE 参数和本地环境冲突
- 需要自动追加 `--no-rope-fusion` / `--transformer-impl local` / `--no-persist-layer-norm`
- **预估**: 0.5 天

### F7. 批量依赖修复 [已修-CC] P2

- 当前逐个装，Khala 光装依赖就花了 5 轮
- 收集所有 ModuleNotFoundError 后批量 `pip install`
- **预估**: 0.5 天

### F8. 子进程错误日志丢失 [已修-CC] P2

- one-shot 子进程崩溃时 stderr 为空
- 需要 dmesg 捕获 OOM kill 等
- **预估**: 0.5 天

### F9. 错误分类扩展 [已修-Hermes,已修正毁文件 bug,CC已同步安全集] P1

- 当前只有 5 种: dep_missing / file_not_found / paddle_onednn / cuda_oom / unknown
- Khala 遇到 3 种新错误全归 unknown
- **修复**: phase-run-and-repair.sh 新增 7 种错误分类及自动修复:
- **⚠️ 2026-06-16 审查修正**: 初版 3 个分类用 `sed -i` 往 Python 入口文件塞 Megatron CLI flag = 毁文件(`incompatible_checkpoint_arg` 把 `args`/`argparse`/`sys.argv` 全替成注释;`te_spec_missing` 插 flag 成 SyntaxError;`port_conflict` 全局替数字误伤 batch/维度)。已改:Megatron CLI 类(te_spec/incompatible_ckpt)下调为**分类+诊断+转人工不动源码**;distributed/port 改**走 shell env var**(MASTER_ADDR/PORT);te_missing 加 once-guard(TE 是 meta 包需源码编译)。详见 [fixes/2026-06-16-f9-error-class-destructive-autofix-fix.md](superpowers/fixes/2026-06-16-f9-error-class-destructive-autofix-fix.md)。**CC 版同步只移植安全集,毁灭性 sed 绝不进 CC**。

| 错误模式 | 分类 | 修复策略 |
|---|---|---|
| `is not available. Please install TE` | `te_missing` | `pip install transformer-engine[pytorch]` |
| `TESpecProvider.*not defined` | `te_spec_missing` | 加 `--transformer-impl local` |
| `persist_layer_norm not supported` | `incompatible_checkpoint_arg` | 加 `--no-persist-layer-norm` |
| `MASTER_ADDR is not set` | `distributed_env_missing` | 设 `MASTER_ADDR=127.0.0.1` |
| `Address already in use` | `port_conflict` | 换端口或 kill 占用进程 |
| `No such file.*openclaw\|bashrc.*syntax error` | `shell_config_corrupt` | `BASH_ENV=/dev/null` |
| `sox.*not found\|SoX could not be found` | `system_dep_missing` | `apt-get install sox` |
| `ffmpeg.*not found` | `system_dep_missing` | `apt-get install ffmpeg` |

- **预估**: 1 天

### F10. .bashrc 污染检测 [已间接修,CC加检测] P2

- heredoc 改 `<<'PYEOF'` 后不受 .bashrc 影响
- 但根因仍在，建议 preflight 加 `bash -n ~/.bashrc` 检测
- **预估**: 0.2 天

### F11. verify 服务型验证 [待CC] P2（依赖 F1）

### F12. cleanup 清理后台进程 [待CC] P2（依赖 F4）

### F13. intake 项目类型推断 [待CC] P2（依赖 F1）

- 检测 `run_backend.sh / server.py / app.py / api.py` → entry_type=service
- 检测 `estimated_params_b > 30` → entry_type=api_skeleton
- **预估**: 0.5 天

### F14. setsid nohup 统一模板 [待CC] P3

- 跨 cron 后台进程需统一用 setsid nohup + PID 文件 + sentinel
- **预估**: 0.5 天

---

## 四、SCAIL 试跑发现（CC 版待修）

### P1. Cron 只跑一次就退出，不自动续跑 [待CC] P0

- daily.sh 跑完就退出，fetch-weights 跨 cron 要等 24h
- 方案: 退出后检查 in_progress 项目，30min 后重新启动（最多 3 次/天）
- **预估**: 1 天

### P3. State.json 与实际文件不一致 [已修-Hermes] P1

- 接续时 state 说是 fetching 但文件已下载完
- **修复**: reconcile-state.sh 新增规则 4 — verify.json passed=true 但 state 还停在 verifying/running 时自动修正
- **文件**: `scripts/reconcile-state.sh`

### P4. GPU Preflight 不查实际空闲显存 [已部分修] P0

- Hermes intake 已修；CC 版需同步
- **预估**: CC 版 0.5 天

### P6. Cron 失败后无自动重试 [待CC] P2

- 方案: 15min 后重试一次
- **预估**: 0.3 天

### P8. 接续时 agent 看到 failed outcome 就跳过 [待CC] P1

- 应该区分 "刚失败" vs "已失败需要人工"
- **预估**: 0.3 天

### P9. install-env 不装未列出的依赖 [已修-Hermes]

- Hermes 版已加 6b/6c/6d 三层检测（隐式依赖/深度import/apt系统依赖）
- CC 版需同步

### P10. run-and-repair 切 git branch [已修]

- R11 规则 + hook 拦截

### P11. 3 轮修复上限太死 [已修]

- R3 修复轮次分类：依赖缺失不计入 3 轮上限

### P12. R4 poll limit 截断长任务 [已修]

- R4.6 poll 动态间隔

---

## 五、历史遗留（F15-F20）[待CC] P3

| 编号 | 问题 | 说明 |
|---|---|---|
| F15 | CC/Hermes 双引擎互斥 | 运行时互斥锁不完善，CC 用 flock Hermes 用 heartbeat |
| F16 | Hermes cron 续跑机制 | 只有单次 cron 触发，无续跑（CC 版已修: P1） |
| F17 | outcomes 回填 | 已验证通过 ✅ (Qwen3-TTS 实测) |
| F18 | validate-artifacts.sh 未写 | SKILL.md 引用了但脚本不存在 |
| F19 | reconcile-state.sh / enforce-wallclock.sh 未验证 | 从未在真实场景测试 |
| F20 | 多模型策略 | cheap 模型跑机械阶段，强模型跑判断阶段。低优 |

---

## 六、优先级排序（给 CC 的实施建议）

| 优先级 | 编号 | 一句话 | 预估 |
|---|---|---|---|
| **P0** | H1-H3 | ✅ 同步 Hermes 已修的 bug（heredoc/phases_done/apt） | ✅已修 |
| **P0** | Q4 | ✅ from_pretrained HF id → 本地路径替换 | ✅已修 |
| **P0** | Q5 | ✅ 推理超时分级 | ✅已修 |
| **P0** | F1 | 服务型推理支持 | 2天 |
| **P0** | F2 | ✅ no_proxy（Hermes + CC SKILL 均已同步） | ✅已修 |
| **P0** | F9 | ✅ 错误分类扩展（Hermes 修正毁文件 bug #41；CC 同步安全集） | ✅已修 |
| **P0** | P1 | Cron 续跑机制 | 1天 |
| **P1** | F5 | Megatron/TE 隐式依赖链 | 1天 |
| **P1** | F4 | 后台进程 PID 注册 | 0.5天 |
| **P1** | F6 | --use-checkpoint-args 兼容 | 0.5天 |
| **P1** | P3 | ✅ state 不一致（`scripts/reconcile-state.sh` 双框架共用,CC 自动生效） | ✅已修 |
| **P1** | P8 | ✅ 接续跳过（CC版已有*_RESOLVED规则） | ✅ |
| **P2** | F3 | GPU preflight（CC 版同步） | CC版0.5天 |
| **P2** | F7/F8 | ✅ 批量依赖 + 子进程日志(CC 已同步) | ✅已修 |
| **P2** | H3/F10 | ✅ apt 系统依赖 + .bashrc 检测(CC 已同步) | ✅已修 |
| **P2** | F11-F13 | verify/cleanup/intake 服务型 | 2天 |
| **P3** | F14-F20 | 历史遗留 | 3天 |

**总预估: ~15 天**，P0 约 5 天，P1 约 4 天，P2 约 3 天，P3 约 3 天。

---

## 七、关键文件路径

### CC 版需要改的文件
```
.claude/CLAUDE.md                          — 运行时上下文(加 no_proxy 等)
.claude/skills/auto-daily/SKILL.md         — 主调度 skill
.claude/skills/intake/SKILL.md             — intake 阶段
.claude/skills/fetch-weights/SKILL.md      — fetch 阶段
.claude/skills/install-env/SKILL.md        — install 阶段(加 apt 检测)
.claude/skills/run-and-repair/SKILL.md     — run 阶段(加超时分级+HF路径替换+错误分类)
.claude/skills/verify/SKILL.md             — verify 阶段(修 heredoc)
.claude/skills/write-deploy-runbook/SKILL.md — runbook
.claude/skills/cleanup-deployed-workspace/SKILL.md — cleanup
cron/daily.sh                              — 加续跑机制
```

### 参考文档（CC 可读但不需改）
```
docs/framework-issues-full-list.md         — 本文档
docs/framework-improvements-for-cc.md      — 详细方案(每个缺陷含代码示例)
docs/framework-improvements-prompt.md      — 整体 prompt(含框架前置背景)
docs/hermes-migration-gaps.md              — CC→Hermes 迁移差距
docs/superpowers/specs/2026-06-11-试跑复盘与验证清单.md  — SCAIL 试跑 P1-P12
docs/superpowers/specs/2026-06-10-r-rules-reference.md  — R 规则完整参考
```

### Hermes 已修的文件（CC 可参考修法）
```
hermes/scripts/phase-verify.sh             — heredoc 修法参考
hermes/scripts/phase-run-and-repair.sh     — heredoc + entry_command 修法
hermes/scripts/phase-install-env.sh        — heredoc + apt 检测 + phases_done
hermes/scripts/phase-intake.sh             — heredoc 修法
```

---

## 八、试跑数据总结

| 项目 | 结果 | 关键问题 | Hermes 介入 |
|---|---|---|---|
| PaddleOCR | ✅ 通过 | OneDNN bug, pip 依赖 | 0 次(自动修) |
| song-generation | ✅ 通过 | 无 | 0 次 |
| hojo-asr | ✅ 通过 | 无 | 0 次 |
| qwen3-tts | ✅ 通过 | sox 系统依赖, HF 路径, 超时 | 2 次 |
| SCAIL (14B) | ❌ OOM | GPU 不足, 分支切换, resharding | 3 次(失败) |
| Khala (Megatron) | ❌ TE 缺失 | 隐式依赖链, checkpoint 兼容, 服务型 | 5 次(失败) |
| gemma-pytorch | ⏸️ 未跑 | — | — |

**成功率**: 4/6 = 67%（排除未跑的）。如果修了 Q4/Q5/F9，预计提升到 80%+。
