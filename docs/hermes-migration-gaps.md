# ai-auto-harness Hermes 迁移 — 框架完善清单

> 日期: 2026-06-15
> 来源: paddleocr 方案A 全流程试跑 + CC 版(khala)并行验证
> 原则: 只关注框架层面的问题和改善,不涉及具体项目的 bug

## 一、架构级问题 (P0)

### #1 CC/Hermes 双引擎切换

**现状**: `cron/daily.sh` 启动的是 `claude-haha`(CC 版),不是 Hermes。
crontab 10:00 触发的是 CC 版入口,Hermes 版的 phase 脚本虽然写好且验证通过,
但从未在 cron 流程中被使用。

**问题**:
- CC 版 cron 和 Hermes 版没有互斥机制(CC 用 flock,Hermes 用 agent-heartbeat,两者不互通)
- 两套代码并行维护,修改需要同步两处
- Hermes 版的方案A 优势(terminal 直跑,3KB context vs 500K tokens)无法在 cron 中体现

**方案**: 改 daily.sh 支持 `HERMES_MODE` 环境变量切换:
- `HERMES_MODE=1`: 启动 Hermes agent(通过 `hermes cron` 或直接调用),使用 hermes/ 下的 phase 脚本
- 默认(不设): 保持 CC 版启动,向后兼容
- flock/续跑/bg_recheck 逻辑共享,不因引擎切换而改变

### #2 后 3 个阶段无 phase 脚本

