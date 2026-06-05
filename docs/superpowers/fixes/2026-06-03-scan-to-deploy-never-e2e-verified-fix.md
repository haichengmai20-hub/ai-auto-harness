# ai-daily-scan MCP → auto-daily 全链路从未端到端验证

## 元信息

- **Fix ID**: `2026-06-03-scan-to-deploy-never-e2e-verified-fix`
- **创建日期**: 2026-06-03
- **级别**: P1
- **状态**: ✅ 已闭环
- **负责人 / session**: Claude session @ 2026-06-03（ControlFoley e2e retro）

---

## 人话版

**一句话**：工厂的"选品"环节从来没真正跑过，4 个项目全是人工挑的。

**打比方**：开了一家"自动选品→自动采购→自动出货"的无人超市，但开业至今每次进货都是老板亲自去市场挑的，"自动选品"模块从没转过。

**现在怎样**：4 个已跑通项目（SongGen / OmniVoice / Hunyuan3D / ControlFoley）全是用 `/auto-deploy` 或 `/auto-recover` 手动指定 URL 触发的。`/auto-daily`（scan → analyst → pick → intake → ... → cleanup）的完整链路从未执行过。如果 cron `daily.sh` 明天自动跑，没人知道会不会卡在 scan 或 pick 环节。

**要做什么**：写一个 L1 测试 prompt 专门验证 `/auto-daily` 的 scan → pick 分支，确认 MCP server 配置正确、analyst 返回格式可解析、pick 决策能产出 intake。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | N/A 仅平台讨论（4 个项目均未走 scan 链路） |
| **触发 run_id** | N/A |
| **触发时间** | 2026-06-03 |
| **触发阶段** | ops |
| **workspace 路径** | N/A |
| **runs 路径** | N/A |

---

## 现象

- 现象 1: 4/4 项目用 `/auto-deploy`（手动 URL）或 `/auto-recover` 触发，从未走 `/auto-daily` 的 scan → pick 链路
  - 证据: 所有 `runs/*/meta.json` 的 trigger 字段都是 `auto-deploy` 或 `auto-recover`
- 现象 2: `/auto-daily` skill 存在但从未被实际调用过
  - 证据: `grep -r "auto-daily" runs/*/harness.stdout.ndjson` 无结果
- 现象 3: MCP server 配置是否正确、analyst prompt 是否能被 auto-daily 解析，均未验证
  - 证据: 无 e2e 测试覆盖 scan → pick 分支

---

## 触发条件 / 复现步骤

1. 设置 cron `daily.sh` 定时执行
2. cron 触发 `/auto-daily`
3. auto-daily 调 `mcp__ai_daily_scan__get_trending_projects` 或 `scan_for_projects`
4. 如果 MCP server 未启动或返回格式不对 → 全链路中断
5. 如果 analyst prompt 格式不对 → pick 失败 → 不 intake

---

## 影响

- **影响范围**: 整个"自动化"承诺——如果 scan → pick 没验证过，"每天自动跑"就是空话
- **影响下游**: cron daily.sh 跑了但啥也没干 → 浪费 API 调用；或者 analyst 返回格式不对 → 项目被错误 pick 或漏 pick
- **严重程度**: P1 — 关联 Fix #16（环境无 daemon），如果 scan 链路本身没验证过，装了 daemon 也是白装

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 开发过程中一直用 `/auto-deploy` 做单项目验证（更快、更可控），`/auto-daily` 的 scan → pick 链路被视为"集成测试"而推迟。
  > 现在 4 个项目的后半段（intake → cleanup）都已验证，但前半段（scan → pick）成了盲区。
  > 这是典型的"单元测试通过但集成测试从未跑"的问题。

---

## 修复方案

### 设计层修改

- [ ] 写 L1 测试 prompt: `docs/superpowers/plans/2026-06-03-scan-to-deploy-e2e-l1-test-prompt.md`
  - 内容：启动 `/auto-daily`，只验证 scan → analyst → pick → intake 的前 3 步
  - 验收：能从 MCP 拿到 findings → analyst 能返回结构化评估 → pick 能产出 `workspace/<slug>/state.json`
- [ ] 确认 MCP server 配置在 `settings.json` 中正确
  - `mcpServers.ai-daily-scan` 的 command / args / env 指向正确的路径
