# 轮询/交接机制断裂 — fetch 完成后 ~18.7h 无人接棒

## 元信息

- **Fix ID**: `2026-05-29-polling-handoff-mechanism-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-26 retro)
- **级别**: P0(系统级,每个 auto-deploy run 共用)
- **状态**: ✅ 已闭环(MVP 档;watchdog/supervisord 加固档转 env-no-daemon fix 残留)
- **负责人 / session**: 用户实测发现 + Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：权重下完了，但没人知道该开始装环境了，在那干等了 18.7 小时。

**打比方**：像快递到了放门口，但家里没人收，一直放到你下班回家才发现。

**现在怎样**：fetch 阶段 AI 撞了 poll 预算退出后，没有东西检测"下载完了没"并触发下一阶段。

**要做什么**：写个看门狗脚本，每分钟检查 state.json，发现 paused_in_progress 就自动续跑。或者靠 SessionStart hook 每次新会话时扫一遍有没有卡住的任务。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | hunyuan3d-2 |
| **触发 run_id** | `2026-05-25-1752-*`(/auto-deploy 触发) |
| **触发时间** | 2026-05-25 18:59(agent 撞 poll 预算退出) → 2026-05-26 14:47(人工接续) |
| **触发阶段** | fetch-weights(权重下完但无人推进到 install-env) |
| **workspace 路径** | `workspace/hunyuan3d-2/` |
| **runs 路径** | `runs/2026-05-25-1752-*/` |

---

## 现象

- 现象 1: Hunyuan3D-2 权重于 2026-05-25 ~20:07 在后台独立下载完毕(19GB,完整,无 `.incomplete`),但流水线**停了约 18 小时无人推进**,直到 05-26 14:47 被手动 `/auto-recover` 接续
  - 证据: `workspace/hunyuan3d-2/repo/weights/` 19GB 完整;`state.json` 冻结在 `phase=fetching` 快照(记"4/37 文件 0.003GB"——下载启动 3 分钟时的早读)
- 现象 2: `runs/` 下**无任何 `cron-*` 目录**,所有 run 的 trigger 全是手动(`/auto-deploy`、`/auto-recover`)——cron 自动化从未在本环境接通
  - 证据: `find runs/ -maxdepth 1 -name "cron-*" | wc -l` → `0`;各 `runs/*/meta.json` 的 `trigger` 字段
- 现象 3: 当前环境 PID 1 是 `tail -f /dev/null`(站桩占位进程),无 init/systemd/cron/supervisord 运行——**没有任何东西会"自动启动/保活"服务**
  - 证据: `cat /proc/1/cmdline | tr '\0' ' '` → `tail -f /dev/null`

---

## 触发条件 / 复现步骤

1. 环境:无 cron、无 init、无 supervisord,PID 1 = `tail -f /dev/null`
2. `/auto-deploy` 启动,fetch-weights 阶段用 `setsid nohup ... &` 后台下载
3. LLM 轮询撞 R4 poll 预算(≤8 次)→ 写 `paused_in_progress` + 退出
4. 后台下载进程继续跑,在 agent 退出后独立完成
5. **无任何机制检测"fetch 已完成但 install 还没跑"** → 权重静静躺在磁盘,无人接棒
6. 只能靠人工巡检发现,或手动 `/auto-recover` 接续

---

## 影响

- **影响范围**: 可靠性 + 效率(自动化从未真正闭环)
- **影响下游**: 所有需要跨 cron 接续的阶段(fetch→install、install→run 等);大模型下载/CUDA 编译等长任务场景必触发;失败是"无声"的——只能靠人肉巡检
- **严重程度**: P0 — 坏掉的是公共机制(每个 auto-deploy run 共用),hunyuan 只是第一个显形的症状;触发条件很普遍(大模型下载慢、CUDA 扩展编译慢均为常态)

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > ai-auto-harness 的交接机制是"被动轮询"——agent 撞预算后写 `paused_in_progress` 退出,指望 cron 或 `/auto-recover` 回来接。但**接棒机制不存在**:本环境无 cron、无 daemon、无 init,hook 也没做"续跑未推进任务"的逻辑。更根本地,**即使有 cron,底层设计弱点仍在**(交接无核实、无晾置告警、快照失真)——cron 挂了或续跑 agent 中途崩了,同样复发。**触发器是局部的(没 cron),病根是系统性的。**

---

## 修复方案

> 已有详细设计方案,见 `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md` §3-§4。

### 设计层修改(spec / plan / SKILL.md / CLAUDE.md)

- [ ] **① 自报终态**:长任务套 trap,结束时原子写 `state.json`(done/failed)+ 放哨兵文件(`.DONE`/`.FAILED`)。真相由生产者写,不靠会离开的观察者
- [ ] **② hook 自愈(主触发器)**:`SessionStart` hook:扫 paused / 已完成但未推进的任务 → 续上、确保看门狗在;`SessionEnd` hook:退出前核实 + 失败/晾置告警。这是 MVP,不依赖任何 daemon
- [ ] **③ shell 看门狗**:纯 shell 常驻循环,只探测生命周期事件(进程死活、哨兵、进度卡住),不判断成败,有事件就叫 LLM
- [ ] **④ supervisord 当 entrypoint**:让 supervisord 当容器 PID 1:开机自起 + 保活看门狗
- [ ] `.claude/CLAUDE.md` 加新 R 规则(暂编 R10):长任务完成后必须写哨兵文件;SessionStart hook 必扫 paused 任务

### 实现层修改(代码 / 脚本 / 配置)

- [ ] 修 `cron/launch_worker.sh`:长任务套 `trap` 写哨兵文件
- [ ] 修 `.claude/hooks/session-start.sh`:加"扫 paused + 已完成未推进任务 → 续跑"逻辑
- [ ] 修 `.claude/hooks/session-end.sh`:加"退出前核实 + 失败告警"逻辑
- [x] 修 `.claude/skills/auto-deploy/SKILL.md`:重复 launch 同 slug 时先读旧 `state.json`,非终态必须接续,禁止覆盖成新 intake
- [ ] 新建 `cron/watchdog.sh`:shell 常驻看门狗(加固档,非 MVP)
- [ ] (根治档)改容器 entrypoint 为 `supervisord`

### 文档层修改(retro / lessons / handoff)

- [ ] 在 retro 加注:指向本 fix
- [ ] 提升到 `memory/lessons/daemon-less-handoff.md`

---

## 验证步骤

1. **MVP 验证**(①+②):
   ```bash
   # 模拟:fetch 完成后写 .DONE 哨兵 + state.json phase=installing
   touch workspace/test-slug/weights/.DONE
   jq '.phase = "installing"' workspace/test-slug/state.json
   # 模拟:下次有人跑会话 → SessionStart hook 应扫到 "installing 但 install 没跑"
   # 期望:hook 自动 dispatch install-agent
   ```
2. **哨兵验证**:长任务完成后 `ls workspace/<slug>/weights/.DONE` 存在
3. **告警验证**:SessionEnd hook 在有 paused 任务时输出告警到 stderr

---

## 修复结果

- **状态**: ✅ 成功(MVP:R10 sentinel + hook 自愈)
- **验证证据**:
  - 设计方案见 `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md`
  - 2026-06-04 已新增 R10 handoff sentinel 约定、SessionStart resume hints、SessionEnd handoff audit
  - `fetch-weights` / `install-env` skill 已要求后台 wrapper 写 `workspace/<slug>/.cache/handoff/*.json`
  - 2026-06-04 已收紧 `/auto-deploy <url>` 重复 launch 语义:先做 workspace 预检,同 slug 非终态直接从 `state.phase` 接续,不重新写初始 state
  - 2026-06-04 静态验证:预检位于 `analyze_project` 和初始 `state.json` 写入之前;旧表格中“/auto-deploy 不接续”矛盾描述已移除
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/hunyuan3d-2/`
- runs: `runs/2026-05-25-1752-*/`(hunyuan auto-deploy 原始 ndjson)
- 设计方案: `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md`
- 报告: `reports/2026-05-26-hunyuan3d-2.md`
- 相关 R 规则: `.claude/CLAUDE.md` R4(poll 预算退出行为)
- 相关 hook: `.claude/hooks/session-start.sh`(待加自愈逻辑)
- 相关 hook: `.claude/hooks/session-end.sh`(handoff audit)
- 相关规则: `.claude/CLAUDE.md` R10

---

## 关联

- **关联 fix**: [2026-05-21-sleep-loop-discipline-fix.md](2026-05-21-sleep-loop-discipline-fix.md)(R4 poll 预算是"撒手"侧,本 fix 是"接棒"侧)
- **关联 fix**: [2026-05-29-state-snapshot-stale-fix.md](2026-05-29-state-snapshot-stale-fix.md)(快照失真是交接机制的另一缺陷)
- **关联 retro**: `workspace/hunyuan3d-2/results/2026-05-27-hunyuan3d-2-deploy-retrospective.md` §6 P0
- **关联分析**: `workspace/hunyuan3d-2/results/2026-05-26-polling-handoff-analysis.md`(完整根因 + 方案)

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加(落地时加)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(跨项目通用:`daemon-less-handoff.md`)
- [ ] **是否需要 L1 / L2 重测验证** → 是(MVP 落地后用 hunyuan workspace 实跑验证)
- [ ] **是否需要写 pending_human** → 否(方案已定,待排期实施)

---

## 闭环补记(2026-06-10)

MVP 三件套已全部落地并经真实 run 验证:
- **R10 已入 `.claude/CLAUDE.md`**(2026-06-04):长任务必写 sentinel,生产者写终态
- **session-start.sh** 扫 handoff sentinel + paused 任务,注入 "dispatch the matching SubAgent via Task() to resume" hint(行 60-92)
- **fetch-weights / install-env** 后台长任务 wrapper 写 sentinel(各自 SKILL 2026-06-04 ChangeLog)

**L1 实证**:run `cron-2026-06-10-143028` — eagle `paused_in_progress`(11:35 留下)被 session 起始扫描发现,主 agent Task() dispatch fetch-agent 成功接续,state 正常推进(fetching→paused_for_human,gated 403)。"权重下完没人接手干等"的场景已被 sentinel+接续机制覆盖。

**残留(加固档,不阻塞本 fix)**:cron/watchdog.sh 常驻看门狗、supervisord entrypoint — 归 [2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md](2026-05-29-env-no-daemon-auto-not-closed-loop-fix.md) 第 3 档跟踪。
