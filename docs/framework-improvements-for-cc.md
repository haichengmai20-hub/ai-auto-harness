# ai-auto-harness 框架完善意见（给 CC 做）

> 日期: 2026-06-15
> 来源: paddleocr 全流程试跑 + khala 深度踩坑 + CC/Hermes 双版对比
> 范围: 只写框架层面（代码/脚本/规则/流程），不写具体项目 bug
> 目标: CC 版下次 cron 跑能自动处理这些 case，不需要人工介入

---

## 一、架构级缺陷（不修就跑不通新项目类型）

### F1. run-and-repair 只认「单次 python 执行」模型，不支持「服务型推理」

**现象**: Khala 不是 `python3 script.py` 就能出结果的——它需要：
1. 启动后端服务（worker + API，后台常驻）
2. 等 health check 通过
3. 发 HTTP 推理请求
4. 下载结果文件
5. 停止后端

当前 phase-run-and-repair.sh 的修复循环只做 `timeout 600 python3 "$ENTRY_FILE"`，对服务型项目完全无效。

**影响范围**: 所有需要启动服务再调 API 的项目（vLLM/Ollama/Gradio/Flask 后端类），在 AI 项目中占比不小。

**建议**:
- intake 阶段增加 `entry_type` 字段：`script`（默认）/ `service`
- `service` 类型的 entry_script 改为描述服务启动+请求+停止的 JSON：
  ```json
  {
    "entry_type": "service",
    "start_cmd": "bash run_backend.sh --gpus 7 --runtime-mode one_shot",
    "health_check": {"url": "http://127.0.0.1:8001/health", "method": "GET", "expect": "idle"},
    "infer_cmd": "curl -s http://127.0.0.1:8001/generate -d '{...}'",
    "stop_cmd": "bash run_backend.sh stop",
    "output_path": "output.wav"
  }
  ```
- phase-run-and-repair.sh 对 service 类型走不同的执行路径：start → poll health → infer → stop

### F2. Privoxy 代理拦截 localhost 通信

**现象**: 本机 Privoxy 会拦截所有 HTTP 请求（包括 `127.0.0.1`/`localhost`），导致：
- run_backend.sh 的 `wait_for_workers`（curl health check）永远拿不到响应
- entry_script 里的 curl 请求全被代理拦截
- 任何 localhost HTTP 通信都失败

**影响范围**: 所有需要 localhost HTTP 通信的项目（服务型推理、Gradio demo、API 调用）。

**建议**:
- phase-run-and-repair.sh 启动推理前，自动设：
  ```bash
  export no_proxy="127.0.0.1,localhost"
  export NO_PROXY="127.0.0.1,localhost"
  ```
- harness-preflight.sh 增加检测项：`curl -s --noproxy '*' http://127.0.0.1:1/ 2>&1` 对比 `curl -s http://127.0.0.1:1/ 2>&1`，如果前者更快说明代理在拦截 localhost
- 写入 AGENTS.md / CLAUDE.md 的环境事实段

### F3. GPU 资源竞争检测不足

**现象**: harness-preflight.sh 只查磁盘和后台下载，不查 GPU 占用。Khala 默认用 GPU 0，但 GPU 0 被 vLLM 占满（32GB/32GB），推理直接 OOM。

**影响范围**: 所有 GPU 推理项目（在 vLLM/训练常驻的机器上几乎必现）。

**建议**:
- preflight 增加 GPU 空闲检测：
  ```bash
  # 输出可用 GPU 列表（已用 < 25GB 的卡）
  nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits \
    | awk -F', ' '$2 < 25000 {print $1}' | tr '\n' ',' | sed 's/,$//'
  ```
- intake 阶段的 GPU 偏好感知（已有雏形）需要和 preflight 联动：preflight 输出可用 GPU 列表，intake 从中选卡
- 如果没有可用 GPU → `paused_for_human`，reason=`gpu_memory_insufficient`，等用户释放资源后 `_RESOLVED` 重试

### F4. 后台进程 PID 注册机制缺失

**现象**: R1/R-guard 要求 kill 的 PID 必须在 `$WORKSPACE/.cache/*.pid` 登记过。但 run_backend.sh 等项目自带脚本后台启动的 worker/API 进程不在 harness 的 PID 登记体系内，导致 cleanup 时杀不掉。

**影响范围**: 所有启动后台服务的项目。

**建议**:
- phase-run-and-repair.sh 启动后台服务后，立即注册 PID：
  ```bash
  # 启动后端后
  pgrep -f "backend_worker.py" > "$WORKSPACE/.cache/worker.pid"
  pgrep -f "backend_api.py" > "$WORKSPACE/.cache/api.pid"
  ```
