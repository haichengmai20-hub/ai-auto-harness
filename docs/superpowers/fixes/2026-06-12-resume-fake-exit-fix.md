# Fix: 续跑假退出 — fetch-weights 后台下载免续跑

**日期**: 2026-06-12
**严重度**: P1（效率，每次假续跑浪费 ~20min + 100+ API 调用）
**触发**: khala 48.6GB 权重下载，4 次续跑全空转
**Spec**: [2026-06-11-cron-resume-and-optimization.md §7](../specs/2026-06-11-cron-resume-and-optimization.md)

---

## 问题

fetch-weights 阶段下载大权重时，`hf download` 以 `setsid nohup &` 在后台运行。但每次 cron 续跑 agent 都会：
1. 完整走 auto-daily 流程（任务1→任务2→任务3）
2. dispatch fetch-weights SubAgent
3. SubAgent poll 8 turn 确认 "还在下"
4. hit R4 上限 → paused_in_progress → 退出
5. daily.sh 检测 in_progress → 30min后续跑

形成 **假退出 → 续跑 → 又假退出** 循环。khala 实战 4 次 run × ~20min，实际只做了 "看一眼下载还在不在"。

## 根因

后台下载 PID 活着时，不需要 agent 守着。但现有逻辑没有区分 "需要 agent 介入的 in_progress" 和 "只需等待的 in_progress"。

## 方案

三层改动，详见 spec §7.4：

### 1. daily.sh：续跑判断加 PID 存活检查（步骤 1，最高优先）

在续跑判断中，过滤掉 "后台下载 PID 还活着" 的项目，不消耗续跑配额。

### 2. fetch-weights SKILL：PID 活着时 1 turn 退出

现有：PID 活着 → poll 8 turn → 退出
改为：PID 活着 → 1 次 kill -0 + 1 次 du -sh → 返回 {bg_download_alive: true, skip_resume: true}

### 3. auto-daily SKILL：任务 1 加 bg_download_alive 判断

PID 活着 → 不 dispatch SubAgent，直接跳到任务 4 写报告，告知 daily.sh 不设续跑。

## 影响范围

- `cron/daily.sh`：续跑判断逻辑
- `.claude/skills/fetch-weights/SKILL.md`：poll 逻辑
- `.claude/skills/auto-daily/SKILL.md`：任务 1 接续判断

## 验证场景

| 场景 | 预期行为 |
|------|---------|
| 后台下载活着 | 不续跑、不消耗配额、0 token |
| 下载完成（PID 死） | 次日 cron 检测到 → 正常推进 |
| 下载崩溃 | 同上，下次 cron force-download |
| 非 fetch-weights 的 paused_in_progress | 不受影响，正常续跑 |

## 实现(2026-06-12,审查后落地)

实现时对 spec §7.4 草案做了 4 处必要修正(草案照抄会埋雷):

| # | spec 草案问题 | 实现修正 |
|---|---|---|
| 1 | `kill -0 $pid` 判活 — **对僵尸误判活**(容器 PID 1 不收尸;khala 现场 `fetch-weights.pid` 当时就是 Z 态且 kill -0=yes,平台 #37 已踩过) | 判活必须查 `/proc/<pid>/stat` 第 3 列 ≠ Z |
| 2 | 只判 PID 死活,**无停滞检测** — PID 活着但 0 进度时,步骤 1 跳过续跑 + 步骤 3 让 10:00 agent 也跳过 dispatch → **永远没人再看这个下载**(饿死) | 健康 = 活 + 非僵尸 + **30min 内有进度**(local_dir/log/sentinel mtime 三选一);停滞 → NEEDS_AGENT 走正常续跑去重启 |
| 3 | 下载完成后**干等次日 10:00**(最长 ~20h 流水线延迟,且次日还可能撞磁盘门槛) | **免配额复查链**:0-token 纯 bash,10min 一次重入 daily.sh;WAIT_GATE 发现全健康 → 跳过 worker 续挂链;发现 PID 死 → 立即起 worker 接续(此启动消耗续跑配额,防"反复崩→复查→起 worker"绕过 3 次/天上限) |
| 4 | "通过输出标记告知 daily.sh 不设续跑" — agent 输出与 daily.sh 的耦合不可靠 | daily.sh 不信 agent 输出,**自己跑 helper 复核**;return 字段只供报告用 |

落地代码:
- **`scripts/check-bg-downloads.sh`(新,单一真相源)**:per in_progress 项目输出 `WAITING`(健康后台进程)/ `NEEDS_AGENT reason=no_running_sentinel|pid_dead|pid_zombie|stalled_30min`。只读不杀。CC daily.sh 与 hermes preflight 共用
- **`cron/daily.sh`**:入口 WAIT_GATE(全 WAITING → 不起 worker,挂复查链,exit 0)+ 复查链调度(`state/bg-recheck.pid` 去重;`AI_HARNESS_BG_RECHECK=1` 触发的启动消耗续跑配额)+ 尾部续跑判断从 `IN_PROGRESS_SLUGS` 改为 `NEEDS_AGENT_SLUGS`(WAITING 不耗配额只挂链)
- **`fetch-weights/SKILL.md`**:第 1 步接续健康 → 1-turn 快退(return `bg_download_alive/skip_resume`);第 3 步 poll 限定"本次新启动的头几分钟抓秒挂",稳定后同样快退
- **`auto-daily/SKILL.md`**:任务 1 dispatch 前跑 helper,WAITING 不 dispatch 直接写报告
- **Hermes 版同步**:`hermes/scripts/harness-preflight.sh` BG_DOWNLOAD 门 + `hermes/skills/.../references/fetch-weights.md` 快退 + SKILL 任务 1

实现中发现并修复的新 bug:**复查链 nohup 子进程继承 flock FD 200**,睡 10min 期间锁死一切 daily.sh 启动(cron/续跑全被挡)— fixture A2 场景抓到,修法 `nohup ... 200>&- &`。

## 验证

1. helper fixture 6 场景:healthy→WAITING / dead→pid_dead / **僵尸(实测 kill -0=yes,stat=Z)→pid_zombie** / 停滞(活 PID+2h 旧 mtime)→stalled_30min / done与paused_for_human→静默 ✅
2. khala 真实数据:`NEEDS_AGENT khala reason=pid_dead`(下载已完成 49G,等接续)✅
3. daily.sh fixture:A1 全健康→WAIT_GATE 跳过(runs/ 未创建)+挂链;A2 二次进入→"不重复调度"去重;B 死 PID→正常起 worker+尾部配额 1/3+30min 续跑;C 复查触发+配额 3/3→拒绝启动;C2 复查触发+配额 1/3→启动并计数 ✅
4. 复查链 FD 泄漏修复:新链 bash 与其 sleep 子进程均不持有 FD200 ✅
5. hermes preflight 实跑:khala 列入"需 agent 介入",不被 BG 门误拦 ✅
6. 留实战验证:下一个大权重项目 fetch 阶段,确认全程 ≤2 次 agent run(启动 1 + 完成后接续 1)

## 状态

- [x] 问题分析 + spec 写入
- [x] daily.sh 改动实现(+WAIT_GATE/复查链,超出 spec 草案)
- [x] fetch-weights SKILL 改动
- [x] auto-daily SKILL 改动
- [x] helper + fixture 测试(6+5 场景)
- [ ] 实战验证(下一个大权重项目)

## 修复结果

- **commit hash**: `c39dfe7`

