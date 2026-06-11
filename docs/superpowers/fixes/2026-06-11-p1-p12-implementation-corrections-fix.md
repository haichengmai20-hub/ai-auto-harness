# P1-P12 实现审查更正:4 个真 bug + 编号冲突 + 规则没下沉到 SubAgent

## 元信息

- **Fix ID**: `2026-06-11-p1-p12-implementation-corrections-fix`
- **创建日期**: 2026-06-11
- **级别**: P1(无限重试风险 + 大项目误搁浅 + 规则无效)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-11(用户要求审查 SCAIL 试跑复盘批次的实现)

---

## 人话版

**一句话**：上一班修的方向都对,但有 4 颗螺丝拧错了孔,还有三条新规矩贴在了员工看不到的墙上。

**打比方**：①闹钟修好了但贪睡按钮接错线——失败重试的"只试一次"标记传不进去,坏了会每 15 分钟无限重试;②管家查仓库走错了货架编号(`org--repo` vs `org/repo`),永远查不到货;③"试三次不行就叫人"被写成"试三次不行就把还在正常干活的人也叫停";④给修理工立的三条新规(别换图纸/螺丝刀缺了不算次数/巡检可以放慢)贴在了经理办公室——修理工(SubAgent)从来不进经理办公室。

**现在怎样**：均已更正并测试。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | scail(P1-P12 批次的试跑来源) |
| **触发 run_id** | `cron-2026-06-11-110631` / `cron-2026-06-11-144320` / `cron-2026-06-11-152125` |
| **触发时间** | 2026-06-11(实现);2026-06-11 20:12 审查 |
| **触发阶段** | ops(平台代码审查) |
| **workspace 路径** | `workspace/scail/` |
| **runs 路径** | `runs/cron-2026-06-11-*/` |

---

## 审查发现(逐条核实 4f562be/fd53ade 批次)

### 真 bug(4 个,已修)

| # | 文件 | 问题 | 后果 | 修正 |
|---|---|---|---|---|
| B1 | `scripts/reconcile-state.sh` 规则 1 | 权重目录拼成 `hf_models/org--repo`,而 DEST 约定(2026-06-08 fix)是嵌套 `hf_models/<org>/<repo>`(scail 实测路径为证) | 规则 1 永远查不到目录 → 整条规则是死代码 | 改嵌套路径;另加体积下限(实际 ≥ 估算 80%)防"无 .incomplete 但整文件缺失"误判 done |
| B2 | 同上 规则 2 | `[ A ] \|\| [ B ] && [ C ]` — bash 中 `\|\|`/`&&` 同级左结合,phase=installing 时 status 条件被绕过 | status=done 也反复触发,`phases_done` 无限重复 append | 加 `{ ;}` 分组;`phases_done` 改 `unique` 去重 |
| B3 | 同上 规则 4 | `[ "$x" = "*RESOLVED*" ]` 是字面量比较不是 glob | 永假,死代码 | 改 `case ... in *RESOLVED*)` |
| B4 | `cron/daily.sh` P6 重试 | `AI_HARNESS_IS_RESUME=1 cd ... && bash daily.sh` — env 前缀只作用于 `cd`,daily.sh 收不到 | 重试 run 再失败会再调度重试 → **持续性故障(API 挂/bun 丢)下每 15 分钟无限重试烧钱** | env 前缀移到 `bash cron/daily.sh` 上 |

### 设计缺陷(2 个,已修)

