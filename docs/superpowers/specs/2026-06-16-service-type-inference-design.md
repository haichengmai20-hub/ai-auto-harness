# Design: 服务型推理支持(entry_type=service)

**日期**: 2026-06-16
**范围**: F1 + 依赖簇 F11/F12/F13/F4/F14(framework-issues-cc-complete.md)
**目标**: 让平台能部署「启动后端服务 → 等就绪 → 调 API 推理 → 取结果 → 停服务」类项目(vLLM/Ollama/Gradio/Flask 后端),而不只是 `python3 script.py` 一次性脚本。
**优先级**: CC 版优先(改 intake/run-and-repair/verify/cleanup 四个 SKILL + `scripts/reconcile-sentinels.sh`);Hermes 版同步留后续。

---

## 背景

当前流水线只认 `entry_type=script`:run-and-repair 跑 `timeout python3 entry.py` 一次出结果。khala(Megatron worker+API)、vLLM/Gradio/Flask 后端类项目跑不通 —— 它们需要「后台起服务 → health check → HTTP 推理 → 停服务」。这类在 AI 项目里占比不小,是 khala/SCAIL 失败的根因之一。

## 三个核心决策(brainstorm 拍板)

1. **成功标准 = 真实推理往返**:起服务 → 等就绪 → 发一个真实请求 → 验证返回/产物 → 停服务。理由:verify 的全部哲学就是抓「服务起来 ≠ 推理能跑」的假阳性(同 GPU 0% 利用)。**降级**:infer 实在调不通 → 退「仅就绪」并标低置信(见下 verify_level L0/L1)。
2. **descriptor 由 intake 全包**:intake 产完整 service descriptor(含 best-effort `infer_cmd`),run-and-repair 只执行;请求错当**普通修复轮**处理。理由:run-and-repair 的修复逻辑保持统一(run→错→修→重跑),descriptor 全量落 intake.json 便于审计;intake 推请求不准的风险由 run 的 repair loop 兜底。
3. **后台服务 ephemeral within-run(不跨 cron)**:backend 在单次 agent run 内 `start(bg+PID)→ready→infer→stop`,run-and-repair **return 前必停**(成功/失败/超时都停);cleanup 兜底。理由:本机跑训练(R-HO-1),GPU 珍贵 —— 卡住/孤儿的 GPU 服务跨 cron 留守比「拒绝一个太慢的项目」更坏。启动太慢塞不进 run 预算 → `paused_for_human`,而非保活跨 cron。

## § 1. entry_type schema(intake / F13)

`intake.json` 新增 `entry_type`: `"script"`(默认,现状不变)| `"service"`。

**检测规则**(intake 第 4 步「推断 entry_script」前先判 entry_type):
- repo 含 `run_backend.sh` / `server.py` / `app.py` / `api.py`,**或** README quickstart/代码出现 `vllm serve` / `uvicorn` / `fastapi` / `flask run` / `gradio` 的 `.launch(` / `.serve(` → `service`
- 否则 → `script`
- 注:`estimated_params_b > 30` 仍在更前面被过滤走 api-skeleton,不进 service 判定(service 只针对 ≤30B self-host 候选)

`service` 项目 intake.json 增加 `service` 对象(intake best-effort 全包 + confidence):

```json
"entry_type": "service",
"service": {
  "start_cmd": "bash run_backend.sh --gpus 7",
  "ready_signal": {"type": "http", "url": "http://127.0.0.1:8001/health", "expect_status": 200},
  "port": 8001,
  "infer_cmd": "curl -s -X POST http://127.0.0.1:8001/generate -H 'Content-Type: application/json' -d '{\"text\":\"hello\"}' -o output.wav",
  "output_path": "output.wav",
  "stop_cmd": "bash run_backend.sh stop",
  "confidence": "high|medium|low"
}
```

**字段说明**:
- `ready_signal` 支持两型:
  - `{"type":"http","url":...,"expect_status":200}` —— 轮询 health/任意端点直到返回期望状态码
  - `{"type":"log","pattern":"Uvicorn running|startup complete|Application startup complete"}` —— grep `backend.log` 命中就绪正则(很多服务没 health 端点但会打印 "running on")
  - intake 优先找 http health 端点;找不到则退 log 型,从 README/框架默认(uvicorn/gradio 的标志行)给 pattern
