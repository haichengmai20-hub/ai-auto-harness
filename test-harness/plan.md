# CC Harness × Qwen API 兼容性测试计划

> 测试范围：Layer 1（工具调用）+ Layer 3（上下文管理）+ Layer 5（生态集成）
> 测试方式：通过 `claude-haha` harness 连接 `anthropic-qwen-proxy → vLLM → Qwen3.6-35B-A3B`
> 量化尝试与问题记录：`LOCAL_VLLM_QUANTIZATION_POSTMORTEM_20260424.md`

---

## 0. 前置环境确认

在开始任何测试之前，按顺序确认以下服务运行正常：

| 服务 | 端口 | 检查命令 | 预期 |
|------|------|----------|------|
| vLLM | 8000 | `curl http://127.0.0.1:8000/v1/models` | 返回 `Qwen3.6-35B-A3B` |
| Proxy | 8082 | `curl http://127.0.0.1:8082/health` | 返回 JSON |
| Harness | — | `CLAUDE_CODE_FORCE_RECOVERY_CLI=1 ./bin/claude-haha` | 进入 REPL，发一句消息能正常回复 |

环境变量（harness 终端）：

```bash
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

> **测试记录方式**：每个测试用例完成后，在 Excel 的"实测结果"列填写 `✅` / `❌` + 简短描述。

---

## 0.1 一键启动命令（3 份代理 + Harness）

下面是当前可直接复制的启动模板。

### A) Proxy 终端：Qwen API（云端）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
pkill -f anthropic-qwen-proxy || true

BUN=/home/ps/dcr_claude_home/.bun/bin/bun
[ -x "$BUN" ] || BUN=bun

$BUN install

export OPENAI_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
export OPENAI_API_KEY=替换为你的真实DashScopeKey
export ANTHROPIC_PROXY_MODEL=qwen3.6-max-preview
export ANTHROPIC_PROXY_PORT=8082
export ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=4096

$BUN run anthropic-qwen-proxy
```

### B) Proxy 终端：Qwen-3.6-35B 本地（vLLM）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
pkill -f anthropic-qwen-proxy || true

BUN=/home/ps/dcr_claude_home/.bun/bin/bun
[ -x "$BUN" ] || BUN=bun

$BUN install

export OPENAI_BASE_URL=http://127.0.0.1:8000/v1
export OPENAI_API_KEY=EMPTY
export ANTHROPIC_PROXY_MODEL=Qwen3.6-35B-A3B
export ANTHROPIC_PROXY_PORT=8082
export ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=4096

$BUN run anthropic-qwen-proxy
```

### C) Proxy 终端：DeepSeek-v4-pro API（开启 thinking 专项版）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1
pkill -f anthropic-qwen-proxy || true
pkill -f claude-haha || true

BUN=/home/ps/dcr_claude_home/.bun/bin/bun
[ -x "$BUN" ] || BUN=bun

$BUN install

export OPENAI_BASE_URL=https://api.deepseek.com/v1
export OPENAI_API_KEY=替换为你的真实DeepSeekKey
export ANTHROPIC_PROXY_MODEL=deepseek-v4-pro
export ANTHROPIC_PROXY_PORT=8082
export ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=8192
export ANTHROPIC_PROXY_DEBUG=1

$BUN run anthropic-qwen-proxy
```

> **说明**：
> - DEBUG=1 用于观察代理侧日志（便于排查 reasoning_content 回传问题）
> - MAX_OUTPUT_TOKENS 提到 8192（thinking 模式下需要更多输出预算）
> - 代理已支持 reasoning_content 双向透传（thinking 往返）

### D) Harness 终端（DeepSeek thinking 明确开启版）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1

export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
export ANTHROPIC_AUTH_TOKEN=dummy

# 按上游代理模型保持一致（DeepSeek v4 pro）
export ANTHROPIC_MODEL=deepseek-v4-pro
export ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_MODEL
export ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_MODEL
export ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_MODEL

