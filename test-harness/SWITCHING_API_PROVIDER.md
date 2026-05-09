# 切换 API Provider 排错手册

记录从 DeepSeek 代理模式切换到第三方 Anthropic-compatible API（讯飞 MAAS）时遇到的所有问题及解法。

---

## 背景

本 harness 默认走 **DeepSeek 代理模式**（本地 proxy → OpenAI 格式转换 → Anthropic SDK），需要两个终端。

切换到直连 Anthropic-compatible API（如讯飞 MAAS）时，只需一个终端，但有多个坑。

---

## 问题一：ConnectionRefused

**现象**
```
Unable to connect to API (ConnectionRefused)
Retrying in 35 seconds… (attempt 8/10)
```

**根因**

`.env.cc_keys` 里的 `HTTP_PROXY` / `HTTPS_PROXY` 仍指向 DeepSeek 模式的本地代理地址（`172.16.6.179:61080`）。切换到直连 API 后代理进程未启动，所有出站请求被路由到死地址。

**解法**

切换到直连模式时，注释掉 `.env.cc_keys` 中的代理行：

```env
#HTTP_PROXY=http://172.16.6.179:61080/
#HTTPS_PROXY=http://172.16.6.179:61080/
#NO_PROXY=127.0.0.1,localhost,::1
```

**验证 API 是否直连可达（绕过所有代理）：**

```bash
curl -v -x "" \
  -H "x-api-key: <YOUR_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"<MODEL>","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}' \
  <BASE_URL>/v1/messages
```

`-x ""` 强制忽略所有代理环境变量。返回 200 说明 API 本身可达。

---

## 问题二：401 HMAC signature cannot be verified: apikey not found（第一层）

**现象**
```
401 HMAC signature cannot be verified: apikey not found
Retrying in 19 seconds… (attempt 6/10)
```

**根因**

`start_harness.sh` 有这一行：

```bash
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-dummy}"
```

当 `ANTHROPIC_AUTH_TOKEN` 未设置时，强制赋值 `dummy`。Anthropic SDK 优先使用 `ANTHROPIC_AUTH_TOKEN`，将其作为 `Authorization: Bearer dummy` 发出。部分第三方 API（如讯飞）不接受 Bearer 格式，只接受 `x-api-key` 格式，因此报 401。

**认证头区别：**

| 环境变量 | SDK 发出的 Header |
|---|---|
| `ANTHROPIC_API_KEY` | `x-api-key: <value>` |
| `ANTHROPIC_AUTH_TOKEN` | `Authorization: Bearer <value>` |

**解法**

修改 `start_harness.sh`，有 `ANTHROPIC_API_KEY` 时主动 unset 掉残留的 `ANTHROPIC_AUTH_TOKEN`：

```bash
# 直连模式：清除 AUTH_TOKEN，走 x-api-key
# 代理模式（无 API_KEY）：设 dummy 供本地 proxy 用
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  unset ANTHROPIC_AUTH_TOKEN
else
  export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-dummy}"
fi
```

---

## 问题三：401 HMAC signature cannot be verified: apikey not found（第二层）

**现象**

同上，但 `ANTHROPIC_AUTH_TOKEN` 已经 UNSET，代理也已关闭，curl 直连返回 200，harness 仍然 401。

**根因**

CC harness 在 `~/.claude/.credentials.json` 中存储了 Claude.ai OAuth token（`sk-ant-oat01-...`）。鉴权逻辑如下（`src/services/api/client.ts`）：

```typescript
// isClaudeAISubscriber() == true 时走 OAuth 路径
apiKey: isClaudeAISubscriber() ? null : getAnthropicApiKey(),
authToken: isClaudeAISubscriber()
  ? getClaudeAIOAuthTokens()?.accessToken   // ← OAuth token 作为 Bearer
  : undefined,
```

`isClaudeAISubscriber()` 由 `isAnthropicAuthEnabled()` 控制，其判断逻辑：

```typescript
// src/utils/auth.ts
const hasExternalApiKey = apiKeySource === 'ANTHROPIC_API_KEY'
const shouldDisableAuth = hasExternalApiKey && !isManagedOAuthContext()
return !shouldDisableAuth  // 只有外部 key 被识别时才禁用 OAuth
```

`ANTHROPIC_API_KEY` 被识别为"外部 key"的条件：**key 的后 20 位必须在 `~/.claude.json` 的 `customApiKeyResponses.approved` 列表中**。

**子问题：key 在 rejected 列表**