| # | 问题 | 修正 |
|---|---|---|
| D-a | 续跑 3 次配额用完后**强制把所有 in_progress 标 paused_for_human** — 会把仍在合法跨 cron 下载的大权重项目(paused_in_progress)误杀,且次日 cron 筛选排除 paused_for_human → **永久搁浅** | 配额用完只停止当日续跑 + 记日志,项目留给次日 10:00 cron 自然接续;失败升级仍走 R3 超时/3 轮上限的正规通道 |
| D-b | **P10/P11/P12 三条规则只写进 CLAUDE.md** — run-and-repair SubAgent 收不到 CLAUDE.md(S-1 根因,#31;本项目两天前刚以同样理由拒绝过"删 skill 内规则复述"的建议) | 三条规则全文下沉 `run-and-repair/SKILL.md`(轮次分类 + 分支纪律 + poll 动态间隔)+ 反模式 |

### 一致性冲突(3 个,已修)

| # | 问题 | 修正 |
|---|---|---|
| C1 | 新规则编号 R4.1/R4.2 与既有 R4.1(sleep≤60s)/R4.2(连续 sleep 禁)撞号 — **hook 告警文案用的是旧编号**,agent 会把"R4.1 VIOLATION: sleep>60s"理解成动态间隔规则 | poll 动态间隔 → **R4.6**;git checkout 禁令 → **R11**(新顶级规则);REF 补全文 |
| C2 | 动态间隔"递增至 120s"违反 R4.1 单次 sleep ≤60s 硬上限(hook 会告警) | 改 30s→45s→60s,更长等待用 `sleep 55 && tail` 合并为一次 poll;预计超预算直接 paused_in_progress(30min 续跑机制已把接续成本降下来) |
| C3 | preflight P4 推荐卡数公式示例自相矛盾(`ceil((42+8)/32)=2` 却写"3~4 卡");聚合判定漏"模型必须支持多卡切分"前提(单体模型聚合够也跑不起来) | 公式统一 `ceil(need/(30×1024))`,need=权重×1.5;补多卡切分前提,不支持切分按最大单卡 free 判 |

### 小问题(已修)

- 午夜 ≥23 点删当日续跑计数 → 反而在深夜多放 3 次配额;计数文件本就按日期命名无需重置。改为清理 3 天前的旧计数文件
- reconcile-state 规则 1 顺手写 `previous_failure="RESOLVED"` 污染 P8 资源类语义(且与 `*_RESOLVED` glob 不匹配)→ 移除
- 规则 3 `kill -0` 判活对僵尸误判(PID 1 不收尸,同 #37 教训)→ 改读 `/proc/<pid>/stat` Z
- D2 违反:preflight/auto-daily/install-env/CLAUDE.md 改动均无 ChangeLog → 已补 4 条
- hook 缺 R11 检测 → 已加(`git checkout|switch` 不含 ` -- ` 注入警告)

### 复盘文档本身的小勘误

- §三 表格 "CLAUDE.md +R4.1/R4.2" → 实际编号已改 R4.6/R11(见本 fix C1)
- P12 方案 "30s→60s→120s" → 已调和为 ≤60s 上限内(见 C2)

---

## 验证

1. reconcile-state fixture 3/3:嵌套路径+体积达标 → 修正 done(phases_done 去重);含 .incomplete → 不动;体积不足 → 不动 ✅
2. hook R11 单测 4/4:`git checkout wan`/`git switch main` 告警;`git checkout -- file`/`git status` 不告警 ✅
3. `bash -n` daily.sh / reconcile-state.sh / post-tool-use.sh 全过 ✅
4. 留次日观察:cron 10:00 起一轮,确认续跑链与重试链不嵌套失控、scail/eagle(paused_for_human)不被误接续

---

## 修复结果

- **状态**: ✅ 成功
- **commit hash**: `cda7d9e`
- **commit message**: `ai-auto: P1 fix #39 — P1-P12 实现审查更正(4 bug + 编号冲突 + 规则下沉 SKILL)`

---

## 关联

- **关联 fix/spec**:`specs/2026-06-11-试跑复盘与验证清单.md`(被审对象)、`specs/2026-06-11-cron-resume-and-optimization.md`、`2026-06-10-external-review-sentinel-wallclock-runs-fix`(#37,R10 僵尸判定先例)、`2026-06-03-r9-task-dispatch-still-bypassed-fix`(#31,S-1 规则下沉依据)、`2026-06-08-fetch-dest-path-not-injected-fix`(DEST 嵌套路径约定)
- **关联 ChangeLog**:CLAUDE.md / run-and-repair / preflight-gpu-disk / auto-daily / install-env 各自 2026-06-11 条目

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(含补齐上一批欠的 D2)
- [x] **Master Plan Fix 索引区已更新** → ✅
- [ ] **是否提升到 memory/lessons** → 否
- [ ] **是否需要 L1 / L2 重测验证** → 是(次日 cron 观察续跑/重试链)
- [ ] **是否需要写 pending_human** → 否
