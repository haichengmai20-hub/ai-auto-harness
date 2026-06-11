---
name: run-and-repair
description: 试跑 entry_script + LLM 自主修复循环(CC agent loop 替代 Python rule-based repair_loop)
allowed-tools: [Read, Write, Edit, Bash, BashOutput, Grep, KillBash]
agent: runner-agent
---

# run-and-repair

## 核心机制

**你就是 repair loop**.CC agent loop 的每一轮 ToolUse 就是一轮"观察→决策→执行→验收".

替代 `auto-deploy-agent/modules/runner/repair_loop.py` 那套手写 5 轮 while + Rule-based decider.

## 落盘约定(必读)

- **运行日志**:`$WORKSPACE/logs/run_and_repair.log` — 每轮试跑的 stdout/stderr append(多轮累积)
- **修复轨迹**:`$WORKSPACE/logs/fixes.log` — 每次修复 append 一行(简短文字,JSON Line 也行)
- **结果**:`$WORKSPACE/results/run.json` — RunResult

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
LOG="$WORKSPACE/logs/run_and_repair.log"
FIXES="$WORKSPACE/logs/fixes.log"
echo "==== run-and-repair start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=run-and-repair slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

每次修复都同时:
1. 把修复尝试 append 一行到 `fixes.log`(给后续审计用,人能看)
2. 把详细决策 append 到 `$RUN_DIR/decisions.md`(本次 cron 内的决策上下文;`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`,slug 已知时即 `workspace/<slug>/runs/<id>/`)

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "venv_path": "<workspace>/venv",
  "entry_script": "python -m flux t2i --output out.png",
  "gpu_picks": [3, 4],
  "run_id": "<from 主 agent>"
}
```

## 第 0 步:设置环境(每次跑 bash 前都做)

```bash
source "$VENV_PATH/bin/activate"
export CUDA_VISIBLE_DEVICES="$(echo ${GPU_PICKS[@]} | tr ' ' ',')"
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export TRANSFORMERS_CACHE="$WORKSPACE/.cache/transformers"
```

## 第 0.5 步:GPU pre-flight(在跑任何 GPU workload 前必做)

即使 install-env 已经检测过 torch sm_12,本阶段开跑前也要 verify 一次 — 因为可能后续 SubAgent 改过环境 / 卸装过包.

```bash
echo "---- GPU pre-flight ----" >> "$LOG"
python -c "
import torch
print('cuda_available:', torch.cuda.is_available())
print('device_count:', torch.cuda.device_count())
print('capability:', torch.cuda.get_device_capability())
print('archs:', torch.cuda.get_arch_list())
" 2>&1 | tee -a "$LOG"
PFL_EXIT=$?
```

**判定**:
- `cuda_available=False` → 装错了,**不要继续**(GPU 利用率会是 0,verify 会 fail).
  → 调 request-human-intervention skill,reason_category=`stuck_repair_3x`,what_blocked="torch CUDA 不可用,install-env 阶段装错了"
- `capability` 不含 (12, 0) 且当前是 5090 集群 → sm_12 wheel 没装好.
  → 调 request-human-intervention,reason="torch sm_12 not supported"
- 都 OK → 进第 1 步试跑.

**不要**装作没看见就继续试跑 — 那会浪费几分钟跑出 NaN / OOM / CPU fallback 才发现.

## 第 1 步:试跑 entry_script(每轮先做)

**短任务**(脚本几秒到几分钟内出结果):

```bash
cd "$WORKSPACE/repo"
echo "---- round $ROUND attempt at $(date -Iseconds) ----" >> "$LOG"
$ENTRY_SCRIPT >> "$LOG" 2>&1
EXIT=$?
echo "exit_code=$EXIT" | tee -a "$LOG"
```

**长任务**(模型推理可能 10 分钟+):

```bash
# background bash
nohup setsid bash -c '
  source venv/bin/activate
  cd workspace/<slug>/repo
  '"$ENTRY_SCRIPT"'
' > "$WORKSPACE/run.log" 2>&1 &
PID=$!
echo $PID > "$WORKSPACE/.cache/run.pid"
# 然后用 BashOutput / tail poll
```

## 第 2 步:观察(每轮必做,在决策前)

```bash
echo "--- run.log tail ---"
tail -50 "$WORKSPACE/run.log"

