# Qwen Base Claude Code Harness Quickstart

这份文档只讲一件事：

把本地 Qwen 模型跑起来，让 `claude-haha` 能正常连上。

不需要改 `claudecode` 主体代码。启动链路只有 3 层：

1. `vLLM` 读取本地模型目录，提供 OpenAI 接口
2. `anthropic-qwen-proxy` 把 Anthropic 接口转到 OpenAI 接口
3. `claude-haha` 正常走 Anthropic 接口，但实际连的是本地代理

## 0. 先确认模型已经下完

模型目录：

```bash
/home/ps/.cache/modelscope/hub/models/Qwen/Qwen3.6-35B-A3B
```

如果你不确定有没有下完，先看日志：

```bash
tail -f /home/ps/.cache/modelscope/logs/qwen3.6-35b-a3b_modelscope.log
```

看到类似 `download finished successfully` 再继续。

## 1. 启动 vLLM

先开一个新终端。

这台机器上 `vllm-env` 缺默认动态库路径，所以先补 `LD_LIBRARY_PATH`。
另外这份 `Qwen3.6-35B-A3B` 默认会按 `262144` 上下文启动，显存压力非常大，直接照模型默认值跑，第一次对话就可能 `CUDA out of memory`。

下面这份是更稳的启动模板，优先保证 Claude Code 能用起来。你只需要改一处：

- `CUDA_VISIBLE_DEVICES`
- `--tensor-parallel-size`

这两个数字要一致。

例子：如果你用 4 张卡，就写 `0,1,2,3` 和 `4`。

```bash
export CUDA_VISIBLE_DEVICES=0,1,2,3
export LD_LIBRARY_PATH=/home/ps/miniconda3/envs/cosyvoice/lib/python3.10/site-packages/nvidia/nccl/lib:/home/ps/miniconda3/envs/cosyvoice/lib/python3.10/site-packages/nvidia/nvshmem/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

/home/ps/miniconda3/envs/vllm-env/bin/python -m vllm.entrypoints.openai.api_server \
  --model /home/ps/.cache/modelscope/hub/models/Qwen/Qwen3.6-35B-A3B \
  --served-model-name Qwen3.6-35B-A3B \
  --host 127.0.0.1 \
  --port 8000 \
  --tensor-parallel-size 4 \
  --trust-remote-code \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --max-model-len 32768 \
  --max-num-seqs 1 \
  --gpu-memory-utilization 0.82 \
  --enforce-eager
```

启动后，另开一个终端检查：

```bash
curl http://127.0.0.1:8000/v1/models
```

能看到 `Qwen3.6-35B-A3B` 就说明 vLLM 正常。

如果你后面想要更长上下文，再逐步往上试：

1. 先把 `--max-model-len 32768` 改成 `65536`
2. 还不够再把 `--gpu-memory-utilization 0.82` 慢慢加到 `0.85`

不要一开始就用模型默认的 `262144`，这对 Claude Code 单用户场景太激进。

## 2. 启动 Anthropic 兼容代理

再开一个新终端：

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1

export OPENAI_BASE_URL=http://127.0.0.1:8000/v1
export OPENAI_API_KEY=EMPTY
export ANTHROPIC_PROXY_MODEL=Qwen3.6-35B-A3B
export ANTHROPIC_PROXY_PORT=8082
export ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=4096

bun run anthropic-qwen-proxy
```

如果你没有 `bun` 在 PATH 里，也可以直接用：

```bash
/home/ps/dcr_claude_home/.bun/bin/bun run anthropic-qwen-proxy
```

这里的 `ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=4096` 很重要。

原因是 Claude Code full harness 往往会按大模型习惯请求很高的输出上限，比如 `32000`。
但你本地这份 Qwen 现在只按 `32768` 上下文在跑，如果不裁掉输出上限，就会把输入预算挤没，直接报 context length error。

检查代理是否正常：

```bash
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8082/v1/models
```

只要能返回 JSON，就说明代理正常。

## 3. 启动 Claude Code Harness

再开一个新终端：

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1

export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
export ANTHROPIC_AUTH_TOKEN=dummy
export ANTHROPIC_MODEL=Qwen3.6-35B-A3B
export ANTHROPIC_DEFAULT_SONNET_MODEL=Qwen3.6-35B-A3B
export ANTHROPIC_DEFAULT_HAIKU_MODEL=Qwen3.6-35B-A3B
export ANTHROPIC_DEFAULT_OPUS_MODEL=Qwen3.6-35B-A3B
export API_TIMEOUT_MS=600000
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

### 先用最稳的简化模式测试

先确认最基础链路是通的：

```bash
CLAUDE_CODE_FORCE_RECOVERY_CLI=1 ./bin/claude-haha
```

进来后直接问一句：

```text
你好，告诉我你现在连的是哪个模型
```

如果能正常回答，说明整条链路已经通了。

### 再启动完整 harness

基础链路没问题后，直接跑完整模式：

```bash
./bin/claude-haha
```

## 4. 一共要开几个终端

最简单就是 3 个：

1. `vLLM`
2. `anthropic-qwen-proxy`
3. `claude-haha`

如果你还想盯模型下载日志，就再多开一个终端看下载日志。

## 5. 最常见的问题

### 问题 1：vLLM 一启动就报 `libnccl.so.2` 或 `libnvshmem_host.so.3`

说明你没带上这句：

```bash
export LD_LIBRARY_PATH=/home/ps/miniconda3/envs/cosyvoice/lib/python3.10/site-packages/nvidia/nccl/lib:/home/ps/miniconda3/envs/cosyvoice/lib/python3.10/site-packages/nvidia/nvshmem/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
```

### 问题 2：`curl http://127.0.0.1:8000/v1/models` 不通

说明 vLLM 没起来，先别看代理和 harness。

### 问题 3：`curl http://127.0.0.1:8082/health` 不通

说明代理没起来，先别看 harness。

### 问题 4：`claude-haha` 进去了但是一发消息就报错

按顺序检查：

1. `8000` 的 vLLM 还在不在
2. `8082` 的代理还在不在
3. harness 终端里环境变量是不是都设置了
4. `ANTHROPIC_MODEL` 和 `ANTHROPIC_PROXY_MODEL` 是不是都写成了 `Qwen3.6-35B-A3B`

如果 `vLLM` 日志里看到 `Triton Error [CUDA]: out of memory`，说明不是代理错了，是模型推理时爆显存了。
先把 `vLLM` 改成这几个保守参数：

- `--max-model-len 32768`
- `--max-num-seqs 1`
- `--gpu-memory-utilization 0.82`
- `--enforce-eager`

## 6. 最短启动顺序

如果你只想照着敲，顺序就是：

1. 等模型下载完成
2. 起 vLLM
3. 起代理
4. 起 `CLAUDE_CODE_FORCE_RECOVERY_CLI=1 ./bin/claude-haha`
5. 通了以后再跑 `./bin/claude-haha`

## 7. 这份 quickstart 用到的文件

- Claude Code 仓库根目录：[claudecode_sourcecode1](/home/ps/dcr/claudecode/claudecode_sourcecode1)
- 代理脚本：[proxy/anthropic-qwen-proxy.ts](/home/ps/dcr/claudecode/claudecode_sourcecode1/proxy/anthropic-qwen-proxy.ts:1)
- 代理启动脚本：[bin/anthropic-qwen-proxy](/home/ps/dcr/claudecode/claudecode_sourcecode1/bin/anthropic-qwen-proxy:1)
- Harness 启动脚本：[bin/claude-haha](/home/ps/dcr/claudecode/claudecode_sourcecode1/bin/claude-haha:1)
