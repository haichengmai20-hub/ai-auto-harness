# Claude API Harness Quickstart

这份文档只讲一件事：

不用本地 `vLLM`，直接让 `claude-haha` 走远程 API。

适合两种场景：

1. 直接走 Anthropic 官方 API
2. 走第三方 Anthropic-compatible API

## 1. 现在仓库里已经改成 API 模式

当前默认环境文件是：

```bash
/home/ps/dcr/claudecode/claudecode_sourcecode1/.env
```

它不再指向本地 `localhost:4000`。

原来的本地 Qwen 配置我给你保存在：

```bash
/home/ps/dcr/claudecode/claudecode_sourcecode1/.env.local-qwen.example
```

如果以后想切回本地，可以再参考那份文件。

## 2. 如果你走 Anthropic 官方 API

编辑 `.env`，至少改这一行：

```env
ANTHROPIC_API_KEY=replace_with_real_api_key
```

通常不需要设置 `ANTHROPIC_BASE_URL`。

默认模型已经改成：

```env
ANTHROPIC_MODEL=claude-sonnet-4-6
```

## 3. 如果你走第三方 Anthropic-compatible API

把 `.env` 里这行：

```env
ANTHROPIC_API_KEY=replace_with_real_api_key
```

改成注释或删掉，然后填你自己的：

```env
ANTHROPIC_AUTH_TOKEN=replace_with_real_bearer_token
ANTHROPIC_BASE_URL=https://your-provider.example.com/anthropic
ANTHROPIC_MODEL=your-provider-model-name
ANTHROPIC_DEFAULT_SONNET_MODEL=your-provider-model-name
ANTHROPIC_DEFAULT_HAIKU_MODEL=your-provider-model-name
ANTHROPIC_DEFAULT_OPUS_MODEL=your-provider-model-name
```

## 4. 启动

仓库根目录执行：

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
./bin/claude-haha
```

`bin/claude-haha` 会自动读取 `.env`。

如果你想先走最简单模式排错：

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
CLAUDE_CODE_FORCE_RECOVERY_CLI=1 ./bin/claude-haha
```

## 5. 你现在不需要再启动这些

切到 API 模式以后，不需要再起：

1. 本地 `vLLM`
2. `anthropic-qwen-proxy`
3. 本地模型下载/显存相关链路

## 6. 最短使用流程

1. 打开 `.env`
2. 填真实 API key 或 Bearer token
3. 如果是第三方，再填 `ANTHROPIC_BASE_URL`
4. 运行 `./bin/claude-haha`

## 7. 常见问题

### 问题 1：报认证错误

检查：

1. `ANTHROPIC_API_KEY` 或 `ANTHROPIC_AUTH_TOKEN` 是否填了真实值
2. 第三方网关是否还需要 `ANTHROPIC_BASE_URL`

### 问题 2：报模型不存在

说明 `.env` 里的 `ANTHROPIC_MODEL` 不是你的 API 提供方支持的模型名，改成提供方实际模型名即可。

### 问题 3：还在连本地

确认 `.env` 里没有：

```env
ANTHROPIC_BASE_URL=http://localhost:4000
```

也没有运行本地 `vLLM` / `anthropic-qwen-proxy`。