**现状**: verify / write-deploy-runbook / cleanup 三个阶段只有 delegate_task playbook
(references/*.md),没有 phase-*.sh 脚本。

**问题**:
- 这 3 个阶段必须用 delegate_task(子代理),不能用 terminal 直跑
- 子代理 600s 硬上限 + 高 token 消耗 + 不守 playbook 的风险
- 方案A 的核心优势无法覆盖这 3 个阶段

**方案**: 给 verify / runbook / cleanup 各写一个 phase-*.sh 脚本:
- `phase-verify.sh`: 检查 entry_script 输出文件是否存在+内容合法,对比预期结果
- `phase-runbook.sh`: 读取 verify result + intake/fetch/install/run 各阶段 results,生成 runbook JSON
- `phase-cleanup.sh`: 按规则清理 venv/权重/cache,保留必要产物

---

## 二、健壮性问题 (P1)

### #4 MAX_REPAIR_ROUNDS 逻辑不精确

**现状**: MAX_ROUNDS=3 + DEP_EXTRA_ROUNDS=2,repair_count 在每个修复动作都 +1。

**问题**: paddleocr 实测: path_fix + onednn_disable + paddlepaddle_downgrade = 3 次 repair,
还没验证降级效果就到了上限。

**方案**: 区分"修复动作"和"验证执行"——修复动作不消耗 round,只有执行+失败才消耗。
或者把 MAX_ROUNDS 从 3 提到 5(更简单)。

### #8 result JSON 统一 schema

**现状**: 各 phase 脚本自己写 result JSON 格式:
- install-env: `INSTALL_RESULT` + `FIXES_APPLIED` + `WARNINGS`
- run-and-repair: `REPAIR_COUNT` + `FIXES_APPLIED` + `ERROR_CLASS`
- intake: `entry_script` + `gpu_picks` + `ready_to_fetch`

**问题**: 没有统一 schema,主 agent 解析困难,字段名不一致。

**方案**: 定义统一 result schema:
```json
{
  "phase": "string",
  "status": "done|failed|paused_in_progress|paused_for_human|blocked",
  "duration_seconds": "number",
  "fixes_applied": ["string"],
  "warnings": ["string"],
  "error_class": "string|null",
  "error_detail": "string|null",
  "phase_specific": { ... }
}
```

### #10 phase 耗时统计

**现状**: 脚本自身不记录 duration_seconds。intake 462s / fetch 2min / install 121s / run 88s
是手动从日志估算的。

**方案**: 每个 phase 脚本在开头 `date +%s` 记 START_TS,在落盘时算
`duration_seconds = now - START_TS`,写入 result JSON。

---

## 三、健壮性问题 (P2)

### #3 $INFER_CMD 日志误导

**现状**: run-and-repair 日志打印 `Round X, cmd: python3 -c "..."`,
但实际执行的是 `python3 "$ENTRY_FILE"`。$INFER_CMD 从未被更新。

**方案**: 把 $INFER_CMD 改成 `python3 $ENTRY_FILE`,或者打印 entry_script 的关键内容。

### #5 entry_script 剥离逻辑脆弱

**现状**: `sed '1s/^python3 *-c *["'"'"']//'` 只处理了 `python3 -c "..."` 的开头引号。
如果 entry_script 是 `python3 -c 'print("hello")'`(单引号包裹),也会出错。

**方案**: 用 Python 做 entry_script 剥离(解析命令行参数提取 -c 内容),而不是 sed 正则。

### #6 venv 健康检查前置

**现状**: 只有 run-and-repair 检查 venv 不存在时 FATAL。
install-env 自身失败后 venv 可能半残,但没有前置检查。

**方案**: 在 phase-transition 时(如 install→run 之间)加 venv 健康性检查:
- `venv/bin/python --version` 成功
- `venv/bin/pip list` 能返回结果

### #7 僵尸判定不一致

**现状**: AGENTS.md 说"查 /proc/<pid>/stat 为 Z",但 check-bg-downloads.sh 用
`kill -0`(对僵尸返回 0 = 误判活)。

**方案**: 统一用 `/proc/<pid>/stat` 检测:
```bash
is_pid_alive() {
  local pid=$1
  [ -d "/proc/$pid" ] || return 1
  local stat=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $3}')
  [ "$stat" = "Z" ] && return 1  # 僵尸=死
  return 0
}
```

### #9 state transition guard

**现状**: 靠主 agent 手动 `jq '.phase = "running"'` 更新 state.json。
如果主 agent 跳过了某个 phase,state.json 会出现非法组合。

**方案**: 加 `validate-state-transition.sh`,检查 phase 序列合法性:
```
合法流转: null → fetching → installing → running → verifying → runbook_pending → cleanup_pending → done/archived
```

---

## 四、Cron 调度层面 (P3)

### #11-12 Hermes cron 续跑/配额/preflight

**现状**:
- CC 版 daily.sh 有: flock + 30min 续跑配额(3次/天) + 10min bg_recheck + 15min 异常重试
- Hermes 版: cron job 只是 `daily.sh >> log`,没有续跑机制
- harness-preflight.sh 写好了(0-token 预检),但从未在 cron 流程里被触发

**方案**: 一旦切到 Hermes 版入口(#1):
- preflight.sh 应该是 cron job 的 `script` 参数(Hermes cronjob tool 支持 `--script`)
- 续跑/配额/bg_recheck 逻辑从 CC 版 daily.sh 迁移到 Hermes cron 脚本

---

## 已完成的修复(本轮试跑中)

| 编号 | 修复项 | 文件 | 状态 |
|---|---|---|---|
| P0 | FileNotFoundError 自动路径替换 | phase-run-and-repair.sh | ✅ paddleocr 验证 |
| P1 | install-env 隐式依赖检查(6c import + 6c-2 entry_script 试执行) | phase-install-env.sh | ✅ paddleocr 验证 |
| P1 | PaddlePaddle OneDNN bug 检测+降级修复链 | phase-run-and-repair.sh | ✅ 检测链正确,上游 bug 无法修 |
| bug | venv 不存在时 FATAL 退出 | phase-run-and-repair.sh | ✅ |
| bug | intake 扫描 repo 真实测试文件 | phase-intake.sh | ✅ |
| P3 | crontab 日志分离(cron-scheduler-$(date).log) | crontab | ✅ |

## 已完成的框架完善(本轮开发)

| 编号 | 修复项 | 改动文件 | 状态 |
|---|---|---|---|
| P0 #1 | CC/Hermes 双引擎切换(HERMES_MODE=1) | cron/daily.sh | ✅ |
| P0 #2 | verify/runbook/cleanup phase 脚本(方案A全覆盖) | phase-verify.sh, phase-runbook.sh, phase-cleanup.sh | ✅ 语法通过 |
| P1 #4 | MAX_REPAIR_ROUNDS → EXEC_FAIL_COUNT(修复不耗轮) | phase-run-and-repair.sh | ✅ |
| P1 #8 | result JSON 统一 schema(result-schema.sh) | result-schema.sh | ✅ |
| P1 #10 | phase 耗时统计(duration_seconds) | 全部 phase-*.sh | ✅ |
| P2 #3 | $INFER_CMD 日志修正 → python3 $ENTRY_FILE | phase-run-and-repair.sh | ✅ |
| P2 #5 | entry_script 剥离用 Python shlex | phase-run-and-repair.sh | ✅ |
| P2 #6 | venv 健康检查前置(损坏自动重建) | phase-install-env.sh, phase-verify.sh | ✅ |
| P2 #7 | 僵尸判定一致性(/proc/stat 替代 kill -0) | cron/daily.sh | ✅ |
| P2 #9 | state transition guard 脚本 | validate-state-transition.sh | ✅ |
| P3 #11-12 | Hermes cron job(10:00 agent 自跑 preflight+phases) | Hermes cronjob + crontab 注释旧 CC 条目 | ✅ |

---

## 方案A vs CC 版 对照(验证数据)

| 维度 | CC 版 | Hermes 方案A |
|---|---|---|
| intake | SubAgent 600s 时常超时 | delegate_task 462s / terminal 直跑更快 |
| fetch | SubAgent 越界/Xet 断连 | terminal 前台 ~2min |
| install | SubAgent 600s 硬限,torch 大包装不完 | terminal bg 121s |
| run | SubAgent 33 次 API 调用浪费 600s | terminal bg 88s |
| context 消耗 | ~500K tokens/run | ~3KB (tail + JSON) |
| 僵尸/残留 | pip 死亡不检测 | exit code 即可检测 |
| 日志 | trajectory.json(18KB+ metadata) | phase log + result JSON |