echo "--- nvidia-smi ---"
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader

echo "--- workspace 输出文件 ---"
ls -la "$WORKSPACE/repo/" | head -20
ls -la "$WORKSPACE/repo/outputs/" 2>/dev/null || true

echo "--- run.pid alive? ---"
PID=$(cat "$WORKSPACE/.cache/run.pid" 2>/dev/null)
[ -n "$PID" ] && kill -0 $PID 2>/dev/null && echo "alive" || echo "dead"
```

## 第 3 步:决策(LLM 判断)— 是否成功 / 真出错 / 还在跑 / 卡了

### 成功判定
- exit_code == 0
- 预期输出文件存在(图片 / 视频 / 文本 etc.)且大小合理
- → return RunResult `passed=true`

### 真出错判定

看 stderr root cause,匹配常见模式(优先读 memory/lessons/*.md 找类似):

| 错误模式 | 可能根因 | 修复方向 |
|---|---|---|
| `CUDA out of memory` | 显存不够 | 减 batch / 量化 / 换更空的 GPU |
| `No module named X` | 缺包 | `pip install X` |
| `RuntimeError: NaN / inf` + 5090 | sm_12 wheel 不支持(读 torch-sm12.md) | 重装 nightly cu124(应该 install-env 已修,这里 double check) |
| `401 Unauthorized` | gated repo 没 token(读 hf-gated.md) | raise pending_human |
| `ImportError: flash_attn` | flash-attn 没装 | 改代码 try/except fallback(读 flash-attn-build.md) |
| `exit_code = -15` (SIGTERM) | 超时被外部杀 | 看是不是脚本在等什么(下载、等输入) |
| `exit_code = -9` (SIGKILL) | 内存不足 / cgroup OOM | 减大batch / 量化 |
| `exit_code = 137` | OOMKill | 同上 |
| `Connection refused / timed out` | 网络问题 | retry / 看是不是要本地服务 |

### 还在跑判定(长任务)

- run.pid 仍 alive
- GPU 利用率 > 10%
- stderr / stdout 有新输出(对比上次 poll)
- 已生成中间文件(checkpoint / intermediate output)

→ 不修不动,继续 poll(BashOutput / tail)

**poll 动态间隔(2026-06-11, R4.6/P12)**:进程健康(上面 4 项都正常)时,poll 间隔可递增 30s→45s→60s 省 turn;要更长等待用 `sleep 55 && tail -5 "$LOG"` 把等待+采样合并为**一次** poll(单次 sleep ≤60s 硬上限不变);出现异常迹象立即恢复密集检查。已知长耗时步骤(checkpoint resharding/编译,5-10min)预计超 8 次 poll 预算 → 直接 `paused_in_progress` return,daily.sh 的 30 分钟续跑机制会接续

### 卡死判定

- run.pid alive 但 30min:
  - GPU 利用率 0%
  - stderr / stdout 无新输出
  - 文件无新增
- → kill -9 $PID,重启 OR 试改环境(如不同 GPU)

## 第 4 步:修复(若决策是"真出错")

- **修代码**:`Edit workspace/<slug>/repo/<file>` — 先 Read 原内容,小幅修改,**不要重写整个文件**
- **修环境**:`export NEW_VAR=...`,同时写到 state.env_overrides:
  ```bash
  jq --arg k "CUDA_VISIBLE_DEVICES" --arg v "$NEW_VALUE" \
     '.env_overrides[$k] = $v' "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
  ```
- **修配置**:`Edit workspace/<slug>/repo/configs/<yaml>`(同样先 Read)
- **修依赖**:`pip install/uninstall` — 写到 fixes_applied

### 每个修复都强制做这两件事

1. 简短一行 append 到 `$WORKSPACE/logs/fixes.log`(给后续审计 / 多个 cron 跨 run 看):
```bash
echo "$(date -Iseconds) round=$ROUND error=CUDA_OOM fix=batch_size_4_to_1 file=configs/inference.yaml" >> "$WORKSPACE/logs/fixes.log"
```

2. 详细决策 append 到 `$RUN_DIR/decisions.md`(本次 cron 内的上下文;`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`):
```markdown
- 2026-05-19T11:20 by runner-agent (round 1/3): 检测到 CUDA OOM(stderr 含 "CUDA out of memory"),把 configs/inference.yaml 的 batch_size 从 4 改成 1。期望重跑通过。
```

## 第 5 步:验收

修完 → 回到第 1 步重跑.

**3 轮上限(2026-06-11 轮次分类,P11)**:

- **依赖缺失类**(`ModuleNotFoundError` / import 阶段的 `AssertionError` / `ImportError`)→ **不计入** 3 轮上限,可额外重试 2 次 — 一条 `pip install` 能解决的问题不该烧掉宝贵的修复轮(SCAIL 实测:flash_attn 缺失耗掉最后一轮)
- **框架 bug 类**(tensor mismatch / CUDA OOM / segfault / RuntimeError)→ 正常计入 3 轮
- 每轮在 decisions.md 标注分类:`(round 2/3, 类型=框架bug)` 或 `(依赖补装 1/2, 不计轮)`

**🔴 分支纪律(2026-06-11, R11/P10)**:**严禁** `git checkout` / `git switch` 切到其他分支 — 会丢掉前几轮已打的修复补丁,且新分支代码结构可能完全不同(SCAIL 实测:切 wan 分支后 attempt 1-2 的 device fix 全作废 + git stash 冲突)。修复只在当前分支上做;当前分支确实跑不通 → `paused_for_human`,把"建议试 X 分支"写进 next_steps_suggested 让人决策。(`git checkout -- <file>` 恢复单文件不在禁令内)

```python
if round_count == 3 and not passed:
    Call request-human-intervention skill:
        reason_category = "stuck_repair_3x"
        what_tried = [
            "round 1: 改 batch_size 4→1 → 仍 CUDA OOM",
            "round 2: 加 --fp16 量化 → import error",
            "round 3: 改用 GPU 5 (空闲多)→ 同样 OOM"
        ]
        what_blocked = "项目对 5090 32GB 显存不友好,本地无法 self-host"
        next_steps_suggested = [
            "评估走 api-skeleton 路线",
            "或等更大显存 GPU 集群"
        ]
    return {"passed": false, "blocked": true, "paused_for_human": true}

