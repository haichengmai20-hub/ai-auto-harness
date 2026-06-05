# PostToolUse hook 形同虚设的真因:SessionStart 覆盖 run-id,纪律/transcript 写进孤儿目录

## 元信息

- **Fix ID**: `2026-06-02-hook-runid-clobber-fix`
- **创建日期**: 2026-06-02
- **级别**: P0(R1/R4/R6/R9 实时约束全部失效的根因)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-02

---

## 人话版

**一句话**：SessionStart hook 覆盖了 launch_worker 建的 run-id，导致所有 hook 计数和 transcript 写进了错误的目录——R1/R4/R6/R9 从上线起从未在正确目录生效。

**打比方**：像快递员把信投进了隔壁家的信箱，你一直以为没人寄信，其实全投错了。

**做了什么**：修了 SessionStart hook 的 run-id 解析优先级：$AI_HARNESS_RUN_ID > 有 meta.json 的 .current_run_id > 自造。launch_worker 实测 transcript 落正确目录。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | controlfoley |
| **触发 run_id** | `e2e-controlfoley-20260602-103052` |
| **触发时间** | 2026-06-02 10:30(+08:00) |
| **触发阶段** | ops / 全阶段(hook 跨阶段失效) |
| **workspace 路径** | `workspace/controlfoley/` |
| **runs 路径** | `runs/e2e-controlfoley-20260602-103052/` |

---

## 现象

- 现象 1: ControlFoley run 的 `.hook_state.json` 计数器全 0(`bash_count=0 task_called=0 poll_count=0 sleep_streak=0`),但实际有 43 次 Bash / 7 次 sleep。
  - 证据: `runs/e2e-controlfoley-20260602-103052/.hook_state.json`
- 现象 2: 该 run 目录**没有** `transcript.jsonl`(hook 第一步无条件写它)。
  - 证据: `ls runs/e2e-controlfoley-20260602-103052/` 无 transcript.jsonl
- 现象 3: **所有** `runs/*/.hook_state.json` 都全 0 —— 不是单次问题,而是系统性。
- 现象 4: retro 误判为"hook 从未触发 / hook python 有 bug",并据此(2026-05-29 session)写了一批改 hook python 逻辑的 fix(poll-count-accumulate-cross-phase 等)—— 这些 fix 改的代码在生产里其实**从没在正确目录生效**。

---

## 触发条件 / 复现步骤(已实测)

1. `launch_worker.sh` 设 `runs/.current_run_id` = 真 run-id,并 init `runs/<真 run-id>/.hook_state.json`(全 0 + own_slug)。
2. claude-haha 启动 → SessionStart hook `session-start.sh` 跑 → `RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"; echo "$RUN_ID" > runs/.current_run_id` —— **覆盖**了真 run-id。
3. 之后每次 PostToolUse hook 读 `.current_run_id` = SessionStart 自造的 id → 把 transcript + 计数写进 `runs/<session-自造-id>/`(孤儿目录)。
4. `runs/<真 run-id>/.hook_state.json` 永远是 launch_worker 的 0 初值,无人更新;真 run 目录无 transcript。
5. monitor / 主 agent / 审计读真 run 目录 → 看到全 0 → 误判 hook 没触发。

**实测证据链**(本 session smoke test):
- 仅 `--settings <sentinel>` 跑 → sentinel hook **触发**(证明 headless `-p` 下 hook 机制正常,`--setting-sources` 非必需)。
- 用真 `.claude/settings.json` 跑 + 预置 `.current_run_id=_test` → 真 run 目录**无** transcript;wrapper 探针打印 `RUNID_FILE=2026-06-02-1749-2860086`(已被覆盖!),且孤儿目录 `runs/2026-06-02-1749-2860086/` 里 `bash_count=2` + transcript 2 行 —— hook 一直在干活,只是写错地方。

---

## 影响

- **影响范围**: R1(workspace 隔离,own_slug 在孤儿目录恒为空 → 检测全失效)/ R4(sleep)/ R6(pip)/ R9(主 agent 越权)全部实时约束。
- **影响下游**: 所有依赖 `.hook_state.json` / `transcript.jsonl` 的 monitor / 审计 / cleanup G2;2026-05-29 一批 hook 逻辑 fix 的验证前提失真。
- **严重程度**: P0 —— 平台核心安全/纪律机制自上线起从未在正确目录生效("规则写了但没执行"的真因)。

---

## 根因