# 关键：明确开启 thinking（清除历史禁令）
unset CLAUDE_CODE_DISABLE_THINKING
unset DISABLE_INTERLEAVED_THINKING

export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

./bin/claude-haha
```

> **启动后第一件事**：输入 `/clear` 清空历史消息（避免旧轮次的 reasoning_content 冲突），然后再提新问题

### D') Harness 通用终端模板（可复用套用）

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1

export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
export ANTHROPIC_AUTH_TOKEN=dummy

# ===== 1. 选择模型 =====
# 选项 A：Qwen API 云端
# export ANTHROPIC_MODEL=qwen3.6-max-preview

# 选项 B：Qwen-3.6-35B 本地（vLLM）
# export ANTHROPIC_MODEL=Qwen3.6-35B-A3B

# 选项 C：DeepSeek v4 pro（推荐用于 thinking 测试）
export ANTHROPIC_MODEL=deepseek-v4-pro

# ===== 2. 配置模型别名 =====
export ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_MODEL
export ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_MODEL
export ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_MODEL

# ===== 3. Thinking 开关 =====

# 情景 A：关闭 thinking（基础功能测试）
# export CLAUDE_CODE_DISABLE_THINKING=1

# 情景 B：开启 thinking（推理模式测试）- 取消注释下面两行
unset CLAUDE_CODE_DISABLE_THINKING
unset DISABLE_INTERLEAVED_THINKING

# ===== 4. 通用配置 =====
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

./bin/claude-haha
```

> **用法**：改第 8~15 行选模型，第 20~26 行选 thinking 模式，然后直接复制整段执行

### E) 健康检查

```bash
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8082/v1/models
```

---

## Phase 1: Layer 1 — 工具调用（单点基础能力）

> 目标：验证 Qwen 能否正确使用 CC harness 提供的每个内置工具。
> 测试策略：每个工具单独发一条消息测试，避免工具间互相干扰。

### 1.1 Read — 文件读取

**指令**：
```
读 README.md 的前 10 行，告诉我内容
```

**预期**：正确读取并输出 README.md 的内容。

**关注点**：Qwen 是否能理解 `Read` 工具的参数（file_path, limit），是否正确调用工具。

### 1.2 Write — 新建文件

**指令**：
```
在当前目录创建一个 test_qwen.py，内容是 print("hello from qwen test")
```

**预期**：文件被创建，内容正确。

**验证**：`cat test_qwen.py` 确认文件存在且内容匹配。

### 1.3 Edit — 精确修改

**指令**：
```
把 test_qwen.py 里的 hello 改成 hi
```

**预期**：字符串被精确替换，其他内容不变。

**验证**：`cat test_qwen.py` 确认改动正确。

### 1.4 Glob — 路径搜索

**指令**：
```
找当前目录下所有 .py 文件
```

**预期**：返回匹配的文件路径列表，包含刚创建的 `test_qwen.py`。

### 1.5 Grep — 内容搜索

**指令**：
```
搜索当前目录所有 .ts 文件中包含 import 的行
```

**预期**：返回匹配的行及所在文件路径。

### 1.6 Bash — 执行命令

**指令**：
```
运行 ls -la 给我看当前目录
```

**预期**：返回命令输出，内容与实际目录一致。

### 1.7 WebSearch — 联网搜索

**指令**：
```
搜索 FastAPI 最新版本号
```

**预期**：返回搜索结果摘要。

**注意**：WebSearch 依赖外部搜索 API，如果 proxy 层不支持可能失败。记录是否调用了 WebSearch 工具。

### 1.8 WebFetch — 网页抓取

**指令**：
```
抓取 https://httpbin.org/get 并告诉我返回了什么
```

**预期**：返回网页内容总结。

### 1.9 NotebookEdit — Jupyter