# 不要硬试第 4 轮
```

## 第 6 步:积累经验(lesson 写入机制)

修复成功后,判断是否写经验文件 — **判断标准 3 问**:

| 问题 | yes → 写哪里 |
|---|---|
| 修复是这个项目特有的(改了具体 config / 项目 own 代码)? | `memory/projects/<slug>.md` 追加 |
| 修复方法**任何用类似 stack 的项目**都可能用上? | `memory/lessons/<topic>.md` 追加段落 |
| 都不是(只是 1 行参数微调)? | **不写**(过度积累 = 噪声) |

### 通用 lesson 的典型例子(写)

- 5090 sm_12 不支持 torch wheel 怎么修 → `memory/lessons/torch-sm12.md`
- flash-attn prebuilt wheel 选择逻辑 → `memory/lessons/flash-attn-build.md`
- HF gated repo 401 区分 token vs license → `memory/lessons/hf-gated.md`
- diffusers / transformers 之间版本协调 → `memory/lessons/<新>.md`

### 项目专属的典型例子(写 projects/)

- "SongGeneration 的 entry_script 在 `sample.py` 不在 `main.py`" → `memory/projects/song-generation.md`
- "Flux 的 inference 要先跑 `download_weights.sh`" → `memory/projects/flux.md`

### 不要写的例子(噪声)

- "batch_size 从 4 改成 1 OOM 解决了" — 这是常识不是 lesson
- "重启 venv 就好了" — 没有可复用价值
- "改了某个 config 的 yaml 路径" — 项目特有 + 太琐碎

### 写 lesson 的格式

**append 段落**(不覆盖)— 格式参考 `memory/lessons/torch-sm12.md` 已有的:

```markdown
## <现象 / 触发条件>

<内容...>

### 修复(按优先级)

