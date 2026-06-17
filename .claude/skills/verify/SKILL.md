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
echo "=== PHASE_START phase=verify slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
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

## 第 0.6 步:entry_type 分流

```bash
ET=$(jq -r '.intake_result.entry_type // "script"' "$WORKSPACE/state.json" 2>/dev/null)
```
`script` → 走现有第 1-4 步。`service` → 走「服务验证」(独立重跑,不读 run_result)。

## 服务验证(entry_type=service,F11)

```bash
export AI_HARNESS_RUN_ID="${AI_HARNESS_RUN_ID:-$RUN_ID}"
export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
LC=/root/ai-auto-harness/scripts/service-lifecycle.sh
bash "$LC" start "$WORKSPACE" 2>&1 | tee -a "$LOG"
bash "$LC" wait-ready "$WORKSPACE" 1800 2>&1 | tee -a "$LOG"; READY=$?
# infer + 验产物 + GPU 利用
if [ "$READY" -eq 0 ]; then
  INFER=$(jq -r '.intake_result.service.infer_cmd' "$WORKSPACE/state.json")
  ( cd "$WORKSPACE/repo" && eval "$INFER" ) 2>&1 | tee -a "$LOG"
  nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader | head -3 | tee -a "$LOG"
fi
bash "$LC" stop "$WORKSPACE" 2>&1 | tee -a "$LOG"   # verify 也必停
```

判定 → 写进现有 7 字段(不新增顶层字段):
- start_cmd 起不来 / ready 始终不达成 → `passed=false, failed_at="startup"`
- ready 成、infer 失败/产物不合理 → `passed=false, failed_at="smoke_test", verify_level="L0"`(就绪但没真跑通=降级档)
- infer 产物合理 + GPU(mem>1GB & 至少一次 util>10%)→ `passed=true, verify_level="L1"`
- `evidence` 加:`"ready_signal_met": <bool>, "infer_status": "<http code 或 exit>", "output_files": [...]`

**verify_level 语义对齐**:service 的 L0=仅就绪、L1=真往返,与 script 的 L0=存在性/L1=内容级**同向**(L1 总是"更强证据"),下游 `jq -r '.verify_level'` 无需区分 entry_type。

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

### 验证级别(verify_level — 结果必须标注)

上面 3 步 = **L0**(存在性/格式/GPU 真在跑)。L0 过不代表内容对——"有声音且够长"≠"声音是要的"。若环境里有现成工具,**再做 L1 内容级抽查**并升级标注:

| 模型类型 | L1 检查(任选其一,有工具才做,不为 L1 新装包) |
|---|---|
| TTS/音频 | ASR 回环:输出→whisper/ASR→与输入文本比对,CER 明显低 |
| 3D | 网格完整性:面数 > 1000 且无 degenerate face(trimesh 一行) |
| 图像 | 非纯色/噪声:像素方差合理;有 CLIP 则 CLIP score 与 prompt 相关 |
| 文本 | 输出与 prompt 语义相关(LLM 自查即可) |