- phase-cleanup.sh 清理时先读 PID 文件再 kill：
  ```bash
  for pidfile in "$WORKSPACE"/.cache/*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile")
    # 用 /proc/<pid>/stat 判活（不用 kill -0，僵尸误判）
    stat=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $3}')
    [ "$stat" = "Z" ] || [ -z "$stat" ] && continue  # 死了就跳
    kill -9 "$pid" 2>/dev/null
  done
  ```

---

## 二、依赖管理缺陷（不修就降低成功率）

### F5. Megatron/DeepSpeed 类项目的隐式依赖链检测

**现象**: Khala 的依赖链：`six → pybind11 → Transformer Engine → Apex`，一个接一个冒出来。phase-install-env.sh 的 `pip install -r requirements.txt` 对这类项目不够——requirements.txt 只列了 torch/megatron-core，没列 TE/pybind11/six。

**影响范围**: 所有 Megatron/DeepSpeed/TE 类项目（大模型训练框架几乎都有这个问题）。

**建议**:
- install 阶段增加「深度 import 探针」——对含 `from megatron` 的项目，追加：
  ```bash
  python3 -c "from megatron.training import get_args" 2>&1
  python3 -c "import transformer_engine" 2>&1
  ```
  失败则自动 `pip install transformer-engine[pytorch] six pybind11`
- 对常见框架预设「依赖套餐」：
  ```bash
  declare -A FRAMEWORK_DEPS=(
    ["megatron"]="transformer-engine[pytorch] six pybind11 apex"
    ["deepspeed"]="deepspeed ninja packaging"
    ["vllm"]="vllm ninja"
  )
  ```
- 在 requirements.txt 安装完后，扫描 import 语句匹配框架名，自动补装

### F6. `--use-checkpoint-args` 与本地环境不兼容

**现象**: Megatron 项目的 `--use-checkpoint-args` 从 checkpoint 加载所有训练参数（包括 `apply_rope_fusion=True`、`transformer_impl=transformer_engine`、`persist_layer_norm=True`），但推理环境可能没装 TE。

**影响范围**: 所有 Megatron checkpoint 推理项目。

**建议**:
- run-and-repair.sh 增加对 Megatron 类错误的识别：
  ```
  "apply_rope_fusion is not available" → 加 --no-rope-fusion
  "TESpecProvider is not defined" → 加 --transformer-impl local
  "persist_layer_norm not supported by torch LayerNorm" → 加 --no-persist-layer-norm
  ```
- 或者更根本：检测到 `--use-checkpoint-args` 时，先检查 TE 是否可用，不可用则自动追加兼容参数

### F7. 多轮依赖缺失的批量修复

**现象**: 当前 run-and-repair 是逐轮发现、逐轮修复（six → pybind11 → TE → ...），每轮耗时 2-3 分钟。Khala 光装依赖就花了 5 轮。

**影响范围**: 所有依赖链深的项目。

**建议**:
- 依赖缺失错误（`dep_missing`）不逐个装，而是收集一轮所有缺失模块后批量装：
  ```bash
  # 收集所有 ModuleNotFoundError
  MISSING=$(echo "$RUN_OUTPUT" | grep -oE "No module named '([^']+)'" | sed "s/No module named '//;s/'//" | sort -u)
  pip install $MISSING 2>&1
  ```
- 或者：连续 2 轮都是 dep_missing → 触发「深度依赖扫描」（`pip check` + `python3 -c "import <top_level>"` 全量检测）

---

## 三、错误诊断缺陷（不修就浪费大量调试时间）

### F8. one-shot/子进程错误日志丢失

**现象**: Khala worker 的 one-shot 子进程 stdout/stderr 被重定向到临时 `artifact_dir/backbone.log`，但子进程崩溃时这个文件经常没创建或为空。worker 只报 "exited with code 1 without a result file"，错误原因完全看不到。

**影响范围**: 所有使用子进程/one-shot 模式的项目。

**建议**:
- run-and-repair.sh 对子进程失败，增加 stderr 捕获：
  ```bash
  RUN_OUTPUT=$(timeout 600 python3 "$ENTRY_FILE" 2>&1)
  # 如果 RUN_OUTPUT 为空但 exit code != 0，检查 dmesg/系统日志
  if [ $RUN_EXIT -ne 0 ] && [ -z "$RUN_OUTPUT" ]; then
    RUN_OUTPUT="Process exited with code $RUN_EXIT, no output captured. dmesg tail: $(dmesg | tail -5)"
  fi
  ```
- 对 OOM kill（dmesg 里有 `Out of memory: Killed process`），自动识别为 `cuda_oom` 或 `system_oom`

### F9. 错误分类不够细，导致修复策略错误

**现象**: 当前 run-and-repair.sh 的错误分类只有 5 种（dep_missing / file_not_found / paddle_onednn / cuda_oom / unknown）。Khala 遇到的 3 种错误（TE 缺失 / rope_fusion / persist_layer_norm）全被归为 `unknown`，无法自动修复。

