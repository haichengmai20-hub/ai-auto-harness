# fetch-weights DEST 路径未显式注入:SubAgent 自拼路径导致下载目录混乱

## 元信息

- **Fix ID**: `2026-06-08-fetch-dest-path-not-injected-fix`
- **创建日期**: 2026-06-08
- **级别**: P1
- **状态**: 进行中
- **负责人 / session**: Claude session @ 2026-06-08

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：下载路径没传给工人，工人自己瞎猜路径

**打比方**：你让快递员送货，只给了小区名没给门牌号，快递员自己猜了 5 个不同地址放包裹

**现在怎样**：5 个 hf download 进程写了 3 种不同路径（.cache/models、.cache/models/、.cache/models/google/magenta-realtime-2/），SKILL.md 规定的 .cache/hf_models/$REPO 没人用

**要做什么**：主 agent 派发 Task() 时把 DEST 路径模板显式写进 prompt，不靠 SubAgent 自己去 SKILL.md 里找

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | magenta-realtime |
| **触发 run_id** | e2e-magenta-20260608-111127 |
| **触发时间** | 2026-06-08 11:11(+08:00) |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/magenta-realtime/` |
| **runs 路径** | `runs/e2e-magenta-20260608-111127/` |

---

## 现象

- 现象 1: 5 个 `hf download` 进程使用了 3 种不同的 `--local-dir` 路径
  - 证据: `pgrep -af "hf download"` 输出：
    - `--local-dir /root/ai-auto-harness/workspace/magenta-realtime/.cache/models` (×3)
    - `--local-dir /root/ai-auto-harness/workspace/magenta-realtime/.cache/models/` (×1, 多了尾部斜杠)
    - `--local-dir /root/ai-auto-harness/workspace/magenta-realtime/.cache/models/google/magenta-realtime-2` (×1)
  - SKILL.md 规定: `DEST="$WORKSPACE/.cache/hf_models/$REPO"` → 应为 `.cache/hf_models/google/magenta-realtime-2`
- 现象 2: 并发 5 个 hf download 进程写不同目标目录，违反 R7 并发防护
  - 证据: 同上 pgrep 输出，5 个进程同时运行

---

## 触发条件 / 复现步骤

1. 环境: 代理网络 + magenta-realtime 项目
2. 主 agent dispatch fetch-agent Task()，prompt 只传 `slug, hf_repos, workspace_path, run_id`
3. SubAgent 未读 SKILL.md 或忽略其中 DEST 定义，自行拼 `--local-dir` 路径
4. 多次重试/重启下载时，每次拼出不同路径
5. 期望失败: 权重散落在多个目录，后续 install-env/run-and-repair 找不到权重

---

## 影响

- **影响范围**: 数据完整性 / 可靠性
- **影响下游**:
  - install-env 阶段找不到权重（路径不匹配）
  - run-and-repair 的 entry_script 引用权重路径失败
  - verify 阶段无法判定模型是否可用
  - cleanup 阶段可能漏清散落目录
- **严重程度**: P1 — 权重散落导致后续阶段全部失败，但不会丢数据（权重还在，只是路径不对）

---

## 根因

- **是否已确认**: ✅
- **简述**: 主 agent 通过 `Task()` dispatch fetch-agent 时，prompt 里只传了 `slug, hf_repos, workspace_path, run_id` 这 4 个字段，**没有传 `DEST` 路径模板**。SKILL.md 第 2 步虽然定义了 `DEST="$WORKSPACE/.cache/hf_models/$REPO"`，但这个定义在 SKILL.md 正文里，SubAgent 是否读到取决于 CC 的 skill 加载机制。当 SubAgent 没有仔细读 SKILL.md 或 skill 未被自动加载时，就会自行拼路径，导致混乱。
  > 更深层问题：不仅 DEST，其他关键参数（如 HF_HUB_DISABLE_XET、HF_HUB_DOWNLOAD_CONCURRENCY、sentinel 路径模板）也依赖 SubAgent 自己去 SKILL.md 里找，而非 prompt 显式注入。

---

## 修复方案

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [x] 改 `auto-deploy/SKILL.md` 任务 4 的 fetch-agent Task() prompt: 显式传入 `dest_path_template`、`hf_download_env_vars`、`sentinel_dir`
- [x] 改 `auto-daily/SKILL.md` 任务 3 的 fetch-agent Task() prompt: 同上
- [x] 改 `fetch-weights/SKILL.md` 第 0 步: 加"从 prompt 参数取 DEST，若未传则 fallback 到默认模板"的校验逻辑

### 实现层修改(代码 / 脚本 / 配置)

- 无代码修改（纯 prompt/SKILL 修改）

### 文档层修改(retro / lessons / handoff)

- [ ] 不提升到 lessons — 这是单次事件，根因明确（prompt 注入不足），不需要跨项目通用经验

---

## 验证步骤(必须可复现)

1. 读 auto-deploy/SKILL.md 任务 4 fetch-agent dispatch 段，确认 prompt 含 `dest_path_template`
2. 读 auto-daily/SKILL.md 任务 3 fetch-agent dispatch 段，确认 prompt 含 `dest_path_template`
3. 读 fetch-weights/SKILL.md 第 0 步，确认有 DEST 校验逻辑
4. 重跑 magenta-realtime fetch-weights，确认 `pgrep -af "hf download"` 只有一个进程且 `--local-dir` 匹配 `.cache/hf_models/google/magenta-realtime-2`

---

## 修复结果

- **状态**: ⬜ 待验证
- **验证证据**: 待重跑 magenta-realtime fetch 阶段
- **commit hash**: `<pending>`
- **commit message**: `<pending>`

---

## 证据指针(必填)

- workspace: `workspace/magenta-realtime/`
- runs: `runs/e2e-magenta-20260608-111127/`
- 日志: `workspace/magenta-realtime/logs/fetch_weights.log`
- 相关 SKILL: `.claude/skills/fetch-weights/SKILL.md`
- 相关 SKILL: `.claude/skills/auto-deploy/SKILL.md`
- 相关 SKILL: `.claude/skills/auto-daily/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R7(并发防护)、R9(主 agent 只 dispatch)

---

## 关联

- **关联 fix**: 2026-06-08-proxy-hf-download-503-fix（同一次 magenta-realtime 部署暴露的另一个问题）
- **关联 spec/plan ChangeLog 条目**: auto-deploy/SKILL.md + auto-daily/SKILL.md + fetch-weights/SKILL.md ChangeLog
- **关联 lessons**: 否（单次事件，不提升）

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否（单次事件，根因明确）
- [ ] **是否需要 L1 / L2 重测验证** → 是（重跑 magenta-realtime fetch 阶段）
- [ ] **是否需要写 pending_human** → 否