**前置**：先手动创建一个简单的 notebook：
```bash
python3 -c "
import json
nb = {'nbformat':4,'nbformat_minor':5,'cells':[{'cell_type':'code','execution_count':None,'metadata':{},'outputs':[],'source':['print(1)']}],'metadata':{}}
with open('test_qwen.ipynb','w') as f: json.dump(nb,f)
"
```

**指令**：
```
修改 test_qwen.ipynb 的第一个 cell，把 print(1) 改成 print("qwen test")
```

**预期**：cell 被正确修改。

### 1.10 AskUserQuestion — 主动提问

**指令**：
```
帮我写一个函数
```
（故意模糊，不提供参数、语言、功能）

**预期**：CC 主动调用 AskUserQuestion 工具询问澄清需求（语言、功能等）。

**关注点**：Qwen 是否知道在信息不足时主动提问，还是直接瞎猜。

### Phase 1 清理

```bash
rm -f test_qwen.py test_qwen.ipynb
```

---

## Phase 2: Layer 3 — 上下文管理（状态与记忆）

> 目标：验证会话内/跨会话的记忆机制、压缩、恢复等功能。
> 注意：这部分测试需要在同一个 session 内连续进行（不退出 REPL）。

### 3.1 多轮上下文记忆

**第一轮**：
```
记住这个：变量 x=42，颜色是蓝色
```

**第二轮**（紧接着）：
```
x 是多少？颜色是什么？
```

**预期**：正确回答 x=42，颜色是蓝色。

### 3.2 /init 生成 CLAUDE.md

> 注意：当前项目已有 CLAUDE.md，这个测试会追加/覆盖。先备份。

**前置**：
```bash
cp CLAUDE.md CLAUDE.md.bak
```

**指令**：
```
/init
```

**预期**：生成/更新 CLAUDE.md，内容反映当前项目的实际情况。

**恢复**：
```bash
mv CLAUDE.md.bak CLAUDE.md
```

### 3.3 MEMORY.md 跨会话

**步骤**：

1. 在当前 session 中：
```
记住我的偏好：我喜欢用 pytest 做测试，不喜欢用 mock
```

2. 确认记忆已写入（另开终端检查）：
```bash
cat ~/.claude/projects/*/memory/MEMORY.md
ls ~/.claude/projects/*/memory/
```

3. 退出 REPL（`/exit`），重新启动 `./bin/claude-haha`

4. 在新 session 中问：
```
我之前的测试偏好是什么？
```

**预期**：新 session 能引用旧记忆。

### 3.4 /compact 压缩

**前置**：先进行 5~6 轮对话（随便聊什么都行，积累足够的消息历史）。

**指令**：
```
/compact
```

**预期**：生成摘要并替换旧消息，后续对话仍能引用之前的内容。

### 3.5 /resume 恢复会话

**步骤**：

1. 在当前 session 说一句话：`"暗号是 banana"`
2. 退出 REPL
3. 新终端启动 `./bin/claude-haha`
4. 输入 `/resume`

**预期**：恢复到上次会话状态，能知道"暗号是 banana"。

### 3.6 /rewind 回滚

**步骤**：

1. 发一条消息让 CC 创建文件：`创建 rewind_test.txt`
2. 输入 `/rewind`

**预期**：对话回退到上一轮，文件创建操作被撤销。

### 3.7 /export 导出

**指令**：
```
/export
```

**预期**：对话被导出到文件，检查导出文件内容。

### 3.8 /summary 摘要

**指令**：
```
/summary
```

**预期**：生成当前会话摘要。

### 3.9 /clear 清空

**步骤**：

1. 先进行几轮对话积累历史
2. 输入 `/clear`
3. 问一个之前对话中提到过的事情

**预期**：对话历史被清空，无法引用之前的内容。

---

## Phase 3: Layer 5 — 生态集成（外部系统）

> 目标：验证 Git 集成、Skill、Plugin 等外部系统对接能力。
> 注意：部分测试涉及 git 操作，在 `import-main` 分支上进行，不会影响 `main`。

