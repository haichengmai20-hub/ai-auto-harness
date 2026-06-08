# 代理环境 HuggingFace 下载 503:绕过代理 + 降并发

## 元信息

- **Fix ID**: `2026-06-08-proxy-hf-download-503-fix`
- **创建日期**: 2026-06-08
- **级别**: P1
- **状态**: 进行中
- **负责人 / session**: Claude session @ 2026-06-08

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：下载 AI 模型文件时被公司代理拦住了，报 503 连接太多

**打比方**：就像快递员送货到公司，但公司大门口的保安亭只能同时放 10 个人进出，你派了 4 个快递员同时挤，结果保安直接关门——谁也别想进

**现在怎样**：`hf download` 走 HTTP 代理（172.16.6.179:61080），代理连接池有限，Xet 多连接模式 + LLM 反复重试起多个进程，打爆代理 → 503 Too many open connections，下载卡死在 34MB/15.5GB

**要做什么**：让下载直连 HuggingFace 绕过代理，同时限制并发连接数，别再挤爆保安亭

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | magenta-realtime |
| **触发 run_id** | e2e-magenta-20260608-100558 |
| **触发时间** | 2026-06-08 10:05(+08:00) |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/magenta-realtime/` |
| **runs 路径** | `runs/e2e-magenta-20260608-100558/` |

---

## 现象

- 现象 1: `hf download google/magenta-realtime-2` 启动后报 `httpx.ProxyError: 503 Too many open connections`
  - 证据: `workspace/magenta-realtime/logs/fetch_weights.log` 行 1-103
- 现象 2: 下载卡死在 34MB/15.5GB，5 分钟无增长
  - 证据: `du -sm workspace/magenta-realtime/.cache/models/` = 34
- 现象 3: LLM 重试时起 4 个并发 `hf download` 进程写同一 `--local-dir`，加剧锁竞争（R7 并发防护失效 — SubAgent 没遵守 pgrep 检查）
  - 证据: `fetch.json.diagnosis` = "4 concurrent hf download processes were fighting for same lock files"
- 现象 4: 代理环境 `HTTPS_PROXY=http://172.16.6.179:61080/` 全局生效，`no_proxy` 不含 `huggingface.co`

---

## 触发条件 / 复现步骤

1. 环境有 HTTP 代理：`HTTPS_PROXY=http://172.16.6.179:61080/`，`no_proxy` 不含 `huggingface.co`
2. `launch_worker.sh` 启动 worker，代理 env 被 claude-haha 子进程继承
3. SubAgent 执行 `hf download` → 走代理 → Xet 多连接打爆代理连接池 → 503
4. LLM 见下载失败，反复重试起新进程 → 并发 + 代理 → 更严重

---

## 影响

- **影响范围**: 可靠性 + 成本。代理环境下**所有带权重的项目都无法下载**，harness 核心功能（self-host 部署）被完全阻塞
- **影响下游**: fetch-weights SubAgent（直接）、后续 install/run/verify 全部无法执行（串行依赖）
- **严重程度**: P1 — 不修复则所有带权重的部署都失败，harness 只能跑无权重的 API-skeleton 项目

---

## 根因

- **是否已确认**: ✅
- **简述**: 两个问题叠加：
  1. **代理 503**: 公司 HTTP 代理连接池有限（约 10-20 并发），`hf download` 默认用 Xet 后端起多个并发连接（`HF_XET_HIGH_PERFORMANCE=1`），打爆代理 → 503。`no_proxy` 列表不含 `huggingface.co`，所有 HF 流量都走代理。
  2. **LLM 并发重试**: SubAgent 不遵守 SKILL.md 第 2 步的 `pgrep -f` 并发防护，4 次重试起 4 个进程写同一 `--local-dir`，加剧锁竞争和代理压力。

  根因链：代理连接池有限 + Xet 多连接 + no_proxy 未覆盖 HF → 503 → LLM 重试 → 并发 → 更严重 503 → 死循环

---

## 修复方案

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [ ] 改 `fetch-weights/SKILL.md` 第 0 步：加代理绕过逻辑（`no_proxy` 加 `huggingface.co` / `unset HTTPS_PROXY` / `--num-workers 1` 三选一）
- [ ] 改 `fetch-weights/SKILL.md` 第 2 步：`setsid nohup bash -c` 里加 `unset HTTPS_PROXY HTTP_PROXY` 确保下载子进程不走代理
- [ ] 改 `fetch-weights/SKILL.md` 硬规则：加"代理环境下必须绕过代理下载"
- [ ] 改 `.claude/CLAUDE.md` R7：补充代理绕过要求
- [ ] 改 `cron/launch_worker.sh`：加 `HF_HUB_OFFLINE=0` + `no_proxy` 补 `huggingface.co`
- [ ] 改 `cron/daily.sh`：同上

### 实现层修改(代码 / 脚本 / 配置)

- [ ] 修 `cron/launch_worker.sh`：在缓存隔离段之后加代理绕过段
- [ ] 修 `cron/daily.sh`：同上
- [ ] 新建 `memory/lessons/proxy-hf-download.md`：代理环境下载经验

### 文档层修改(retro / lessons / handoff)

- [ ] 提升到 `memory/lessons/proxy-hf-download.md`：代理 503 三种解法 + no_proxy 配置

---

## 验证步骤(必须可复现)

1. `bash cron/launch_worker.sh "/auto-deploy https://github.com/magenta/magenta-realtime (slug=magenta-realtime)" "runs/test-proxy-fix-$(date +%s)" magenta-realtime`
2. 期望：fetch-weights 阶段 `hf download` 直连 HuggingFace（不走代理），下载速度 ≥ 10MB/s
3. `grep -i "proxy\|503\|unset" workspace/magenta-realtime/logs/fetch_weights.log`
4. 期望：无 503 错误，日志可见 unset proxy 或 no_proxy 生效

---

## 修复结果

- **状态**: ⬜ 待验证
- **验证证据**: (待填)
- **commit hash**: (待填)
- **commit message**: (待填)

---

## 证据指针(必填)

- workspace: `workspace/magenta-realtime/`
- runs: `runs/e2e-magenta-20260608-100558/`
- 日志: `workspace/magenta-realtime/logs/fetch_weights.log`
- 相关 SKILL: `.claude/skills/fetch-weights/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R7

---

## 关联

- **关联 fix**: 无
- **关联 lessons**: 将提升到 `memory/lessons/proxy-hf-download.md`
- **关联 spec/plan ChangeLog 条目**: `.claude/CLAUDE.md` R7 + `fetch-weights/SKILL.md` ChangeLog

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是（代理问题是跨项目通用问题）
- [ ] **是否需要 L1 / L2 重测验证** → 是（用 magenta-realtime 重跑 fetch 阶段）
- [ ] **是否需要写 pending_human** → 否
