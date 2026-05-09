# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在本仓库中工作时提供指引。

## 运行项目

```bash
# 安装依赖
bun install

# 交互式 TUI 模式
./bin/claude-haha

# 无头模式（单次查询）
./bin/claude-haha -p "your prompt"

# 降级 Recovery CLI（TUI 出问题时使用）
CLAUDE_CODE_FORCE_RECOVERY_CLI=1 ./bin/claude-haha

# Windows（PowerShell）
bun --env-file=.env ./src/entrypoints/cli.tsx
```

需要在 `.env` 中配置 `ANTHROPIC_API_KEY` 或 `ANTHROPIC_AUTH_TOKEN`；使用非 Anthropic 端点时还需配置 `ANTHROPIC_BASE_URL`。从 `.env.example` 复制开始。

无需构建步骤——Bun 直接运行 TypeScript/TSX。本仓库无测试套件。代码检查使用 Biome（代码中可见 `// biome-ignore` 注释）。

## 架构

基于 Claude Code 泄露源码修复的本地可运行版本，修复了启动链路中的阻塞问题。核心架构为 5 层系统：

**启动层** → `cli.tsx` 快速路由分发 → `main.tsx`（Commander.js CLI）→ `init.ts`（memoized 一次性初始化）→ `setup.ts` → REPL 启动

**Agent 循环** → `QueryEngine.ts` 封装 `query.ts`（核心 `async function*` while(true) 循环）。每次迭代：调用 LLM → 流式接收响应 → 检测 `tool_use` → 执行工具 → 追加结果 → 下一次迭代。退出条件：`needsFollowUp === false`、abort、maxTurns 或预算耗尽。

**工具系统** → `Tool.ts` 定义接口（给 LLM 看的 name/description/inputSchema + 运行时的 call/isReadOnly/isDestructive）。`tools.ts` 聚合约 44 个工具，受 feature flag 门控。`commands.ts` 注册约 80 个斜杠命令（用户触发、懒加载）。Hook（`PostToolUse`、`SessionStart`、`SessionEnd`）在系统事件处注入自定义逻辑。

**上下文工程** → `context.ts` 从 3 个来源组装 system prompt（静态 system prompt + git status + CLAUDE.md）。`memdir/` 管理自动记忆（MEMORY.md 索引 + 各主题文件）。`services/compact/` 处理自动上下文压缩，token 用量达约 87-93% 阈值时触发。`services/SessionMemory/` 管理 session 内临时笔记。

**UI 层** → React/Ink 终端渲染（`ink/` 自研引擎、`components/`、`screens/REPL.tsx`）。

## 关键文件

| 文件 | 用途 |
|------|------|
| `src/entrypoints/cli.tsx` | 启动入口，快速路由分发（--version、--daemon 等） |
| `src/main.tsx` | Commander.js CLI 定义，REPL/无头模式启动（约 4700 行） |
| `src/query.ts` | 核心 Agent 循环——驱动所有工具执行的 while(true) |
| `src/QueryEngine.ts` | query() 的 SDK 封装，管理 session 状态 |
| `src/Tool.ts` | 工具类型系统、权限、ToolUseContext |
| `src/tools.ts` | 工具注册表——聚合所有工具，feature flag 过滤 |
| `src/commands.ts` | 斜杠命令注册表——懒加载、用户触发 |
| `src/context.ts` | System prompt 组装（memoized，静态/动态边界） |
| `src/bootstrap/state.ts` | 全局可变状态（session ID、成本计数器、GrowthBook 引用） |
| `preload.ts` | Bun preload——设置 MACRO 全局变量（VERSION、BUILD_TIME 等） |
| `bunfig.toml` | Bun 配置——preload 指令 |

## 关键模式

- **Feature Flag**：`feature()` 来自 `bun:bundle`，构建时死代码消除，同一份源码产出不同 bundle（内部版/公开版）
- **MACRO 注入**：`preload.ts` 将编译时常量（版本号、构建时间戳）替换到全局作用域
- **懒加载**：80+ 斜杠命令仅在调用时加载执行代码；启动时只加载元数据
- **Async Generator 模式**：`query()` 是 `async function*`，yield `StreamEvent | Message`——实现流式工具执行（响应未完全到达即可启动工具）
- **工具权限矩阵**：`isReadOnly × isDestructive` 决定权限策略；`CanUseToolFn` 每次工具调用前检查
- **上下文压缩**：token 用量约 87-93% 时自动触发；fork 子 Agent（`maxTurns: 1`）生成结构化摘要替换旧消息
- **记忆隔离**：子 Agent（AgentTool）拥有独立上下文；`agentMemory.ts` 处理父子 Agent 间的记忆隔离

## 环境变量

详见 `.env.example`。关键变量：
- `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` — 认证（二选一）
- `ANTHROPIC_BASE_URL` — 非 Anthropic 提供商的自定义 API 端点
- `ANTHROPIC_MODEL`、`ANTHROPIC_DEFAULT_SONNET_MODEL` 等 — 模型映射
- `DISABLE_TELEMETRY=1`、`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — 禁用遥测