1. ...
2. ...
```

如果 `<topic>.md` 已存在,**append**(在文件末尾加新段落);如果不存在,**新建** topic 文件.

## 返回前落盘 results JSON

```bash
cat > "$WORKSPACE/results/run.json" <<JSON
{
  "passed": <true|false>,
  "error_class": <"CUDA_OOM" | "MODULE_MISSING" | ... | null>,
  "repair_count": <int>,
  "stdout_tail": "<last 50 lines from $LOG>",
  "gpu_snapshot": {...},
  "fixes_applied": [...],
  "post_conditions_met": {...},
  "blocked": <bool>,
  "paused_for_human": <bool>,
  "completed_at": "$(date -Iseconds)"
}
JSON
echo "==== run-and-repair end at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_END   phase=run-and-repair slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

## 返回 schema

```json
{
  "passed": true,
  "error_class": null,
  "repair_count": 1,
  "stdout_tail": "<last 50 lines>",
  "gpu_snapshot": {
    "memory_used_mb": 18432,
    "utilization_pct": 87,
    "processes": 1,
    "gpu_index": 3
  },
  "fixes_applied": ["batch_size_1"],
  "post_conditions_met": {
    "output_file_exists": true,
    "file_size_reasonable": true,
    "format_valid": true
  },
  "blocked": false,
  "paused_for_human": false
}
```

**`repair_count` / `fixes_applied` 的统计口径(必须遵守)**:任何为了让 entry_script 跑通而做的**适配动作都算修复**,不只是"重试 python 命令"。包括:改 import / 换 library 版本 / 改 config / patch 源代码 / 改 batch_size / 写 wrapper 脚本 / 改 entry 参数。每个动作在 `fixes_applied` 里一条,`repair_count` = 修复**轮数**(一轮可含多个动作)。omnivoice 实测翻车:transcript 里 52 处代码适配,run.json 却写 `repair_count: 0` — 下游报告/复盘全失真。

## 反模式

- ❌ 跑模型用 `Bash(timeout=600)` 同步阻塞(长任务必须 background)
- ❌ Edit 不先 Read(可能改坏)
- ❌ Edit 不写 decisions.md(后续审计困难)
- ❌ 修第 4 5 6 轮还在试(应该早 raise)
- ❌ 重写整个文件而不是小改(易引入新 bug)
- ❌ 不看 nvidia-smi 就判定"模型在跑"
- ❌ 有真实代码/配置适配却把 `repair_count` 写 0、`fixes_applied` 留空 — 适配动作(改 import/config/patch 代码)都必须入账
- ❌ **`git checkout`/`git switch` 切分支当"修复手段"** — 丢补丁 + 结构不兼容(R11,SCAIL 实测);切分支的念头 = 该 paused_for_human 让人决策了

## ChangeLog

- **2026-06-11** — P10/P11/P12 规则下沉本 SKILL(SubAgent 收不到 CLAUDE.md,S-1)
  - 变更类型: 硬约束 + 流程 + 反模式
  - 影响范围: 第 2 步 poll 动态间隔 / 第 5 步轮次分类 + 分支纪律 / 反模式段
  - 动机: SCAIL 试跑(2026-06-11)三个教训 — 切 wan 分支丢补丁、flash_attn 缺失烧掉最后一轮、resharding 被 poll 预算截断;原修复只写在 CLAUDE.md,但 run-and-repair SubAgent 看不到 CLAUDE.md(#31 S-1),规则必须在 SKILL 内才到达执行者
  - 证据: [fixes/2026-06-11-p1-p12-implementation-corrections-fix.md](../../../docs/superpowers/fixes/2026-06-11-p1-p12-implementation-corrections-fix.md) + specs/2026-06-11-试跑复盘与验证清单.md

- **2026-06-10** — repair_log 统计口径扩大(适配动作都算修复)
  - 变更类型: schema 语义 + 反模式
  - 影响范围: 返回 schema 说明 / 反模式段
  - 动机: omnivoice transcript 有 52 处真实代码适配,run.json 写 repair_count=0,下游报告失真
  - 证据: [fixes/2026-05-29-run-json-process-field-inaccurate-fix.md](../../../docs/superpowers/fixes/2026-05-29-run-json-process-field-inaccurate-fix.md)