### 5.1 Git /commit 自动提交

**前置**：
```bash
echo "# test commit" > commit_test.md
git add commit_test.md
```

**指令**：
```
/commit
```

**预期**：自动生成 commit message 并提交。

**验证**：`git log --oneline -1` 确认提交成功。

### 5.2 Git /diff 查看改动

**前置**：
```bash
echo "change" >> commit_test.md
```

**指令**：
```
/diff
```

**预期**：显示当前未提交的改动。

### 5.3 Git /commit-push-pr

**注意**：这个测试需要真实的 GitHub 远程仓库权限。如果没有远程仓库配置，跳过此测试或标记为 N/A。

**指令**：
```
（先 commit 后 push 再创建 PR）
```

**预期**：提交并创建 PR。

### 5.4 /review 代码审查

**指令**：
```
/review
```

**预期**：输出代码审查意见。

### 5.5 /security-review 安全审查

**指令**：
```
/security-review
```

**预期**：输出安全问题清单。

### 5.6 MCP 外接工具

**前置**：需要配置一个 MCP server。如果没有现成的，可以跳过或用一个简单的 MCP server 测试。

**指令**：
```
（查看可用的 MCP 工具并调用）
```

**预期**：能发现并调用 MCP 工具。

**备注**：需前置配置，标记为条件测试。

### 5.7 Skill 内置技能

**指令**：
```
/simplify
```

**预期**：simplify 技能被正确触发执行。

### 5.8 Plugin 插件管理

**指令**：
```
/plugin
```

**预期**：列出或安装插件。

### 5.9 /skills 技能管理

**指令**：
```
/skills
```

**预期**：列出所有可用 skill。

### 5.10 /agents Agent 管理

**指令**：
```
/agents
```

**预期**：列出自定义 agent。

### Phase 3 清理

```bash
git reset HEAD~1 --soft  # 撤销 5.1 的测试提交（如果需要）
rm -f commit_test.md
```

---

## 测试执行建议

### 推荐顺序

```
Phase 1 (Layer 1) → Phase 2 (Layer 3) → Phase 3 (Layer 5)
```

原因：
- Layer 1 是基础，确认工具调用正常后再测更复杂的功能
- Layer 3 需要连续 session，适合在工具调用确认无误后进行
- Layer 5 涉及外部系统，复杂度最高，放最后

### 每个 Phase 的建议

| Phase | Session 策略 | 预计时间 |
|-------|-------------|---------|
| Phase 1 | 每个用例可单独 session，也可以一个 session 连续测 | 30~45 min |
| Phase 2 | **必须**在同一个 session 内连续进行（3.3 除外需要重启） | 30~40 min |
| Phase 3 | 可分多个 session | 20~30 min |

### 常见问题预判

| 问题 | 可能原因 | 排查 |
|------|---------|------|
| 工具调用失败 | Qwen 的 tool call 格式不兼容 | 检查 vLLM 的 `--tool-call-parser qwen3_xml` 是否正确 |
| 多轮对话丢失上下文 | proxy 层截断了 messages | 检查 proxy 的 max context length |
| /command 不响应 | Qwen 不理解 slash command 的语义 | 这是预期行为差异，记录即可 |
| 输出被截断 | `ANTHROPIC_PROXY_MAX_OUTPUT_TOKENS=4096` 不够 | 可适当调大，但注意显存 |

---

## 测试结果汇总表

测试完成后，在 Excel 中填写"实测结果"列。同时在这里记录关键发现：

### 关键发现（测试过程中记录）

| 编号 | 状态 | 备注 |
|------|------|------|
| — | — | — |

### Qwen 与 Claude 的行为差异（观察记录）

| 测试项 | Claude 预期行为 | Qwen 实际行为 | 差异说明 |
|--------|----------------|--------------|---------|
| — | — | — | — |