- `port`:抽出来供健康检查 + 冲突检测;README/config hardcode 的端口记在这
- `start_cmd`:GPU 索引已由 intake 按 `gpu_picks[0]` 注入(如 `--gpus 7`);若启动脚本用别的传法(env/config)intake 在 `warnings` 标注
- `stop_cmd`:**可选**。项目有停止命令则填;无则 run/cleanup 直接 kill 登记的 PID
- `confidence`:descriptor 整体置信(README 给全 → high;靠框架默认推 → medium/low),供 run 决定要不要多花修复轮调请求

找不到足够信息组 descriptor(连 start_cmd 都推不出)→ `blocked: ["service_descriptor_incomplete"]` → paused_for_human(同现有 intake 失败处理)。

## § 2. run-and-repair 服务路径(F1 + F4)

`entry_type == "service"` 时走服务分支(否则现状 script 路径,零改动)。

1. **环境**:同第 0 步(含已落地的 F2 `no_proxy=127.0.0.1,localhost`、CUDA_VISIBLE_DEVICES、HF cache)。
2. **启动 backend**(F4 + F14):
   ```bash
   nohup <start_cmd> > "$WORKSPACE/logs/backend.log" 2>&1 &
   echo $! > "$WORKSPACE/.cache/backend.pid"
   # launcher 派生的 worker/api 子进程也登记(F4),供 stop/cleanup 用
   pgrep -f "<backend 进程特征>" >> "$WORKSPACE/.cache/backend.pid" 2>/dev/null || true
   ```
   同时写 `.cache/handoff/service-<id>.json {status:"running", pid, run_id, started_at, log_path}` —— **不为跨 cron 续跑,只为孤儿回收**(见 § 5)。
3. **等就绪**:按 `ready_signal` 轮询 —— http 用 `curl -s -o /dev/null -w '%{http_code}'`(no_proxy 已设)、log 用 `grep -E "$pattern" backend.log`。受 **R4 poll 预算 + 就绪超时**约束(就绪超时按 `estimated_params_b` 分级,复用 Q5 的分级:≤1B 900s … >30B 5400s,但服务通常加载即占大头)。R4.6 动态间隔。
4. **推理**:跑 `infer_cmd`,捕获输出。请求错(HTTP 4xx/5xx / 连接拒绝 / payload 不合法)= **普通修复轮**:LLM 看错误改 payload/endpoint/header 重发,复用 repair 预算 + F9 分类(如 `port_conflict`、连接拒绝→检查 backend.log 是否崩)。
5. **验产物**:`output_path` 存在 + 大小/格式合理(同 script 路径的成功判定;LLM 用 domain knowledge)。
6. **🔴 必停(ephemeral 铁律)**:
   - 有 `stop_cmd` 先跑;再对 `.cache/backend.pid` 里每个 PID `kill` (TERM 等 ~5s → KILL),`/proc/<pid>/stat` 确认死(僵尸=已死,容器 PID1 不收尸)
   - 标 `service-<id>.json` status=stopped,清 `.cache/backend.pid`
   - **成功 / 失败 / 超时三种结局都必须在 return 前执行这一步**
7. **预算耗尽**:超 R3 wall-clock / R4 poll 仍没 ready+infer 完 → **先停 backend** → `paused_for_human`(reason=`service_startup_over_budget`),**绝不** `paused_in_progress`(决策 3:不留跨 cron 服务)。
8. **降级**:ready 达成但 `infer_cmd` 在修复预算内始终调不通 → 停服务 + 在 run.json 记 `ready_achieved:true, infer_succeeded:false`,passed 交给 verify 独立判定(verify 会标 L0,见 § 3)。

run.json 服务相关字段(在现有 schema 基础上加):`entry_type`、`ready_achieved`、`infer_succeeded`、`backend_log_tail`。

## § 3. verify 服务路径(F11)

verify **独立重跑**服务生命周期(不信 run_result,但**允许读** intake.json 的 `service` descriptor —— descriptor 是输入不是修复历史)。

流程:`start(bg+PID) → 等 ready → infer_cmd → 验产物 + GPU 利用 → 必停`(同 § 2 的 ephemeral 纪律,verify 只有 Read+Bash,服务操作全 bash,契合)。

映射到现有 verify.json **7 个固定字段**(不新增顶层字段):
- `failed_at` 取值复用:`"startup"`(start_cmd 起不来 / ready_signal 始终不达成)、`"smoke_test"`(infer_cmd 失败 / 产物不合理)、`"gpu_utilization"`(infer 时 GPU mem<1GB 或 util 全 0)
- **verify_level 承载降级语义**(复用现有 L0/L1):
  - `L0` = 仅就绪达成、推理未验证(decision 1 的降级档)
  - `L1` = 真实推理产物验证通过(完整往返)
