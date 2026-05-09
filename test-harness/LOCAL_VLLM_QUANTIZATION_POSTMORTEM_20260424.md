# Qwen3.6-35B-A3B 本地量化尝试记录（vLLM）

更新时间：2026-04-24  
目录：`/home/ps/dcr/claudecode/claudecode_sourcecode1/test-harness`

## 1. 目标与环境

- 目标：在本地部署 `Qwen3.6-35B-A3B`，尽量兼顾回答质量、速度、显存稳定性（避免 OOM），并用于 Claude Code Harness。
- 机器：`RTX 5090 x8`，主要尝试使用 `GPU 0,1,2,3`。
- 服务链路：`claude-haha -> anthropic-qwen-proxy(8082) -> vLLM(18083) -> Qwen3.6-35B-A3B`。
- 模型目录：`/home/ps/.cache/modelscope/hub/models/Qwen/Qwen3.6-35B-A3B`
- vLLM 版本：`0.17.0`

## 2. 尝试记录（按时间）

### 尝试 A：bitsandbytes 4bit（NF4）+ TP=4 + 128K

- 关键参数：`--quantization bitsandbytes --load-format bitsandbytes --tensor-parallel-size 4 --max-model-len 131072`
- 结果：启动失败。
- 核心报错：
  - `NotImplementedError: Shard id with multiple indices is not supported for BNB quantization with TP yet.`
- 结论：当前模型 + 当前 vLLM 下，`BNB 4bit + TP` 不可用。

### 尝试 B：bitsandbytes 4bit（NF4）+ PP=4 + TP=1（规避 TP 限制）

- 关键参数：`--pipeline-parallel-size 4 --tensor-parallel-size 1`
- 结果：仍失败。
- 核心报错：
  - `RuntimeError: The size of tensor a (...) must match the size of tensor b (...)`
  - 报错位置集中在 MoE/fused expert 权重加载。
- 结论：当前组合下 BNB 4bit 路线整体不可落地。

### 尝试 C：FP8 权重 + FP8 KV（TP=4，131072）

- 关键参数：`--quantization fp8 --kv-cache-dtype fp8 --calculate-kv-scales`
- 结果：可启动，但在部分配置和请求下出现运行期崩溃。
- 核心报错：
  - `RuntimeError: Triton Error [CUDA]: out of memory`
- 结论：能跑但对参数敏感，激进配置易在 warmup 或首批请求时 OOM。

### 尝试 D：FP8 稳定档（eager 模式）

- 关键参数：
  - `--enforce-eager`
  - `--gpu-memory-utilization 0.82`
  - `--max-num-seqs 1`
  - `--max-num-batched-tokens 4096`
- 结果：稳定性显著提升，OOM 风险下降。
- 代价：吞吐下降，实测常见 `generation throughput ~14-15 tok/s`。
- 结论：这是“保稳定”的可用档，但速度一般。

### 尝试 E：平衡档（去 eager，开 compile/cudagraph）

- 关键参数：
  - `--enforce-eager` 去掉
  - `--max-num-seqs 2`
  - `--max-num-batched-tokens 3072`
  - `--gpu-memory-utilization 0.80`
- 结果：服务可启动，但回答质量异常。
- 现象：
  - 简单问答出现固定错误模式，如 `Here's a thinking process...`、重复模板、无关内容拼接。
  - 同样问题在 `/v1/chat/completions` 与 `/v1/completions` 两个接口均可复现。
- 关键信号：
  - 日志反复出现：`Using uncalibrated q_scale 1.0 and/or prob_scale 1.0 with fp8 attention. This may cause accuracy issues.`
- 结论：当前 FP8 路径虽快，但在该模型上存在明显质量失真风险。

### 尝试 F：质量修复（把 KV 改为 bfloat16）

- 关键参数：`--kv-cache-dtype bfloat16`
- 结果：直接启动失败。
- 核心报错：
  - `RuntimeError: Unsupported data type of kv cache: bfloat16`
- 结论：当前后端路径不支持该 KV dtype 组合。

## 3. 综合结论

1. `BNB 4bit` 路线在当前环境不可行（TP/PP 两条都失败）。
2. `FP8 权重 + FP8 KV` 路线可启动，但存在两类风险：
   - 稳定性风险：参数激进时 OOM。
   - 质量风险：输出污染或退化（与未校准 FP8 缩放相关）。
3. 单纯通过改 `max_output` 或代理参数不能根治质量问题，根因在模型推理精度路径。

## 4. 当前建议（按优先级）

### 建议 1：质量优先（本地）

- 采用 `BF16 权重`（不做权重量化）+ `FP8 KV`
- 初始保守参数：
  - `--max-model-len 65536`
  - `--gpu-memory-utilization 0.78`
  - `--max-num-seqs 1`
  - `--max-num-batched-tokens 2048`
- 稳定后再逐步上调。

### 建议 2：稳定优先（本地）

- 使用 `FP8 eager 稳定档`，接受速度下降，换取较低 OOM 概率。

### 建议 3：质量与生产可用优先

- 直接切云端 API（如 DashScope / DeepSeek），避免本地 FP8 路径质量漂移。

## 5. 后续调参顺序（一次只改一项）

1. `max-num-batched-tokens`：`2048 -> 3072`
2. `gpu-memory-utilization`：`0.78 -> 0.80`
3. `max-num-seqs`：`1 -> 2`（最容易触发 OOM，最后改）
4. `max-model-len`：在稳定后再从 `65536` 往上试

## 6. 相关日志文件

- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_fp8kv_128k_gpu0123.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_fp8kv_128k_gpu0123_fix.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_stable_gpu0123.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_fastsafe_gpu0123.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_balanced_gpu0123.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_noprefix_gpu0123.log`
- `~/.cache/vllm_logs/qwen3.6-35b-a3b_fp8_quality_gpu0123.log`

