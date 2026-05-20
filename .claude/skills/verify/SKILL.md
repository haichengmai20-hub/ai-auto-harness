---
name: verify
description: 独立判定项目是否真能跑 — 不读 run-and-repair 修复历史(独立 SubAgent)
allowed-tools: [Read, Bash]
agent: verify-agent
---

# verify

## 落盘约定(必读)

- **日志**:`$WORKSPACE/logs/verify.log` — 启动检查 + smoke test + GPU 监测 全输出 append
- **结果**:`$WORKSPACE/results/verify.json` — return schema

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
LOG="$WORKSPACE/logs/verify.log"
echo "==== verify start at $(date -Iseconds) ====" >> "$LOG"
```

注:你**只 Read + Bash**(无 Edit/Write),所以"写日志"也只能通过 `tee -a "$LOG"` 这样的 bash 命令(`bash -c 'cmd 2>&1' | tee -a "$LOG"` 或 `cmd 2>&1 >> "$LOG"`).

`results/verify.json` 用 `bash -c 'cat > $WORKSPACE/results/verify.json <<JSON ... JSON'` 写.

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "venv_path": "<workspace>/venv",
  "entry_script": "...",
  "run_id": "<from 主 agent>"
}
```

**注意**:**你不会收到** RunResult / VerifyState 历史。也不应该主动 Read state.json 的 run_result 字段。

## 第 0 步:设置环境(每次跑 bash 前)

```bash
source "$VENV_PATH/bin/activate"
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export TRANSFORMERS_CACHE="$WORKSPACE/.cache/transformers"
```

## 第 1 步:启动检查(冷启动一次,短任务)

试 `<entry_script> --help`,或对应的 quickstart 命令:

```bash
cd "$WORKSPACE/repo"
echo "---- startup check ----" >> "$LOG"
$ENTRY_SCRIPT --help 2>&1 | tee -a "$LOG" | head -20
# 或者 python -c "<from entry_script 推断的顶层 import>" 2>&1 | tee -a "$LOG"
```

判定:
- 退出码 = 0 → 启动 OK,进第 2 步
- 退出码 != 0 → `passed=false, failed_at="startup"`,记 stderr,**停止**

不要尝试装 deps 修复 — 那是 install-env 的事;不要修代码 — 那是 runner 的事。

## 第 2 步:功能检查(smoke test)

读 `$WORKSPACE/repo/README.md` 找**最小** demo 命令(优先选 README 里明显"5 分钟见效"那种)。

```bash
cd "$WORKSPACE/repo"
# 设置 CUDA_VISIBLE_DEVICES(从 state.json 读 gpu_picks,但不读 run_result)
GPU=$(jq -r '.intake_result.gpu_picks[0]' "$WORKSPACE/state.json" 2>/dev/null || echo "0")
export CUDA_VISIBLE_DEVICES=$GPU

# 跑 smoke (timeout 适度短,smoke 应该是几分钟级,不是几十分钟)
echo "---- smoke test ----" >> "$LOG"
timeout 600 <smoke_cmd> 2>&1 | tee -a "$LOG" | tail -50
```

判定输出"合理性"(LLM 用 domain knowledge):

| 模型类型 | 合理判定 |
|---|---|
| 文本生成 | 输出是连贯文本,不是随机 token / 全 0 / 重复字符 |
| 图像生成 | 输出文件大小合理(几百 KB 到几 MB),非全黑/全白 PNG |
| 视频生成 | `ffmpeg -i out.mp4 2>&1 \| grep "Stream"` 能读出 video stream |
| 音频生成 | 文件采样率/时长合理(用 `ffprobe` 看)|

退出码 0 + 输出合理 → smoke OK,进第 3 步.

## 第 3 步:GPU 利用率检查

第 2 步跑的同时(或单独再跑一次 smoke),另一个 bash poll:

```bash
echo "---- gpu utilization ----" >> "$LOG"
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader -l 2 | head -10 | tee -a "$LOG"
```

判定:
- GPU `memory.used` > 1024 MiB(否则可能是 CPU fallback)
- 至少一次采样 `utilization.gpu` > 10%(否则没真在跑计算)

GPU 利用 OK → `passed=true`,进返回.

GPU 利用低(< 1GB used 或全程 0% 利用)→ `passed=false, failed_at="gpu_utilization"`,可能是模型 fallback CPU 或装错.

## 第 4 步:汇总判定

| 步骤 | 通过条件 | 失败 → failed_at |
|---|---|---|
| 1 启动 | exit_code=0 | "startup" |
| 2 smoke | exit_code=0 + 输出合理 | "smoke_test" |
| 3 GPU 利用 | mem>1GB 且 util>10% | "gpu_utilization" |

三步都过 → `passed=true`,verify 完成

任一失败 → `passed=false`,**不要重试**(verify 不修问题)— 写 evidence 后返回

## 返回 schema

```json
{
  "passed": true,
  "failed_at": null,
  "evidence": {
    "startup_exit_code": 0,
    "smoke_stdout_snippet": "<last 500 chars>",
    "smoke_exit_code": 0,
    "gpu_stats": {
      "memory_used_mb": 18432,
      "utilization_pct": 87
    },
    "output_files": ["sample/output/audio_001.mp3"]
  },
  "notes": "smoke 生成 5s 音频文件,GPU 87% 利用率正常",
  "confidence": "high"
}
```

失败情况:

```json
{
  "passed": false,
  "failed_at": "gpu_utilization",
  "evidence": {
    "startup_exit_code": 0,
    "smoke_stdout_snippet": "...",
    "smoke_exit_code": 0,
    "gpu_stats": {
      "memory_used_mb": 234,
      "utilization_pct": 0
    }
  },
  "notes": "推理跑通了但 GPU 几乎没用,可能 fallback 到 CPU — 装 torch / config 有问题",
  "confidence": "high"
}
```

## 强制要求(返回前)

1. **写 results/verify.json**(用 bash heredoc,因为你无 Write 工具):
   ```bash
   bash -c "cat > '$WORKSPACE/results/verify.json' <<JSON
   {
     \"passed\": <true|false>,
     \"failed_at\": <null | step name>,
     \"evidence\": { ... },
     \"notes\": \"<判定说明>\",
     \"confidence\": \"<high|medium|low>\",
     \"completed_at\": \"$(date -Iseconds)\"
   }
   JSON"
   ```

2. **append 一条到 `runs/$RUN_ID/decisions.md`**(同样用 bash echo / cat):
   ```bash
   echo "- $(date -Iseconds) by verify-agent: startup ✓ / smoke ✓ / gpu_util ✓ → PASS" >> "runs/$RUN_ID/decisions.md"
   ```

3. **结束日志**:
   ```bash
   echo "==== verify end at $(date -Iseconds) ====" >> "$LOG"
   ```

主 agent 会另外把 return JSON 也写到 `runs/$RUN_ID/verify.json`(本次 cron 快照).

## 我做错了什么?常见诱惑

- ❌ "smoke fail 了,可能是 batch_size 太大,我改下 config 重跑" — **不**.你没 Edit 工具.runner 的事
- ❌ "GPU 利用率 0%,但 smoke 出文件了,算 pass 吧" — **不**.GPU 0% = 没真用模型,严格 fail
- ❌ "看下 runner 之前是怎么修的" — **不**.读 run_result 破坏独立判定原则
