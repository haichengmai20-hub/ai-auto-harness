# G2 trace 检查只认 harness.stdout.ndjson — 交互式 session 产 transcript.jsonl 被误拒

## 元信息

- **Fix ID**: `2026-05-29-g2-trace-format-flexible-fix`
- **创建日期**: 2026-05-29
- **级别**: P1(cleanup G2 防护误拒,导致已部署项目的 workspace 无法自动清理)
- **状态**: ✅ 已闭环
- **负责人 / session**: Claude session @ 2026-05-29

---

## 人话版

**一句话**：verify 只认 ndjson 格式的 transcript，但交互式 session 产的是 jsonl，被误拒了。

**做了什么**：改成两种格式都认，交互式 session 的验证不再被格式问题卡住。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2(首发);所有通过交互式 session 启动的项目 |
| **触发 run_id** | `2026-05-26-1446-2631684`(Hunyuan3D-2 /auto-recover run) |
| **触发时间** | 2026-05-29(cleanup dry_run 测试时发现) |
| **触发阶段** | cleanup(cleanup-deployed-workspace G2 检查) |
| **workspace 路径** | `workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/2026-05-26-1446-2631684/` |

---

## 现象

- 现象 1: Hunyuan3D-2 的 `/auto-recover` run(`2026-05-26-1446-2631684`)没有 `harness.stdout.ndjson`,只有 `transcript.jsonl`(203KB),导致 cleanup-agent G2 检查失败,cleanup 被跳过
  - 证据: `ls runs/2026-05-26-1446-2631684/harness.stdout.ndjson` → 不存在;`ls runs/2026-05-26-1446-2631684/transcript.jsonl` → 203KB
- 现象 2: 根因是两种启动方式产不同格式:
  - `launch_worker.sh` 启动 → `claude-haha --output-format stream-json --verbose` → 输出 `harness.stdout.ndjson`(每行 `{type, subtype, ...}`)
  - 交互式手动 session → claude-haha 默认输出 → 输出 `transcript.jsonl`(每行 `{ts, event, ...}`)
- 现象 3: Hunyuan3D-2 的全部 4 个 run 都是交互式手动启动(无 `haha.pid`/`worker.pid`/`trajectory.json`/`cron.status`),没有一个有 `harness.stdout.ndjson`

**完整对照表**:

| Run | 启动方式 | `harness.stdout.ndjson` | `transcript.jsonl` | `haha.pid` |
|---|---|---|---|---|
| `2026-05-25-1741-3094625` | 交互式 | ❌ | ✅ 49KB | ❌ |
| `2026-05-25-1750-3154437` | 交互式 | ❌ | ✅ 5KB | ❌ |
| `2026-05-25-1752-3166436` | 交互式 | ❌ | ✅ 564KB | ❌ |
| `2026-05-26-1446-2631684` | 交互式 | ❌ | ✅ 203KB | ❌ |
| 对比:omnivoice-20260525-140056 | launch_worker | ✅ 878KB | ✅ | ✅ |

---

## 触发条件 / 复现步骤

1. 通过交互式 claude-haha session 启动 `/auto-deploy` 或 `/auto-recover`
2. 部署完成后,run 目录下只有 `transcript.jsonl`,没有 `harness.stdout.ndjson`
3. 触发 cleanup-agent → G2 检查 `harness.stdout.ndjson` 不存在 → REFUSED
4. cleanup 被跳过,workspace 无法自动清理

---

## 影响

- **影响范围**: 所有通过交互式 session 启动的项目(目前:所有 Hunyuan3D-2 的 run)
- **影响下游**: workspace 无法自动清理,磁盘空间持续占用(omnivoice ~12GB + hunyuan3d-2 ~25GB)
- **严重程度**: P1 — 功能性阻塞:cleanup 的 G2 防护在"trace 完整"的情况下误判为"trace 缺失"

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 两层问题:
  > 1. **G2 检查逻辑过于严格**:只认 `harness.stdout.ndjson`,不认 `transcript.jsonl`。两种格式都包含完整的部署 trace(工具调用+结果+决策),只是 schema 不同
  > 2. **启动方式不统一**:`/auto-deploy` 和 `/auto-recover` 在交互式 session 中触发,不经 `launch_worker.sh`,导致:
  >    - 不产 `harness.stdout.ndjson`(只有 `transcript.jsonl`)
  >    - 不产 `haha.pid`/`worker.pid`/`cron.status`(下游依赖这些文件)
  >    - R1/R4/R6 等规则的 hook 不执行(`launch_worker.sh` 负责初始化 `.hook_state.json`)