- **是否已确认**: ✅(实测复现 + 探针定位)
- **简述**:
  > `session-start.sh` 无条件生成新 run-id 并覆盖 `runs/.current_run_id`,而 `launch_worker.sh` 已在启动前把真 run-id 写进该文件。SessionStart 在 claude-haha 启动时晚于 launch_worker 执行,于是覆盖生效。PostToolUse hook 以 `.current_run_id` 解析落点,遂全部写进 SessionStart 自造的孤儿目录。**hook 一直正常触发**,只是 run-id 所有权冲突导致落点错位。

---

## 修复方案

### 实现层修改

- [x] `cron/launch_worker.sh`:`export AI_HARNESS_RUN_ID="$RUN_ID"`(并加入 claude-haha 调用的显式 env 前缀),作为权威 run-id 传给 hook 子进程。
- [x] `.claude/hooks/session-start.sh`:run-id 解析改为 —— `$AI_HARNESS_RUN_ID` 优先 → 否则若 `.current_run_id` 指向含 `meta.json` 的 launch_worker run 则复用 → 否则(交互式)才自造。**绝不覆盖** launch_worker 的 id。
- [x] `.claude/hooks/post-tool-use.sh`:run-id 解析 `${AI_HARNESS_RUN_ID:-$(cat .current_run_id)}`,env 优先(belt-and-suspenders)。
- [x] 新建 `scripts/validate-run-discipline.sh`:worker 退出后解析 ndjson 产 `discipline-report.json`,事后审计 R9/R4/R1,**不依赖 hook 落点正确**(兜底)。在 `launch_worker.sh` 跑完落 trajectory 后 wire 调用。

### 设计层修改

- [x] `.claude/CLAUDE.md` ChangeLog 补本 fix(hook 执行链 run-id 所有权)。

### 文档层

- [x] 修正 retro 误判:hook 一直触发,问题是 run-id 落点;2026-05-29 一批 hook 逻辑 fix 现在(落点修复后)才真正生效。

---

## 验证步骤(已实测通过)

1. 真 `launch_worker.sh "<echo prompt>" runs/_verify verifyslug` 跑完:
   - `runs/_verify/transcript.jsonl` **存在**(1 行)✅
   - `.hook_state.json` = `bash=1 task=0 own_slug=verifyslug`(计数增长 + own_slug 正确)✅
   - 无新孤儿 `runs/<时间戳-pid>/` 目录 ✅
2. `bash scripts/validate-run-discipline.sh e2e-controlfoley-20260602-103052 controlfoley`:
   - 正确标出 R9(43 Bash/0 Task)+ R4.2(sleep streak 2)+ R4.5(poll 18)✅
   - 产出 `discipline-report.json` ✅

---

## 修复结果

- **状态**: ✅ 成功(实测复现 + 修复后端到端验证通过)
- **commit hash**: <填 WS1 commit>
- **commit message**: `ai-auto: P0 fix — SessionStart 覆盖 run-id 致 hook 写孤儿目录 + 事后纪律审计器`

---

## 证据指针

- runs: `runs/e2e-controlfoley-20260602-103052/`(全 0 hook_state,无 transcript)
- hook: `.claude/hooks/{session-start,post-tool-use}.sh`
- 启动器: `cron/launch_worker.sh`
- 审计器: `scripts/validate-run-discipline.sh` + `runs/<id>/discipline-report.json`
- 相关 R 规则: `.claude/CLAUDE.md` R1/R4/R8/R9

---

## 关联

- **关联 fix**: [2026-05-29-task-dispatch-not-isolated-fix](2026-05-29-task-dispatch-not-isolated-fix.md)(其证据 `task_called=0` 实为本 bug 的假象,应据本 fix 重新评估)+ 2026-05-29 全部读 `.hook_state.json` 的 fix。
- **关联 retro**: ControlFoley e2e 2026-06-02 retro(问题 15/16 hook 计数器全 0 / sleep 未检测)。

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(CLAUDE.md)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ WS3
- [x] **是否提升到 memory/lessons** → 是(建议:`memory/lessons/hook-runid-ownership.md` —— "外部启动器与 SessionStart 抢 run-id 所有权"是易复发坑;WS3 视情补)
- [ ] **是否需要清理历史孤儿 run 目录** → 是(`runs/<时间戳-pid>/` 一批),但属housekeeping,**不**在本 fix 自动删(留用户决定,守 R-HO 谨慎删除)