- 只做了 3 步基础检查 → `verify_level: "L0"`
- 额外做了内容级检查且通过 → `verify_level: "L1"`
- **L1 失败但 L0 过** → `passed=false, failed_at="content_check"`(内容不对=没部署对)

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
  "confidence": "high",
  "verify_level": "L0"
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
  "confidence": "high",
  "verify_level": "L0"
}
```

## 强制要求(返回前)

1. **写 results/verify.json — 必须含下列 7 个根字段,严禁自创 schema**:

   下游(cleanup G4 / auto-status / write-recommendation)用 `jq -r '.passed'` 读判定。**字段缺失 = 下游误判**。L1 实测 hunyuan3d-2 / omnivoice 都因为 LLM 自由写 schema(用 `status`+`checks` 或 `status`+`verdict`)导致 `passed` 字段缺失,被 cleanup G4 误判 verify_not_passed。

   **必须**用下面这个**精确**的 bash heredoc 写,不许改字段名:

   ```bash
   PASSED_VAL=true                  # 真实判定:true 或 false (字符串,无引号)
   FAILED_AT_VAL=null               # 真实:null 或 "startup"|"smoke_test"|"gpu_utilization" (带引号)
   CONFIDENCE_VAL='"high"'          # "high" | "medium" | "low"
   VERIFY_LEVEL_VAL='"L0"'          # "L0"(仅 3 步基础) | "L1"(做了内容级抽查)
   NOTES_VAL='"<判定说明,单行>"'    # 一句话

   bash -c "cat > '$WORKSPACE/results/verify.json' <<JSON
   {
     \"passed\": $PASSED_VAL,
     \"failed_at\": $FAILED_AT_VAL,
     \"evidence\": {
       \"startup_exit_code\": <int>,
       \"smoke_stdout_snippet\": \"<last 500 chars>\",
       \"smoke_exit_code\": <int>,
       \"gpu_stats\": {\"memory_used_mb\": <int>, \"utilization_pct\": <int>},
       \"output_files\": [<paths>]
     },
     \"notes\": $NOTES_VAL,
     \"confidence\": $CONFIDENCE_VAL,
     \"verify_level\": $VERIFY_LEVEL_VAL,
     \"completed_at\": \"$(date -Iseconds)\"
   }
   JSON"
   ```

2. **写完立即自检 schema** — `jq -e` 验证 7 个根字段都在,任一缺失即 raise + 重写:

   ```bash
   for f in passed failed_at evidence notes confidence verify_level completed_at; do
       jq -e --arg k "$f" 'has($k)' "$WORKSPACE/results/verify.json" >/dev/null \
           || { echo "FATAL verify.json 缺字段: $f" >&2; exit 1; }
   done
   jq -e '.passed | type == "boolean"' "$WORKSPACE/results/verify.json" >/dev/null \
       || { echo "FATAL verify.json .passed 必须是 boolean(true/false),不能是 null/string" >&2; exit 1; }
   ```

3. **append 一条到 `$RUN_DIR/decisions.md`**(同样用 bash echo / cat;`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`,slug 已知时即 `workspace/<slug>/runs/<id>/`):
   ```bash
   RUN_DIR="${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}"
   echo "- $(date -Iseconds) by verify-agent: startup ✓ / smoke ✓ / gpu_util ✓ → PASS" >> "$RUN_DIR/decisions.md"
   ```

4. **结束日志**:
   ```bash
   echo "==== verify end at $(date -Iseconds) ====" >> "$LOG"
   echo "=== PHASE_END   phase=verify slug=$SLUG status=done ts=$(date -Iseconds) ===" | tee -a "$LOG"
   ```

主 agent 会另外把 return JSON 也写到 `$RUN_DIR/verify.json`(本次 cron 快照,`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`).

## 🔴 反模式(L1 实测出现过的真实问题,**严禁重演**)

- ❌ **自创 verify.json schema** — `{status, checks, ...}` 或 `{status, verdict, ...}` 都不行(L1 实测 hunyuan3d-2 + omnivoice 撞过)。**必须** 7 字段 `passed/failed_at/evidence/notes/confidence/verify_level/completed_at`。下游 cleanup G4 `jq -r '.passed'` 拿到 null → 误判 verify 没过
- ❌ **passed 字段写字符串** — `"passed": "true"` 不行,必须 boolean `true`/`false`。第 2 步 jq -e 会拦
- ❌ **缺 failed_at** — passed=true 时填 `null`(JSON null,不是字符串 "null");passed=false 时填具体 step name 字符串
- ❌ **smoke fail 了改 config 重跑** — 你没 Edit 工具,runner 的事。verify 只判定不修
- ❌ **GPU 利用率 0% 但 smoke 出文件 → 算 pass** — 不行,GPU 0% = 没真用模型,严格 fail
- ❌ **读 run_result 之前怎么修的** — 破坏独立判定原则
- ❌ **service verify 后没 stop backend** — backend 占 GPU 孤儿(ephemeral 铁律:成功/失败/超时都必须 stop)
- ❌ **ready 成就判 passed(没发 infer 就标 L1)** — ready 只是服务在线,L1 要求真实推理往返产物合理;ready 成 infer 未验=最多 L0

## 我做错了什么?常见诱惑

- ❌ "我用更详细的 schema(加 verdict、original_output_ok 之类)能更清楚表达" — **不**.下游靠固定字段名 grep,自创字段 = 对下游隐形.信息丰富 = 写到 `evidence` 子对象,不是顶层新字段
- ❌ "passed 真假我不确定,我写 null 让人决定" — **不**.verify 的存在就是给布尔判定.不确定 = 走 `passed:false, failed_at:"gpu_utilization"` 或类似,**永远不写 null**
- ❌ "smoke fail 了,可能是 batch_size 太大,我改下 config 重跑" — **不**.你没 Edit 工具.runner 的事
- ❌ "看下 runner 之前是怎么修的" — **不**.读 run_result 破坏独立判定原则

## ChangeLog

- **2026-06-10** — 加 verify_level 分级验证(L0 存在性 / L1 内容级)
  - 变更类型: schema(根字段 6→7)+ 流程
  - 影响范围: 第 4 步后新增"验证级别"段 / 返回 schema / 强制要求 heredoc + 自检 / `scripts/validate-verify.sh`(V2 列表 + 新 V6)
  - 动机: "有声音且够长"≠"声音是要的" — L0 全过仍可能内容不对,下游需要知道验到哪一级
  - 证据: [fixes/2026-05-29-verify-content-level-check-fix.md](../../../docs/superpowers/fixes/2026-05-29-verify-content-level-check-fix.md)
  - 验证: ✅ validate-verify.sh fixture 双向(含 verify_level PASS / 缺失 FAIL)

- **2026-06-16** — F11 service 独立验证路径 + verify_level L0/L1 语义对齐
  - 变更类型: 流程 + schema(evidence 子字段) + 反模式
  - 影响范围: 第 0.6 步(entry_type 分流) + 服务验证段(start/wait-ready/infer/必停) + evidence 子字段(ready_signal_met/infer_status/output_files) + verify_level 语义(service L0=仅就绪/L1=真往返,与 script 同向) + 反模式两条(没 stop backend / ready 成就判 L1)
  - 动机: F1 服务型支持 — vLLM/Gradio/Flask 类项目需独立 start→wait-ready→infer→验产物→stop 验证链,7 根字段不变,evidence 子对象扩展
  - 证据: [docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md](../../../docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md)
  - 验证: bash -n 自检通过;grep 确认第 0.6 步位置 + 7 字段 schema 不变 + verify_level 语义 + 必停
