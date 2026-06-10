# 状态快照失真 — paused 快照由即将退出的 agent 拍,立即过期

## 元信息

- **Fix ID**: `2026-05-29-state-snapshot-stale-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-26/27 retro)
- **级别**: P1(状态账本与现实脱节,下游误判)
- **状态**: ✅ 已闭环(与 polling-handoff 同方案:R10 sentinel 自报终态)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：state.json 记的是"3 分钟前的进度"而不是"现在的进度"，接手的人看的是过期信息。

**打比方**：像看股票行情用的是延迟 3 分钟的报价，你以为还在跌其实已经涨回来了。

**现在怎样**：AI 退出时才写 state.json，但后台下载还在跑。等下载完了 state.json 还写着"下载中 4/37"，实际已经是 37/37。

**要做什么**：改成后台进程自己定期更新 state.json，或者看门狗直接检查文件而不是读 state。最简单的：下载完时写一个 `.DONE` 哨兵文件。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2(首发);song-generation(state.json status:null)、song-generation-run2(slug:null) |
| **触发 run_id** | hunyuan3d-2: `2026-05-25-1752-*`;songgen: 早期 run |
| **触发时间** | 2026-05-25 18:59(hunyuan fetch 快照) |
| **触发阶段** | fetch-weights(agent 退出前写快照) |
| **workspace 路径** | `workspace/hunyuan3d-2/`、`workspace/song-generation/`、`workspace/song-generation-run2/` |
| **runs 路径** | `runs/2026-05-25-1752-*/` |

---

## 现象

- 现象 1: Hunyuan3D-2 fetch-weights 阶段,agent 撞 poll 预算退出前写 `paused_in_progress` 快照,记"4/37 文件、0.003GB"——只是下载启动 3 分钟时的早读。实际后台下载于 ~20:07 完毕(19GB,37/37),但 state.json 冻结在这个失真快照
  - 证据: `jq .fetch_state workspace/hunyuan3d-2/state.json` → 记 4/37 0.003GB;`du -sh workspace/hunyuan3d-2/repo/weights/` → 19G
- 现象 2: `workspace/song-generation/state.json` 有 `status:null`
- 现象 3: `workspace/song-generation-run2/state.json` 有 `slug:null`

---

## 触发条件 / 复现步骤

1. 长任务(fetch-weights / install-env)用 `setsid nohup ... &` 后台启动
2. LLM 轮询撞 R4 预算 → 写 `paused_in_progress` 快照(含后台 PID)+ 退出
3. 快照由**即将离开的 agent**在**某个时间点**拍摄——只反映拍摄瞬间,不代表最终状态
4. 后台进程继续跑,完成后快照已过期,没有人更新

---

## 影响

- **影响范围**: 数据完整性 + 可靠性 + 可观测性
- **影响下游**: `/auto-recover` 读 state.json 重建现场时拿到过期数据(以为 fetch 4/37,实际 37/37);auto-status 显示状态错乱;report 拼数据出错
- **严重程度**: P1 — 不阻塞当前部署(人工可纠正),但自动接续机制依赖准确状态

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 状态快照的写入者(agent)和状态的生产者(后台进程)是分离的。agent 退出前拍的快照只是"最后一瞟",不能代表后台进程的最终状态。**真相应该由生产者写**(后台进程完成时自己写 `.DONE` 哨兵 + 更新 state.json),而不是靠会离开的观察者。

---

## 修复方案

### 设计层修改

- [ ] **① 自报终态**:长任务(后台进程)套 `trap` 或 `wait` + 完成时原子写 state.json 更新 + 放哨兵文件(`.DONE`/`.FAILED`)
  - 例:fetch-weights 的 `nohup hf download ... &` 完成后写 `workspace/<slug>/weights/.DONE` + `jq '.fetch_state.progress = "100%" | .fetch_state.files_done = N' state.json`
- [ ] `.claude/CLAUDE.md` 加规则:长任务完成后必须写哨兵文件 + 更新 state.json
- [ ] SKILL.md(fetch-weights / install-env / run-and-repair)加"自报终态"步骤

### 实现层修改

- [ ] 修 `cron/launch_worker.sh`:长任务 wrapper 脚本套 `trap 'write_sentinel' EXIT`
- [ ] 修 `.claude/hooks/session-start.sh`:读哨兵文件而非读 state.json 快照判断阶段完成

### 文档层修改

- [ ] retro 加注:指向本 fix

---

## 验证步骤

1. 模拟 fetch-weights 后台下载完成:
   ```bash
   touch workspace/test-slug/weights/.DONE
   jq '.fetch_state.progress = "100%"' workspace/test-slug/state.json
   ```
2. 下次 session /auto-recover 读 state.json → 应看到 `fetch_state.progress = "100%"` + `.DONE` 存在
3. 期望:auto-recover 直接跳到 install-env,不重新 fetch

---

## 修复结果

- **状态**: ✅ 成功(R10 sentinel)
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/hunyuan3d-2/`(快照记 4/37 实际 37/37)
- workspace: `workspace/song-generation/`(status:null)
- workspace: `workspace/song-generation-run2/`(slug:null)
- 相关 SKILL: `.claude/skills/fetch-weights/SKILL.md`
- 相关 R 规则: `.claude/CLAUDE.md` R3(wall-clock 上限)

---

## 关联

- **关联 fix**: [2026-05-29-polling-handoff-mechanism-fix.md](2026-05-29-polling-handoff-mechanism-fix.md)(本 fix 是交接机制修复的子问题"① 自报终态")
- **关联 retro**: `workspace/hunyuan3d-2/results/2026-05-27-hunyuan3d-2-deploy-retrospective.md` §6 P1
- **关联分析**: `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md` §3 ①

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 否(平台特定问题)
- [ ] **是否需要 L1 / L2 重测验证** → 是(哨兵写入 + 读取 集成测试)
- [ ] **是否需要写 pending_human** → 否

---

## 闭环补记(2026-06-10)

与 [2026-05-29-polling-handoff-mechanism-fix.md](2026-05-29-polling-handoff-mechanism-fix.md) 同一机制闭环:
- **自报终态** = `.claude/CLAUDE.md` R10:长任务 wrapper 完成时写 sentinel(`.DONE`/`.FAILED`)+ 更新 state.json,真相由生产者写
- **session-start.sh 读 sentinel**(行 60-92)而非只信 state.json 快照;sentinel done 仍要求 dispatch SubAgent 核实推进
- fetch-weights / install-env 已接 sentinel(2026-06-04 各自 ChangeLog)
- L1 实证同 polling-handoff fix:run `cron-2026-06-10-143028` 接续成功