- `evidence` 子对象加服务证据:`ready_signal_met`(bool)、`infer_status`(http code 或 exit)、`output_files`、`gpu_stats`

判定:start+ready 不成 → `passed=false, failed_at="startup"`;ready 成但 infer 不成 → `passed=false, failed_at="smoke_test", verify_level="L0"`(就绪但没真跑通);完整往返 + 产物合理 + GPU 真用 → `passed=true, verify_level="L1"`。

## § 4. cleanup 杀后台(F12)

cleanup 在 whitelist rm(第 2 步)**之前**加一步「杀本 workspace 登记的后台进程」:

```bash
# 读 stop_cmd(从 intake.json.service.stop_cmd)先优雅停
# 再遍历 $WORKSPACE/.cache/*.pid:
for pidfile in "$WORKSPACE"/.cache/*.pid; do
  [ -f "$pidfile" ] || continue
  while read -r pid; do
    stat=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [ -z "$stat" ] && continue          # 已死
    [ "$stat" = "Z" ] && continue       # 僵尸=已死(kill -0 会误判活)
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
  done < "$pidfile"
done
```

**R1 铁律**:只杀本 `$WORKSPACE/.cache/*.pid` 登记的 PID,**绝不**碰未登记进程 / 训练 / 别的 workspace。这是成功路径的兜底(run/verify 正常已停)。

注:cleanup 在 verify 没过时可能被 G4 跳过 → 失败路径的孤儿由 § 5 的 preflight 回收兜底。

## § 5. 孤儿安全网(F14 + ephemeral 关键风险缓解)

**风险**:ephemeral 下,若 agent 被 R3 wall-clock(`enforce-wallclock.sh`)或异常杀掉,`nohup` 的 backend 可能孤儿留守占 GPU。

**缓解**:`service-<id>.json` 记 `run_id`,扩 `scripts/reconcile-sentinels.sh`(daily.sh preflight 已调用它)做**孤儿回收**:
- reconcile 在 **preflight 时机**跑 —— 此刻处于两次 run 之间(flock + N=1 保证无活跃 run),所以**任何 `status=running` 的 service sentinel 且其 PID 仍活 = 孤儿**(创建它的上一个 run 必然已死)→ kill 其登记 PID + 标 sentinel `stopped`
- **R1 安全**:只 kill 该 sentinel 对应 workspace `.cache/*.pid` 登记的 PID;判活/判死查 `/proc/<pid>/stat`(僵尸 Z 视为已死,非 kill -0)

这是把 sentinel/reconcile 机制(R10)当**安全网**,**不是续跑机制**(决策 3:服务不跨 cron 续跑,只确保孤儿被收掉)。

## § 6. 横切

- **state**:intake 把 `entry_type` + `service` 写进 `intake_result`;run/verify 读它分支(script 路径完全不受影响)。
- **R9**:主 agent 仍只 dispatch;所有服务操作在 run/verify SubAgent 内。
- **R1**:kill 只动登记 PID。**R3**:就绪超时分级;超预算停服务转人工。**R4.6**:等就绪用动态 poll 间隔。**F2**:no_proxy 已落地(localhost HTTP 不被 Privoxy 拦)。
- **端口**:intake 记 `port`;启动后冲突(`Address already in use`)走 F9 `port_conflict`(改 env 端口或转人工)。
- **R-HO-1**:严禁清理/kill 任何非本 workspace 登记的进程(用户训练)。

## 成功标准 / 验证

| 项 | 验证 |
|---|---|
| script 路径零回归 | 现有 script 项目流程不变(entry_type 缺省=script) |
| 服务往返 | 一个真实服务型项目(vLLM 或 Gradio demo)走完 start→ready→infer→验产物→stop,verify=L1 |
| 必停 | run/verify return 后 `.cache/backend.pid` 的进程全死;无 GPU 残留 |
| 孤儿回收 | 构造 service sentinel(run 已死 + PID 活)→ reconcile-sentinels 杀掉 + 标 stopped |
| 降级 | infer 调不通的服务 → verify=L0,passed=false failed_at=smoke_test,backend 仍被停 |
| R1 | reconcile/cleanup 不碰未登记 PID(fixture:放一个外部 PID,确认不被杀) |

## 不做(本设计明确排除)

- 跨 cron 服务保活/重连(决策 3 排除)
- 多服务编排(单 cron run N=1,一个 backend)
- Hermes 版同步(CC 优先,留后续 batch)
- 流式/WebSocket 推理协议(先做请求-响应型;流式留后续)
- api_skeleton 的 entry_type(>30B 走现有 api-skeleton 路由,不在本设计)