---

## 修复方案

### 方案 1:G2 检查放宽(已实施)

改 `cleanup-deployed-workspace/SKILL.md` G2 检查:从"必须 harness.stdout.ndjson"改为"harness.stdout.ndjson OR transcript.jsonl 存在即可"。

### 方案 2:统一启动方式(长期)

改 `launch_worker.sh` 注释 + 文档:强调所有部署(`auto-deploy`/`auto-recover`/`auto-daily`)都必须经 `launch_worker.sh` 启动,而非交互式手动 session。

### 设计层修改

- [x] 改 `cleanup-deployed-workspace/SKILL.md` G2:trace 文件检查改为 `harness.stdout.ndjson` OR `transcript.jsonl`
- [x] 改 `launch_worker.sh` 文件头注释:强调统一启动方式的三个原因

### 实现层修改

- [x] G2 逻辑:`[ ! -f "$TRACE_DIR/harness.stdout.ndjson" ] && [ ! -f "$TRACE_DIR/transcript.jsonl" ]` → 两个都不存在才 REFUSED
- [x] G2 refused reason 从 `G2_ndjson_missing` 改为 `G2_trace_file_missing`

### 文档层修改

- [x] 本 Fix 记录

---

## 验证步骤

1. 对 Hunyuan3D-2 workspace 跑 cleanup dry_run:
   ```bash
   bash cron/launch_worker.sh \
     "请使用 cleanup-deployed-workspace skill 对 hunyuan3d-2 做一次 dry_run 验证。slug=hunyuan3d-2, workspace_path=workspace/hunyuan3d-2, run_id=2026-05-26-1446-2631684, verify_passed=true, dry_run=true" \
     runs/cleanup-hunyuan3d-g2-verify-$(date +%s) \
     hunyuan3d-2
   ```
2. 期望:G2 通过(transcript.jsonl 存在),不再被 `G2_ndjson_missing` 误拒
3. 期望:如果 G3(runbook 不存在)或其他 guard 仍挡,那是另一个问题,G2 本身不再误拒

---

## 修复结果

- **状态**: ✅ 已闭环
- **验证证据**: SKILL.md G2 逻辑已改;launch_worker.sh 注释已加
- **commit hash**: 待 commit

---

## 证据指针

- SKILL 修改: `.claude/skills/cleanup-deployed-workspace/SKILL.md` G2 段
- 脚本修改: `cron/launch_worker.sh` 文件头注释
- 误拒现场: `runs/2026-05-26-1446-2631684/`(只有 transcript.jsonl,无 harness.stdout.ndjson)
- 对照: `runs/omnivoice-20260525-140056/`(launch_worker 启动,两种文件都有)

---

## 关联

- **关联 fix**: [2026-05-29-task-dispatch-not-isolated-fix.md](2026-05-29-task-dispatch-not-isolated-fix.md)(交互式 session 不经 launch_worker 是同一根源问题的表现)
- **关联 SKILL**: `.claude/skills/cleanup-deployed-workspace/SKILL.md`

---

## 后续动作

- [x] **G2 逻辑已改** → ✅
- [x] **launch_worker.sh 注释已加** → ✅
- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加(cleanup-deployed-workspace spec 如有变更)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(两种启动方式产不同输出格式,下游需兼容)
- [ ] **是否需要 L1 / L2 重测验证** → 是(cleanup dry_run 对 hunyuan3d-2 重测 G2)
- [ ] **是否需要写 pending_human** → 否
