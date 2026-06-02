# 并发 hf download 锁竞争 + 僵尸 hf 进程残留:加并发防护 + 启动期审计

## 元信息

- **Fix ID**: `2026-06-02-concurrent-download-zombie-guard-fix`
- **创建日期**: 2026-06-02
- **级别**: P1(并发防护)/ P2(僵尸审计)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-02

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | controlfoley(并发)+ 历史 song-generation 等(僵尸残留) |
| **触发 run_id** | `e2e-controlfoley-20260602-103052` |
| **触发时间** | 2026-06-02(并发)+ 自 2026-05-21 起累积(僵尸) |
| **触发阶段** | fetch-weights / ops |
| **workspace 路径** | `workspace/controlfoley/` |
| **runs 路径** | `runs/e2e-controlfoley-20260602-103052/` |

---

## 现象

- 现象 1(P2-6): LLM 见下载慢就"重试",起了 3 个 `hf download` 进程写同一 `--local-dir`,锁竞争 → 0 MB/s 卡死(没 kill 旧进程)。
- 现象 2(P2-11): 17 个 `<defunct>` hf 进程从 2026-05-21 残留。

---

## 触发条件 / 复现步骤

1. fetch-weights 启动 bg `hf download`,LLM poll 见速度慢。
2. LLM "重试" → 再起一个 `hf download` 同 repo 同 `--local-dir` → Xet/文件锁竞争。
3. 进程退出不干净(worker 被 kill / 跨 cron)→ 留 `<defunct>` 累积。

---

## 影响

- **影响范围**: fetch-weights 下载吞吐(并发锁竞争直接 0 MB/s)+ 进程表卫生。
- **影响下游**: 下载卡死撞 R3 wall-clock 超时 → 误判 paused/blocked。
- **严重程度**: P1(并发)— 直接卡死下载;P2(僵尸)— 渐进式 PID 占用。

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > 1. fetch-weights SKILL 只用散文说"串行",无**硬防护**:启动新 `hf download` 前不检查同 repo 是否已在跑。
  > 2. 历史僵尸:worker 异常退出留下 `<defunct>` hf,无启动期审计/可见性。

---

## 修复方案

### 设计层修改

- [x] `fetch-weights/SKILL.md` 第 2 步:启动 `hf download` 前 `pgrep -f "hf download.*$REPO"`,已有则**跳过**(不起新进程),提示"要重启先 pkill"。反模式段加并发条目。
- [x] `.claude/agents/fetch-agent.md`:加"起前先 pgrep"约束。
- [x] `.claude/CLAUDE.md` R7:加并发防护条目。

### 实现层修改

- [x] `cron/launch_worker.sh` 启动期:加 `hf` 进程审计 python 块。**保守边界**:
  - 真僵尸(state Z,PPID=1,父已死)→ init 自动收割,**只记录计数**到 `.last_cleanup.log`。
  - 活的 `hf download`(含 setsid nohup PPID=1)→ **绝不杀**(那是 fetch-weights 合法跨 cron 接续 R4.4,也可能是用户/别 run 的)→ 只报告 pid/etimes/args 供人核实。
  - 破坏性 reap 仍只走既有「dead worker.pid 名下 .cache/*.pid」逻辑(未改)。

> **为何不激进 reap**:`setsid nohup hf download` 故意让进程 PPID=1 以跨 cron 存活(R4.4 设计)。无差别杀 PPID=1 的 hf 会破坏合法接续 + 可能误伤用户进程(R-HO-1)。故僵尸/孤儿只审计报告,不自动杀。

---

## 验证步骤

1. `grep -n 'pgrep -f "hf download' .claude/skills/fetch-weights/SKILL.md` → 命中并发防护。
2. 模拟:起一个 `sleep 300` 伪装 `hf download <repo>`,再走第 2 步 → 第二次被 pgrep 拦下,log 出 "已有 ... 跳过"。
3. `launch_worker.sh` 跑完 → `runs/.last_cleanup.log` 出 hf 审计段(若有 defunct/orphan)。

---

## 修复结果

- **状态**: ✅ 成功(并发硬防护落地;僵尸保守审计,不做高风险 kill)
- **commit hash**: <填 WS2 commit>
- **commit message**: `ai-auto: P2 fetch — hf 1.x 现代化（去 --resume-download / Xet）+ 并发下载/僵尸防护`

---

## 证据指针

- SKILL: `.claude/skills/fetch-weights/SKILL.md`(第 2 步并发防护 + 反模式)
- 启动器: `cron/launch_worker.sh`(hf 进程审计块)
- 审计输出: `runs/.last_cleanup.log`
- R 规则: `.claude/CLAUDE.md` R7

---

## 关联

- **关联 fix**: [2026-06-02-fetch-weights-hf1.x-modernization-fix](2026-06-02-fetch-weights-hf1.x-modernization-fix.md)(同 fetch 簇)+ [2026-05-21-agent-isolation-fix](2026-05-21-agent-isolation-fix.md)(R1 不杀别人进程,本 fix 守同一边界)
- **关联 retro**: ControlFoley e2e 2026-06-02(问题 5/7)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(fetch-weights SKILL + CLAUDE.md R7)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ WS3
- [ ] **是否需要更激进的僵尸 reap** → 待用户决策(当前保守审计;若确认无跨 cron 接续场景可加定向 kill)
