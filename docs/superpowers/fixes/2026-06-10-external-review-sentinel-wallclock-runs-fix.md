# 外部 review 采纳:sentinel 僵尸对账 + R3 代码级兜底 + runs 清理 + 5 个小补丁

## 元信息

- **Fix ID**: `2026-06-10-external-review-sentinel-wallclock-runs-fix`
- **创建日期**: 2026-06-10
- **级别**: P0(sentinel 僵尸)+ P1(R3 兜底/runs 清理)+ P3(小补丁×5)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-10(外部 AI review 20 条,逐条核实后采纳 9 条)

---

## 人话版

**一句话**：值班表说"小王还在岗",其实小王 5 小时前就倒了,没人改值班表。

**打比方**：下载工人(wrapper 进程)干完活要在白板(sentinel)上写"完工/失败"。但这次的工人是临时雇的(agent 现场手写 wrapper),不知道要写白板;他干到一半猝死了,白板永远写着"工作中"。第二天接班的人看白板以为还在干,傻等。更糟的是这栋楼的物业(容器 PID 1 = `tail -f /dev/null`)不收尸,尸体(僵尸进程)`kill -0` 还探得到"活着"。

**现在怎样**：scail 下载进程死了 5 小时(46.8/47GB,差一个文件断流 exit 1),sentinel 仍报 `running/849MB`;magenta-realtime 还有 2 个 6 月 8 日的陈年假 running sentinel。R3 wall-clock 上限纯靠 LLM 自觉。runs/ 堆了 68 目录 4.1GB 没人清。

**要做什么**：平台级"对账"——每次启动前把死进程的 sentinel/state 改写成真相(只写状态,绝不 kill);SKILL 加规则防 agent 再手写丢 trap 的 wrapper;runs/ 保守自动清理。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | scail(zai-org/SCAIL-Preview)+ magenta-realtime(陈年 sentinel) |
| **触发 run_id** | `cron-2026-06-10-143028` |
| **触发时间** | 2026-06-10 14:58 启动下载,17:51 断流死亡,20:06 发现 |
| **触发阶段** | fetch-weights(跨 cron 后台下载) |
| **workspace 路径** | `workspace/scail/` |
| **runs 路径** | `runs/cron-2026-06-10-143028/` |

---

## 现象(均已实测核实)

- 现象 1: PID 605912 `Z <defunct>` 5h03m,父进程是 PID 1(`tail -f /dev/null`,不收尸) — `ps -p 605912 -o stat` = `Z`
- 现象 2: sentinel `workspace/scail/.cache/handoff/fetch-weights-SCAIL-Preview.json` 仍 `status:"running", bytes:849874470`(14:58 的快照)
- 现象 3: 真实情况:46.8GB/47GB 已下,17:51 `httpx.RemoteProtocolError: peer closed connection`(一个 2.4GB 文件收到 2.0GB)→ `hf download exited with code 1`(log 有,sentinel 没有)
- 现象 4: `runs/` 68 条目 4.1GB(大头 magenta-resume 2.7G + e2e-magenta 1.2G),无自动清理
- 现象 5: workspace/magenta-realtime 还有 2 个 06-08 的假 running sentinel(对账脚本首跑即抓出)

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > ① SKILL 第 2 步 wrapper 模板**有** sentinel 终态写入(`RC=$? → python3 写 done/failed`),但本次 agent 为现场修代理**从头手写了 wrapper**,只写了 log 的 exit code,丢了 sentinel 写入 — prompt 模板对"agent 自由发挥"无防御;
  > ② 即使用模板,wrapper 被 SIGKILL 时终态也写不出 — 缺平台级对账兜底;
  > ③ 容器 PID 1 是 `tail -f /dev/null` 不收尸,僵尸进程用 `kill -0` 判活会误判"活着",必须看 `/proc/<pid>/stat` 的 `Z`;
  > ④ R3 wall-clock 是纯 prompt 约束,SubAgent 死亡时 state.json 永远停在 `running`;
  > ⑤ runs/ 无清理机制。

---

## 外部 review 20 条逐条裁决(核实后)