**影响范围**: 所有非标准错误的项目。

**建议**:
- 增加错误分类：
  | 错误模式 | 分类 | 修复策略 |
  |---|---|---|
  | `is not available. Please install TE` | `te_missing` | `pip install transformer-engine[pytorch]` |
  | `TESpecProvider.*not defined` | `te_spec_missing` | 加 `--transformer-impl local` |
  | `persist_layer_norm not supported` | `incompatible_checkpoint_arg` | 加 `--no-persist-layer-norm` |
  | `MASTER_ADDR is not set` | `distributed_env_missing` | 设 `MASTER_ADDR=127.0.0.1` |
  | `Address already in use` | `port_conflict` | 换端口或 kill 占用进程 |
  | `No such file.*openclaw\|bashrc.*syntax error` | `shell_config_corrupt` | `BASH_ENV=/dev/null` |
- 对 `unknown` 类错误，增加「错误摘要提取」——从 traceback 最后一行提取关键信息，写入 result JSON 的 `error_detail` 字段，方便人工诊断

### F10. .bashrc 污染导致所有 bash 命令报错

**现象**: `/root/.bashrc` 第 139 行语法错误 + `/root/.openclaw/completions/openclaw.bash` 不存在，导致每次 `source venv/bin/activate` 都先报两行错。虽然不影响功能，但污染了日志和错误检测。

**影响范围**: 所有项目（全局问题）。

**建议**:
- phase-install-env.sh 或 preflight 增加检测：
  ```bash
  bash -n ~/.bashrc 2>&1 || echo "⚠️ ~/.bashrc 语法错误，建议修复"
  ```
- 或者在所有 phase 脚本里设 `BASH_ENV=/dev/null`，跳过 .bashrc 加载

---

## 四、流程/规则缺陷（不修就降低效率或违反规则）

### F11. verify 阶段对服务型项目无验证能力

**现象**: 当前 verify 只做 `entry_script --help` 或 `python3 -c "import <module>"`。对服务型项目，需要验证的是「服务能启动 + 推理能出结果」，不是 import 能过。

**建议**:
- verify 阶段根据 `entry_type` 走不同验证路径：
  - `script` 类型：现有逻辑（import check + smoke test）
  - `service` 类型：启动服务 → health check → 发推理请求 → 检查输出文件 → 停止服务

### F12. cleanup 阶段不清理后台服务进程

**现象**: phase-cleanup.sh 只清理 venv/权重/cache，不清理后台服务进程。Khala 的 worker/API 进程在 cleanup 后仍在运行，占用 GPU 和端口。

**建议**:
- cleanup 阶段增加「进程清理」步骤：
  ```bash
  # 1. 读 PID 文件
  for pidfile in "$WORKSPACE"/.cache/*.pid; do ... done
  # 2. 调项目的 stop 命令（如果有）
  if [ -f "$WORKSPACE/repo/run_backend.sh" ]; then
    cd "$WORKSPACE/repo" && bash run_backend.sh stop
  fi
  # 3. 兜底：kill 所有以 $WORKSPACE 为 cwd 的进程
  ```

### F13. intake 阶段不检测项目类型（script vs service vs api-skeleton）

**现象**: intake 只推断 entry_script（一条命令），不区分项目类型。导致后续所有阶段都按 script 模式跑，对 service/api 项目必然失败。

**建议**:
- intake 阶段增加项目类型推断：
  ```
  检测到 run_backend.sh / server.py / app.py / api.py → entry_type=service
  检测到 estimated_params_b > 30 → entry_type=api_skeleton
  默认 → entry_type=script
  ```
- 写入 intake.json 的 `entry_type` 字段，后续阶段根据此字段走不同路径

### F14. Hermes terminal(background=true) 进程随 cron run 结束可能被回收

**现象**: AGENTS.md 已经写了这个问题（R4b），但 phase 脚本里没有统一处理。Khala 的 run_backend.sh 如果用 `terminal(background=true)` 启动，cron run 结束后进程可能被杀。

**建议**:
- 所有需要跨 cron 存活的后台进程，统一用 `setsid nohup` + sentinel 模板：
  ```bash
  setsid nohup bash run_backend.sh --gpus 7 > "$WORKSPACE/logs/backend.log" 2>&1 &
  echo $! > "$WORKSPACE/.cache/backend.pid"
  # 写 sentinel
  cat > "$WORKSPACE/.cache/handoff/run-backend.json" <<EOF
  {"status":"running","pid":$!,"started_at":"$(date -Iseconds)","log_path":"$WORKSPACE/logs/backend.log"}
  EOF
  ```

---

## 五、之前一直没完善的点（历史遗留）

### F15. CC/Hermes 双引擎互斥机制不完善

