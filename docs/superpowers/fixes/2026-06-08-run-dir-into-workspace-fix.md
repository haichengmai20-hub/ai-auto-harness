# run 目录治理:run 级数据从全局 runs/ 移入 workspace/<slug>/runs/

## 元信息

- **Fix ID**: `2026-06-08-run-dir-into-workspace-fix`
- **创建日期**: 2026-06-08
- **级别**: P1
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-08

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**:每次跑的日志/快照原来全堆在一个公共抽屉里,现在按项目分到各自的抽屉。

**打比方**:原来所有同事的草稿都丢进一个公共文件筐(`runs/`),谁的是谁的全靠文件名猜;现在每个项目有自己的柜子(`workspace/<slug>/runs/`),一眼就知道哪份草稿属于哪个项目。

**现在怎样**:9 个 magenta 的 run 散在公共 `runs/` 里,命名风格不统一,monitor / 人工要按项目找得翻一遍;而且全局只有一个 `.current_run_id` 指针文件,多个项目并发时会互相覆盖。

**要做什么**:把 run 级数据移到对应项目的 `workspace/<slug>/runs/`,`.current_run_id` 也跟着进项目目录,各项目互不干扰。

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | magenta-realtime(暴露问题的现场) |
| **触发 run_id** | e2e-magenta-20260608-111127 / magenta-resume-* 等 9 个 |
| **触发时间** | 2026-06-08(monitor 陪跑会话) |
| **触发阶段** | ops / 多阶段(intake→fetch-weights) |
| **workspace 路径** | `workspace/magenta-realtime/` |
| **runs 路径** | 迁移前 `runs/e2e-magenta-*` / `runs/magenta-*`;迁移后 `workspace/magenta-realtime/runs/*` |

---

## 现象

- 现象 1: magenta-realtime 的 9 个 run 散落在全局 `runs/` 下,命名风格不统一(`e2e-magenta-*` / `magenta-resume-*` / `magenta-fetch-poll-*`),monitor/人工无法按项目快速定位。
  - 证据: `ls runs/ | grep -iE 'magenta'` → 多种前缀
- 现象 2: R1 workspace 隔离规则说"`$WORKSPACE` 是唯一活动范围",但 SubAgent 双写 `runs/<run-id>/<phase>.json` 时实际上离开了 `$WORKSPACE`,自相矛盾。
  - 证据: `.claude/CLAUDE.md` 落盘约定"双写原则" + R1 段
- 现象 3: 全局单文件 `runs/.current_run_id`,N>1 并发项目时互相踩;交互式 monitor 会话的 SessionStart hook 自造 run-id 后覆盖该文件。
  - 证据: `.claude/hooks/session-start.sh:22` `echo "$RUN_ID" > "runs/.current_run_id"`

---

## 触发条件 / 复现步骤

1. 环境前提: 用 `launch_worker.sh` 启动一个带 slug 的部署 worker(如 magenta-realtime),且在交互式会话里同时开 monitor。
2. worker 写 `runs/<run-id>/`(全局),`.current_run_id` 全局单文件。
3. 交互式 monitor 会话 SessionStart 走自造分支,`echo > runs/.current_run_id` 覆盖。
4. 期望异常: 按项目找 run 要全局翻找;并发/交互式会话有 `.current_run_id` 覆盖风险。

---

## 影响

- **影响范围**: 可观测性 / 可维护性 / 隔离正确性(R1)。
- **影响下游**: monitor(找不到本项目 run)、cleanup(run cache 散在全局)、所有 SubAgent 的双写约定、3 个 hook 的 run-dir 解析、validate-run-discipline。
- **严重程度**: P1 — 非数据丢失,但与 R1 隔离原则直接矛盾,且并发场景下 `.current_run_id` 覆盖会让纪律计数/transcript 落错目录。

---

## 根因

- **是否已确认**: ✅
- **简述**: run 级目录在 *launch 时* 由 launcher 创建并经全局 `runs/.current_run_id` + `$AI_HARNESS_RUN_ID` 传给 hook,而当时 hook 只拿到 `run_id`(不含 slug),无法把目录落到 `workspace/<slug>/runs/`。要把 run 级数据归到项目下,必须让 launcher 把**完整 run 目录路径**传给 hook,而不是让 hook 用 `runs/$RUN_ID` 自拼。

---

## 修复方案

### 设计层修改(spec / SKILL.md / CLAUDE.md)

- [x] 改 `.claude/CLAUDE.md` "落盘约定"段:run 级路径 `runs/<run-id>/` → `workspace/<slug>/runs/<run-id>/`;双写原则改;补"无 slug 的 cron 预挑阶段"例外说明。
- [x] 改 9 个 SKILL.md 的 run 级双写路径 `runs/$RUN_ID/` → `$RUN_DIR/`(在 task 0 / phase 开头解析 `RUN_DIR="${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}"`):auto-deploy / auto-daily / auto-recover / intake / install-env / fetch-weights / run-and-repair / verify / write-deploy-runbook / cleanup-deployed-workspace。

### 实现层修改(代码 / 脚本 / 配置)