| # | 建议 | 裁决 | 理由 |
|---|---|---|---|
| 1 | sentinel 僵尸 | ✅ **采纳**(本 fix 主体) | 实证成立,且根因比 review 更深(agent 手写 wrapper + PID1 不收尸) |
| 2 | scail 44GB"缓存泄漏" | ⚠️ **定性纠正** | 实测 46.8/47GB 是**接近完成的正常下载**,无重复副本,仅 1 个 .incomplete;真问题=#1 没写终态 + 已在册 #30(完整性校验,部分落地) |
| 3 | "39 个 fix 很多未闭环" | ❌ **已过时** | 2026-06-10 当天已清零(#15-#24 全闭环,commit 740f619);review 举的 3 例:integrity=#30 在册部分落地、scan-e2e 已由 toonflow 闭环、state-stale 当日闭环 |
| 4 | runs/ 68 目录 4.1GB | ✅ **采纳** | 实证成立 → `scripts/clean-old-runs.sh`(保守:14 天+<100MB+排除用户自管目录,大目录只列不删) |
| 5 | gated preflight 不可信 | ✅ **部分采纳** | preflight 403 分类当日已修(#36);采纳增量=fetch 第 0 步先读 intake.json 的 gated 结果,blocked 不试下载 |
| 6 | 并发 hf 竞争检测 | ➖ **已覆盖** | per-repo pgrep 防护(#28)+ P2-11 僵尸审计已在;全局加强暂缓 |
| 7 | R3 无强制 | ✅ **采纳** | → `scripts/enforce-wallclock.sh`(stale running → paused_in_progress,1.5× 容忍,绝不 kill) |
| 8 | CLAUDE.md 16KB 瘦身 | ✅ **已执行**(用户拍板) | 当日转 fix #38:23KB→7.2KB 结论版,详解外迁 specs/2026-06-10-r-rules-reference.md,规则零删减(commit 8159339) |
| 9 | daily.sh/launch_worker 去重 | ⏸️ **缓** | daily.sh 有另一工作线未提交改动 + 明日 cron 关键路径,今晚不动启动链路 |
| 10 | .cache 改名 weights/ | ❌ **拒** | 跨 N 个 skill 的路径大改,回归风险 > 收益;cleanup 白名单已防误删 |
| 11 | 落盘双写成本 | ⏸️ **缓** | 架构决策,审计价值 vs 维护成本需权衡 |
| 12 | 僵尸清理三处分散 | ⏸️ **缓** | 与 #9 同批做 |
| 13 | skill 重复 R 规则 | ❌ **拒** | **故意设计**:S-1 根因(#31)= SubAgent 拿不到 system prompt/CLAUDE.md,skill 内复述是规则到达 SubAgent 的唯一通道 |
| 14 | monitor 浪费 token | ➖ **不动** | monitor-ride-along 属另一工作线 |
| 15 | pending_human 被动 | ➖ **已部分覆盖** | 日报模板有"待人手处理积压"全量表;推送系统缓 |
| 16 | auto-status 定时推送 | ❌ **拒**(现在) | 每小时一个 LLM turn 与 token 预算敏感冲突 |
| 17 | 报告无成本 | ✅ **采纳** | write-recommendation 报告加"当日 LLM 成本"行(抽 ndjson result.total_cost_usd) |
| 18 | 下载进度不可见 | ✅ **采纳** | fetch poll 同时写机器可读 progress.json 行 |
| 19 | python 版本推断不准 | ✅ **采纳** | intake 优先 requires-python/python_requires 字段,推断必标 confidence: low |
| 20 | record_outcome 失败丢结果 | ✅ **采纳** | 失败 → `state/outcomes-pending.jsonl` 暂存;auto-daily 任务 1 重试回填 |

**附加发现(review 没提,本次核实时抓到)**:auto-daily 任务 1 筛选只看 `state.phase ∉ {done, paused_for_human}`,而暂停语义在 `status` 轴 — eagle(phase=fetch-weights, status=paused_for_human)明天会被误接续再撞一次 403。已修:筛选加 `status != paused_for_human`。

---

## 修复方案(全部已落地)

### 实现层

- [x] 新建 `scripts/reconcile-sentinels.sh`:status=running 的 sentinel,PID 死/僵尸(看 `/proc/<pid>/stat` Z)→ 改写 status=dead + du 实测 bytes + log 尾部抓 exit_code。只写 sentinel,绝不 kill
- [x] 新建 `scripts/enforce-wallclock.sh`:state.json status=running 且 updated_at 超 R3 上限×1.5 → status=paused_in_progress + 注记。绝不 kill
- [x] 新建 `scripts/clean-old-runs.sh`:默认 dry-run;`--delete` 只删 >14 天且 <100MB 且不在排除清单(songgen-e2e-*,R-HO-2)的目录;大目录只列入 .last_cleanup.log
- [x] `cron/daily.sh` + `cron/launch_worker.sh` 启动前置接入(daily 三个全接,launch_worker 接对账两个)

### 设计层(SKILL)

- [x] `fetch-weights/SKILL.md`:poll 第 0 项(PID 死/僵尸 → 立即写 sentinel 终态)+ 反模式(禁自创 wrapper 丢 sentinel trap)+ 第 0 步读 intake gated 结果 + progress.json
- [x] `auto-daily/SKILL.md`:任务 1 筛选加 status 轴 + outcomes-pending 重试
- [x] `write-recommendation/SKILL.md`:成本行 + record_outcome 失败 fallback
- [x] `intake/SKILL.md`:python_requires 优先,推断标 low confidence

---

## 验证步骤

1. `bash scripts/reconcile-sentinels.sh` → 实跑首轮即修正 3 个假 running sentinel(scail:dead/exit_1/46799523519 bytes;magenta×2)✅
2. `jq .status workspace/scail/.cache/handoff/fetch-weights-SCAIL-Preview.json` → `"dead"` ✅
3. `bash scripts/enforce-wallclock.sh` → 当前无 stale running,0 updated(负样本正确)✅
4. `bash scripts/clean-old-runs.sh`(dry-run)→ 14d 阈值 0 选中;`RETENTION_DAYS=7` 正确选中 2 个 controlfoley 老目录,大目录/排除目录不碰 ✅
5. `bash -n` 三脚本 + daily.sh + launch_worker.sh 语法通过 ✅
6. 明日 10:00 cron:daily.sh 前置对账后,scail 接续应基于 dead sentinel 重启下载(hf 续传补完最后 ~0.4GB)

---

## 修复结果

- **状态**: ✅ 成功
- **验证证据**: 上节 1-5;6 为次日观察项
- **commit hash**: `2dca1df`
- **commit message**: `ai-auto: 外部 review 采纳 — sentinel 对账 + R3 兜底 + runs 清理 + 5 小补丁(20 条裁决表)`

---

## 证据指针

- workspace: `workspace/scail/`(46.8GB 权重 + 修正后 sentinel)
- 日志:`workspace/scail/logs/fetch_weights.log`(17:51 断流 exit 1)
- 僵尸证据:`ps -p 605912 -o stat` = Z,PPID=1(`tail -f /dev/null`)
- 脚本:`scripts/{reconcile-sentinels,enforce-wallclock,clean-old-runs}.sh`
- 相关 R 规则:R3(wall-clock)/ R10(sentinel)

---

## 关联

- **关联 fix**:`2026-05-29-polling-handoff-mechanism-fix`(R10 sentinel 体系;本 fix 是其"生产者死亡不写终态"盲区的兜底)、`2026-06-03-fetch-weights-no-download-integrity-check-fix`(#30,resume 完整性;review #2 的正确归属)、`2026-06-10-no-proxy-pollution-gated-403-fix`(#36)
- **关联 spec/plan ChangeLog 条目**:fetch-weights / auto-daily / write-recommendation / intake 各自 2026-06-10 条目

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [x] **Master Plan Fix 索引区已更新** → ✅
- [ ] **是否提升到 memory/lessons** → 否(脚本注释 + SKILL 反模式已覆盖)
- [ ] **是否需要 L1 / L2 重测验证** → 是(明日 10:00 cron 观察 scail 基于 dead sentinel 正确接续)
- [ ] **是否需要写 pending_human** → 否(缓/拒清单已在本文档裁决表)