**现状**: hermes-migration-gaps.md #1 已写，但只改了 daily.sh 支持 `HERMES_MODE=1`，没有真正的互斥锁。CC 用 flock，Hermes 用 agent-heartbeat，两者不互通。

**建议**:
- 统一用 `state/agent-heartbeat` 作为互斥信号（CC 版也读这个文件）
- 或者更简单：CC 版 crontab 条目注释掉 = 关闭，Hermes cron job pause = 关闭，不需要运行时互斥

### F16. Hermes cron 续跑机制未实现

**现状**: CC 版 daily.sh 有 30min 续跑配额（3次/天）+ 10min bg_recheck + 15min 异常重试。Hermes 版只有单次 cron 触发，没有续跑。

**建议**:
- 利用 Hermes cronjob 的 `context_from` 功能：fetch 阶段写 sentinel → 下次 cron 读 sentinel 判断是否需要续跑
- 或者：Hermes cron 设为每 30min 触发一次，preflight 判断是否需要做事（已有 BUSY 检测）

### F17. outcomes 回填机制未验证

**现状**: SKILL.md 写了 `MCP record_outcome` 回填，但从未在 Hermes 版实际跑过。`state/outcomes-pending.jsonl` 的重试逻辑也没测过。

**建议**:
- 下次跑通一个项目后，手动验证 record_outcome 调用
- 如果 MCP 不可用，fallback 到写本地 jsonl

### F18. validate-artifacts.sh 未写

**现状**: SKILL.md 任务 4 引用了 `scripts/validate-artifacts.sh`，但这个脚本不存在。

**建议**:
- 写一个简单版本：检查 verify.json / runbook.json / cleanup.json 是否存在且 status=done

### F19. reconcile-state.sh / enforce-wallclock.sh 未验证

**现状**: preflight 调了这三个脚本，但从未验证它们在真实场景下的行为。

**建议**:
- 构造测试 fixture（一个 state.json status=running 但 updated_at=2h 前）验证 enforce-wallclock.sh 能正确标记为 stale
- 构造一个僵尸 sentinel 验证 reconcile-sentinels.sh 能正确补写终态

### F20. 多模型策略未实现

**现状**: SKILL.md 提到「fetch-weights / install-env 机械性强，可用 cheap 模型；run-and-repair / verify 判断密集，用强模型」。但从未实现。

**建议**:
- 先全用默认模型跑通，再切。优先级低。

---

## 优先级排序

| 优先级 | 编号 | 一句话 | 预估工作量 |
|---|---|---|---|
| **P0** | F1 | 服务型推理支持（entry_type=service） | 2天 |
| **P0** | F2 | Privoxy 拦截 localhost（no_proxy 设置） | 0.5天 |
| **P0** | F3 | GPU 资源竞争检测 | 0.5天 |
| **P1** | F5 | Megatron/TE 隐式依赖链检测 | 1天 |
| **P1** | F6 | --use-checkpoint-args 兼容性 | 0.5天 |
| **P1** | F9 | 错误分类扩展 | 1天 |
| **P1** | F4 | 后台进程 PID 注册 | 0.5天 |
| **P2** | F7 | 批量依赖修复 | 0.5天 |
| **P2** | F8 | 子进程错误日志捕获 | 0.5天 |
| **P2** | F10 | .bashrc 污染检测 | 0.2天 |
| **P2** | F11 | verify 服务型验证 | 1天（依赖F1） |
| **P2** | F12 | cleanup 清理后台进程 | 0.5天（依赖F4） |
| **P2** | F13 | intake 项目类型推断 | 0.5天（依赖F1） |
| **P3** | F14 | setsid nohup 统一模板 | 0.5天 |
| **P3** | F15-F20 | 历史遗留项 | 各0.5天 |

---

## Khala 项目最终判定

Khala 在当前环境下**无法跑通推理**，根本原因：

1. **Transformer Engine 编译依赖**：`transformer-engine[pytorch]` 需要从源码编译 CUDA kernel，编译耗时 >10 分钟且需要匹配的 CUDA toolkit 版本。PyPI 的 `transformer-engine` 是空 meta package。
2. **GPU 资源不足**：6/8 GPU 被 vLLM 常驻占用，剩余 GPU 7 可用但模型需要 ~15GB（backbone）+ ~10GB（superres），单卡 32GB 勉强够但叠加 TE 有额外开销。
3. **依赖链过深**：Megatron → TE → Apex → pybind11 → six，每一层缺失都导致静默失败。

**建议**: 对 Khala 这类 Megatron 项目标记为 `needs_gpu_cluster`（需要多卡 + TE 预装环境），不在当前单机 cron 流水线中处理。intake 阶段检测到 `from megatron` + 无 TE → `paused_for_human`，reason=`needs_preinstalled_te`。