- [x] `cron/launch_worker.sh`:`.current_run_id` 写到 `$(dirname "$LOG_DIR")/.current_run_id`(slug 已知时 = `workspace/<slug>/runs/.current_run_id`);**新增** `export AI_HARNESS_RUN_DIR="$LOG_DIR"`;僵尸清理同时扫 `workspace/*/runs/*/worker.pid` 和 legacy `runs/*/worker.pid`;usage 示例改为 `workspace/<slug>/runs/<run-id>`。
- [x] `cron/daily.sh`:**新增** `export AI_HARNESS_RUN_DIR="$LOG_DIR"`;僵尸清理同时扫两处;`LOG_DIR` 保持全局 `runs/cron-<ts>`(见下"已知偏差")。
- [x] `.claude/hooks/{session-start,post-tool-use,session-end}.sh`:run-dir 解析统一为 `RUN_DIR="${AI_HARNESS_RUN_DIR:-$HARNESS_ROOT/runs/${AI_HARNESS_RUN_ID:-$(cat runs/.current_run_id)}}"`;session-start 在 worker 管理(`AI_HARNESS_RUN_DIR` 已设)时**不写** `.current_run_id`(防交互式覆盖);session-end 的"清 7 天旧 runs"同时清 `workspace/*/runs/`。
- [x] `scripts/validate-run-discipline.sh`:run_id-arg 分支同时在 `runs/$ARG` 与 `workspace/*/runs/$ARG` 查找(path-arg 分支本来就不依赖位置)。
- [x] 新建 `scripts/migrate-runs-into-workspace.sh`:**liveness-guarded** 迁移 — 跳过任何 `worker.pid` 仍存活的 run,只迁移 slug 能映射到现有 workspace 的 run。

### 已知偏差(prompt 与现实不符,本 fix 的实现决定)

1. **`daily.sh`(auto-daily cron)在 launch 时没有 slug** — slug 由 auto-daily skill 动态 pick,且 daily.sh **不调** launch_worker(自带 inline 启动)。因此其 worker 级目录无法在创建时落到 `workspace/<slug>/`。决定:daily.sh 的 `LOG_DIR` 保持全局 `runs/cron-<ts>`,作为**唯一合法的全局预挑暂存目录**(N=1,无跨项目混杂)。slug 已知后 SubAgent 的双写仍走 `$AI_HARNESS_RUN_DIR`(= 该 cron 目录)。
2. **迁移时有 5 个 live worker**(含 magenta fetch 92%)。迁移脚本跳过 live run,只迁移 dead run;live run 待其结束后由同一脚本补迁。因此迁移当下"全局 runs/ 无项目 run"无法 100% 满足,残留的都是 live / 测试 fixture(codex-r9-*)/ scan-e2e / 交互式自造 id。

---

## 验证步骤(必须可复现)

1. `bash -n cron/launch_worker.sh cron/daily.sh .claude/hooks/*.sh scripts/validate-run-discipline.sh scripts/migrate-runs-into-workspace.sh` → 期望:全部语法 OK。
2. `bash scripts/migrate-runs-into-workspace.sh --dry-run` → 期望:列出将迁移的 dead run + 跳过的 live run,不实际移动。
3. `bash scripts/migrate-runs-into-workspace.sh` → 实际迁移 dead run。
4. `ls workspace/magenta-realtime/runs/` → 期望:能看到迁移后的 dead magenta run。
5. `grep -rn 'runs/\$RUN_ID' .claude/skills/` → 期望:0(全部改为 `$RUN_DIR`)。
6. live worker 用旧 launcher 启动(无 `AI_HARNESS_RUN_DIR`)→ hook fallback 到 `runs/$AI_HARNESS_RUN_ID`,继续写全局,**不被本次改动打断**(向后兼容)。

---

## 修复结果

- **状态**: ✅ 成功(结构 + 代码 + 文档闭环;dead run 已迁移,live run 待结束补迁)
- **验证证据**: 见下方 ChangeLog 条目 + commit;`bash -n` 全过;skills 中 `runs/$RUN_ID` 归零。
- **commit hash**: 见本次 `[fix] run-dir` 提交(git log)
- **commit message**: `[fix] run-dir: 将 run 级数据从全局 runs/ 移入 workspace/<slug>/runs/`

---

## 证据指针(必填)

- workspace: `workspace/magenta-realtime/`
- runs(迁移后): `workspace/magenta-realtime/runs/`
- 迁移脚本: `scripts/migrate-runs-into-workspace.sh`
- 相关 hook: `.claude/hooks/{session-start,post-tool-use,session-end}.sh`
- 相关 R 规则: `.claude/CLAUDE.md` R1 + 落盘约定段

---

## 关联

- **关联 fix**: [2026-06-02-hook-runid-clobber-fix](2026-06-02-hook-runid-clobber-fix.md)(本 fix 在其 `AI_HARNESS_RUN_ID` 基础上加 `AI_HARNESS_RUN_DIR`)、[2026-06-08-monitor-role-discipline-fix](2026-06-08-monitor-role-discipline-fix.md)(同一 magenta 会话暴露)
- **关联 spec/plan ChangeLog 条目**: `.claude/CLAUDE.md`(2026-06-08)、各 SKILL.md(2026-06-08)
- **关联 lessons**: 暂不提升(单次结构调整,非跨项目反复根因)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(单次结构调整)
- [ ] **是否需要 L1 / L2 重测验证** → 否(无 agent 行为变更,纯路径)
- [ ] **live run 补迁** → ⬜ 待 5 个 live worker 结束后重跑 `scripts/migrate-runs-into-workspace.sh`