之前启动 harness 时弹出"是否信任此 API key"交互提示，若选择拒绝，key 进入 `rejected` 列表，永远不会被识别为外部 key，OAuth 路径持续生效。

注意：此交互提示只在 TUI 里出现一次，不起眼，容易误操作。

**解法**

手动将 key 的 normalized 值（后 20 位）从 `rejected` 移到 `approved`：

```bash
python3 -c "
import json

KEY = '<YOUR_FULL_API_KEY>'
normalized = KEY[-20:]

with open('/home/ps/.claude.json') as f:
    d = json.load(f)

responses = d.setdefault('customApiKeyResponses', {})

# 从 rejected 移除
rejected = responses.get('rejected', [])
if normalized in rejected:
    rejected.remove(normalized)
    responses['rejected'] = rejected

# 加入 approved
approved = responses.get('approved', [])
if normalized not in approved:
    approved.append(normalized)
    responses['approved'] = approved

with open('/home/ps/.claude.json', 'w') as f:
    json.dump(d, f, indent=2)

print('Done:', json.dumps(responses, indent=2))
"
```

**重要：配置文件路径**

| 文件 | 用途 |
|---|---|
| `~/.claude.json` | **Auth 配置**，存 OAuth token、customApiKeyResponses |
| `~/.claude/settings.json` | **权限配置**，存 allow/deny 规则、hooks |

`customApiKeyResponses.approved` 必须写入 `~/.claude.json`，写错到 `settings.json` 无效。

---

## 完整切换流程（直连模式）

### 修改 `.env.cc_keys`

```env
# 注释掉 DeepSeek 相关
#OPENAI_BASE_URL=...
#OPENAI_API_KEY=...
#ANTHROPIC_PROXY_MODEL=...
#ANTHROPIC_MODEL=deepseek-v4-pro

# 注释掉代理
#HTTP_PROXY=http://172.16.6.179:61080/
#HTTPS_PROXY=http://172.16.6.179:61080/
#NO_PROXY=...

# 启用直连
ANTHROPIC_API_KEY=<your_key>
ANTHROPIC_BASE_URL=<your_base_url>
ANTHROPIC_MODEL=<your_model>
ANTHROPIC_DEFAULT_HAIKU_MODEL=<your_model>
ANTHROPIC_DEFAULT_SONNET_MODEL=<your_model>
ANTHROPIC_DEFAULT_OPUS_MODEL=<your_model>
```

### 验证 API 直连

```bash
curl -x "" \
  -H "x-api-key: <YOUR_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"<MODEL>","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}' \
  <BASE_URL>/v1/messages
```

### 确保 key 在 approved 列表（首次使用时）

```bash
python3 -c "
import json
key = '<YOUR_FULL_API_KEY>'
normalized = key[-20:]
with open('/home/ps/.claude.json') as f:
    d = json.load(f)
responses = d.setdefault('customApiKeyResponses', {})
# 清 rejected
responses['rejected'] = [k for k in responses.get('rejected', []) if k != normalized]
# 加 approved
if normalized not in responses.get('approved', []):
    responses.setdefault('approved', []).append(normalized)
with open('/home/ps/.claude.json', 'w') as f:
    json.dump(d, f, indent=2)
print('approved:', responses['approved'])
"
```

### 启动（只需一个终端）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
./test-harness/start_harness.sh
```

---

## 切回 DeepSeek 模式

1. 反注释 `.env.cc_keys` 里的 DeepSeek 和代理行
2. 注释掉直连 block
3. 终端一启动代理：`./test-harness/start_proxy_deepseek.sh`
4. 终端二启动 harness：`./test-harness/start_harness.sh`

---

## 快速诊断命令

```bash
# 检查当前 env 里的 auth 变量
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
set -a && source test-harness/.env.cc_keys && set +a
echo "API_KEY=[${ANTHROPIC_API_KEY:-UNSET}]"
echo "AUTH_TOKEN=[${ANTHROPIC_AUTH_TOKEN:-UNSET}]"
echo "BASE_URL=[${ANTHROPIC_BASE_URL:-UNSET}]"

# 检查 key 的 approved/rejected 状态
python3 -c "
import json
key = '$(grep ANTHROPIC_API_KEY test-harness/.env.cc_keys | grep -v "^#" | cut -d= -f2)'
print('normalized:', key[-20:])
with open('/home/ps/.claude.json') as f:
    d = json.load(f)
r = d.get('customApiKeyResponses', {})
print('approved:', r.get('approved', []))
print('rejected:', r.get('rejected', []))
"
```