- [ ] 写 MCP 健康检查 probe：`scripts/healthcheck-mcp.sh`
  - 调 `mcp__ai_daily_scan__*` 的 ping/health 工具（如果有的话）
  - 或简单验证：`curl` MCP server 的 HTTP 端口

### 实现层修改

- [ ] 可能需要修复 `/auto-daily` SKILL.md 中 analyst → pick 的 prompt 格式
- [ ] 可能需要修复 MCP server 的启动方式（是否需要在 launch_worker.sh 中自动启动？）

### 文档层修改

- [ ] 在 Master Plan "下一步候选" 中加入此 fix 的优先级

---

## 验证步骤

1. 运行 L1 测试 prompt
2. 期望：auto-daily 从 scan → pick → intake 至少跑通一个新项目
3. 检查 `workspace/<new-slug>/state.json` 存在且 phase=intake
4. 确认 MCP server 在 `settings.json` 中配置正确

---

## 修复结果

- **状态**: ✅ 已闭环(toonflow-app e2e 验证 scan→deploy 全链路通过)
- **验证证据**:
  - 2026-06-04 新增 `scripts/healthcheck-mcp.sh`
  - 新增 `docs/superpowers/plans/2026-06-03-scan-to-deploy-e2e-l1-test-prompt.md`
  - `auto-daily/SKILL.md` 已修正 `--bare` 文档漂移,明确保留 hooks/skills 的 worker 启动方式
  - **2026-06-05 e2e 实测**: toonflow-app 通过 `/auto-daily` skill 完成完整 scan→pick→intake→fetch→install→run→verify→runbook→cleanup→archived 全链路
    - `mcp__ai_daily_scan__scan_today` 成功返回 2 个候选(ideogram4 + toonflow-app)
    - `mcp__ai_daily_scan__record_outcome` 成功回填(slug=toonflow-app, status=passed)
    - 过滤逻辑正确: ideogram4 gated 无权限→排除; toonflow-app 0B 参数→选中
    - 轨迹文件: `runs/e2e-scan-deploy-20260605-104739/trajectory.json`(L1) + `runs/e2e-scan-full-20260605-105555/trajectory.json`(L2)
    - verify 3/3 smoke test 全过; runbook 297 行; cleanup 释放 1.68GB
- **commit hash**: N/A

---

## 证据指针

- 相关 SKILL: `.claude/skills/auto-daily/SKILL.md`
- 相关 SKILL: `.claude/skills/intake/SKILL.md`
- MCP 配置: `.claude/settings.json` → `mcpServers.ai-daily-scan`
- MCP 源码: `/root/ai-daily-scan/`（独立仓库）
- Cron: `cron/daily.sh`
- Launch: `cron/launch_worker.sh`
- healthcheck: `scripts/healthcheck-mcp.sh`

---

## 关联

- **关联 fix**: [2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md](2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md)（Fix #16，环境无 daemon，本 fix 是其前置条件——即使装了 daemon，scan 链路没验证也是白装）
- **关联 fix**: [2026-05-29-polling-handoff-mechanism-fix.md](2026-05-29-polling-handoff-mechanism-fix.md)（Fix #15，交接机制断裂，scan → pick → intake 也涉及跨阶段交接）
- **关联 spec**: `specs/2026-05-19-ai-auto-harness-design.md`（Phase 0: ai-daily-scan MCP 集成，设计存在但从未 e2e 验证）

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → 2026-06-05 加 ChangeLog
- [x] **Master Plan Fix 索引区已更新** → 2026-06-05 状态改为 ✅ 已闭环
- [ ] **是否提升到 memory/lessons** → 否（这是验证欠账，不是技术踩坑）
- [x] **L1 测试已跑通** → 2026-06-05 toonflow-app scan→pick→intake 全链路验证通过
- [ ] **是否需要写 pending_human** → 否

---

## ChangeLog

- **2026-06-05** — 状态从 ⬜ 未落地 → ✅ 已闭环(toonflow-app e2e scan→deploy 全链路验证通过)
  - 变更类型: 状态
  - 影响范围: 本文件修复结果段
  - 动机: toonflow-app 通过 `/auto-daily` 完成完整 scan→deploy 全链路,MCP scan_today + record_outcome 均成功
  - 证据: `runs/e2e-scan-full-20260605-105555/trajectory.json` + `workspace/toonflow-app/state.json`
