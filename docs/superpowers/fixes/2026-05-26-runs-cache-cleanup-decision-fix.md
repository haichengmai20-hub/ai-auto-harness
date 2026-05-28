# runs/<run-id>/.cache 残留不被 cleanup 覆盖 — 22GB 隐形累积 + 边界决策

## 元信息

- **Fix ID**: `2026-05-26-runs-cache-cleanup-decision-fix`
- **创建日期**: 2026-05-26
- **级别**: P1(磁盘累积风险,但单次跑不阻塞)
- **状态**: 已闭环
- **负责人 / session**: 用户决策(选 A) + Claude session @ 2026-05-26

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation(run2) + song-generation(原 run) |
| **触发 run_id** | `songgen-e2e-run2-20260521-132245`(13GB 残留)+ `songgen-e2e-20260521-124245`(9GB 残留) |
| **触发时间** | 2026-05-21 ~ 2026-05-25(累积发现) |
| **触发阶段** | cleanup(发现于 phase 5 L1 测试后用户实测磁盘) |
| **workspace 路径** | `workspace/song-generation-run2/` / `workspace/song-generation/` |
| **runs 路径** | `runs/songgen-e2e-run2-20260521-132245/` / `runs/songgen-e2e-20260521-124245/` |

---

## 现象

- 现象 1: phase 5 L1 测试后,cleanup-agent 报告 dry_run 释放 8.6GB,但实际项目占用 ~30GB
- 现象 2: 用户实测 `du -sh runs/*/`,发现两个 song-generation run 的 `.cache/` 目录分别占 13GB 和 9GB,**完全没被 cleanup 处理**
  - 证据: `du -sh runs/songgen-e2e-run2-20260521-132245/.cache/` → `13G`
  - 证据: `du -sh runs/songgen-e2e-20260521-124245/.cache/` → `9.0G`
- 现象 3: 这两块 cache 不是 retro 显式列出的,是用户实测后报的"隐藏第 16 条"

---

## 触发条件 / 复现步骤

1. 用 `cron/launch_worker.sh` 启动 SubAgent,launch_worker 在 `runs/$RUN_ID/.cache` 创建 isolated cache(`HF_HOME` / `PIP_CACHE_DIR` 隔离)
2. 部署过程下载权重(~15GB) + pip wheel(~5GB)到这个 isolated cache
3. 部署完成,phase=done
4. 跑 `cleanup-deployed-workspace` 清 workspace,**只清 `workspace/<slug>/{venv,.cache,repo}`**
5. `runs/<run-id>/.cache/` **完全没动** → 残留累积

---

## 影响

- **影响范围**: 磁盘 + 长期可靠性
- **影响下游**: 每跑一次 cron 累积 ~20GB,跑 5 次就 100GB,触发磁盘空间不足后续 fetch
- **严重程度**: P1 — 单次部署不阻塞,但跨 cron 累积会触发 R3 磁盘阈值(< 50GB safety)误判

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > `cleanup-deployed-workspace/SKILL.md` 设计时只考虑 `workspace/<slug>/` 下的清理,
  > 没意识到 `launch_worker.sh` 为隔离环境变量另起的 `runs/$RUN_ID/.cache/` 是同一个 run 的产物,**也该归 cleanup 管**。
  > 设计层缺失了一个清理目标。

---

## 修复方案

用户决策时给了 4 个选项 A/B/C/D:
- **A**: cleanup 同步清自己 run 的 `runs/<run-id>/.cache/`(简单,不跨 run)
- B: cleanup 同步清所有 done/archived run 的 `runs/*/.cache/`(激进,跨 run 误删风险)
- C: 独立 skill `cleanup-runs-cache` + cron 周清
- D: 文档化,人手 `find runs/ -mtime +7 -name .cache -exec rm`

**用户选 A**(2026-05-26):简单 + 范围明确 + 不跨 run。

### 设计层修改

- [x] 改 `.claude/skills/cleanup-deployed-workspace/SKILL.md` 加**第 2.5 步**:清 `runs/$RUN_ID/.cache/`,严格安全检查(RUN_ID 非空 + 不含 `..` 或 `/` + 路径精确前缀匹配)
- [x] 改 SKILL §返回 schema:加 `run_cache_freed_bytes` + `run_cache_removed` 细分字段(总 `freed_bytes` 包含)
- [x] 改 SKILL §反模式:加"❌ 绝不递归清 `runs/*/.cache/`(R1 隔离)"

### 实现层修改

- [x] `scripts/validate-cleanup.sh` V3 必填字段加 `run_cache_freed_bytes` + `run_cache_removed`

---

## 验证步骤

1. 跑 cleanup dry_run:
   ```bash
   bash scripts/validate-cleanup.sh workspace/song-generation-run2 dry_run
   ```
2. 期望:`run_cache_freed_bytes` 字段存在 + log 里出现 `[DRY] would rm -rf .../runs/.../.cache (X GB, run-isolated cache)`
3. Task 5-7 串联后真跑 cleanup,实测 `runs/<run-id>/.cache/` 被清,磁盘 free 增加

---

## 修复结果

- **状态**: ✅ 设计 + 实现已落地(尚未真跑验证 — 上次 session 因硬约束 R-HO-2 不许 rm 实际 22GB 残留,等 Task 5-7 串联后真跑)
- **commit hash**: `42bdc5c`("Phase 5 测试与回溯 — L1 retro + 防护测试 plan + validate 脚本")
- **本 fix 文件 commit**: 待补(本 session)

---

## 证据指针

- workspace: `workspace/song-generation/` / `workspace/song-generation-run2/`
- runs: `runs/songgen-e2e-run2-20260521-132245/.cache/`(13GB) + `runs/songgen-e2e-20260521-124245/.cache/`(9GB)
- 相关 SKILL: `.claude/skills/cleanup-deployed-workspace/SKILL.md` 第 2.5 步
- 相关 launch_worker: `cron/launch_worker.sh`(创建 isolated cache 的源头)
- 验证脚本: `scripts/validate-cleanup.sh`
- handoff 第一次提出: `docs/superpowers/handoffs/2026-05-25-session-handoff.md` §5 末尾"用户隐含问的第 16 条"

---

## 关联

- **关联 retro**: `docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md`(隐藏第 16 条)
- **关联 fix**: [2026-05-26-phase5-l1-retro-15-fixes.md](2026-05-26-phase5-l1-retro-15-fixes.md)(同期完成)
- **关联 spec/plan**: `.claude/skills/cleanup-deployed-workspace/SKILL.md` ChangeLog(待加)

---

## 后续动作

- [x] **Master Plan 已落地**:从"待决策"移到"已落地的设计决策"(本 session 上次已更新)
- [ ] **Task 5-7 串联跑后实测验证**:cleanup 真清 13G+9G 残留
- [x] **不提升到 lessons**(架构决策非通用技术)
