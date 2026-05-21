# SongGeneration 自动部署 E2E 测试指南(给另一个 AI)

> **你的任务**:启动一次 ai-auto-harness 的完整自动部署测试,目标项目是 SongGeneration,陪同人类用户观察整个过程(预计 30-90 分钟),最后产出公司视角建议报告.

---

## 一、你是谁 / 你不是谁

**你是**:陪人观察的"副驾驶".
- 你的工作:启动 worker,然后**只读** worker 落盘的产物,把关键事件汇报给人类用户.
- 你**不修改** worker workspace 内任何文件(不动 repo / 不动 venv / 不动权重 / 不改 state.json).

**你不是**:做部署决策的 worker.
- worker 是独立的 `claude-haha --print` 进程,它自己跑 intake / fetch-weights / install-env / run-and-repair / verify 5 阶段 SubAgent.
- LLM 修复决策**完全由 worker 内部独立完成**,你**不许**通过任何方式介入它的决策.

---

## 二、红线(绝不能踩)

| # | 红线 | 说明 |
|---|---|---|
| 1 | 不动 `/root/auto-deploy-agent/workspace/fb4944c4334b-SongGeneration/` | 那是 auto-deploy-agent 方案的输出,横向对比基线 |
| 2 | 不动 `/root/ai-workspace/20260520_110924-songgeneration/` | 那是纯 claudecode-haha-harness 方案的输出,另一个横向对比基线 |
| 3 | 不动 `/root/auto-deploy-agent/` 下任何项目目录(它在 deprecated) | |
| 4 | 不动用户的训练进程 / GPU(若 GPU 被占,worker 自己会 raise pending_human) | |
| 5 | 不读 `~/.cache/huggingface/` 或系统其他 cache 看里面权重(那会"作弊" — 跳过真实下载) | |
| 6 | 不要在 worker 内部 prompt 里"灌输"决策(比如"你应该用 nightly torch")— 让 worker 自己探 | |

**只允许**写入的位置:
- `/root/ai-auto-harness/runs/<你启动的 LOG_DIR>/`(你自己创建)
- `/root/ai-auto-harness/workspace/song-generation/`(worker 写,你只读)
- `/root/ai-auto-harness/reports/<date>.md`(worker 写)
- `/root/ai-auto-harness/memory/lessons/*.md`(worker 写)
- `/root/ai-auto-harness/pending_human/*.md`(worker 写)

---

## 三、启动前自检(5 项,跑前必看)

```bash
# 1. GPU 资源(全部 8 卡空闲 OR 至少 1 卡 free > 28GB)
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader
# 预期:每卡 used < 25000 MiB(我们 preflight 阈值),否则 worker 会写 pending_human 退出

# 2. 磁盘 free > 80GB(SongGen ~28GB + venv ~5GB + 50GB safety)
df -h /root | tail -1
# 当前已知:309GB free,够用但偏紧

# 3. 我们 workspace 是空的(没有残留)
ls /root/ai-auto-harness/workspace/
# 预期:空目录 OR 只有 song-generation/ 不存在

# 4. .env 配好(API key + 可选 HF_TOKEN)
ls /root/ai-auto-harness/.env
test -s /root/ai-auto-harness/.env && echo "OK"

# 5. claude-haha 可用
/root/ai-auto-harness/bin/claude-haha --version
# 预期:输出 "999.0.0-local (Claude Code)"
```

任一项失败 → 报告人类用户,停止;不要硬试.

---

## 四、启动命令(完整,直接复制跑)

```bash
LOG_DIR="/root/ai-auto-harness/runs/songgen-e2e-$(date +%Y%m%d-%H%M%S)"
echo "LOG_DIR=$LOG_DIR"

bash /root/ai-auto-harness/cron/launch_worker.sh \
  '请使用 auto-deploy skill 部署 SongGeneration 项目。下面是完整前置信息(无需重新 scan,直接用这些参数):

项目:SongGeneration(腾讯 AI Lab 开源音乐生成大模型 v2-large,4B 参数)
- github_url: https://github.com/tencent-ailab/SongGeneration
- hf_repos: ["lglg666/SongGeneration-Runtime", "lglg666/SongGeneration-v2-large"]
  (注:权重在 lglg666/ 社区镜像,不是 tencent/。是公开 repo,无需 HF_TOKEN)
- 估算下载: 28GB (Runtime ~15GB ckpt+third_party + v2-large ~13GB)
- 估算参数: 4B(过 30B 阈值)
- scenario_hits: scenario_005(AI 音乐音频)
- recommended_route: self_host_5090
- 已知 sm_120 + torch 2.6 兼容性 quirks,intake/install 阶段需 verify torch.cuda.is_available()

要求:
1. slug 用 "song-generation"(有横杠)
2. 所有产物落到 /root/ai-auto-harness/workspace/song-generation/
3. 完整走 5 阶段流水线:intake → fetch-weights → install-env → run-and-repair → verify
4. 每阶段产 workspace/song-generation/logs/<phase>.log 和 results/<phase>.json
5. fetch-weights 必须真实下载 28GB(env 已经把 HF_HOME 隔离了,不会复用系统 cache)
6. run-and-repair 修复上限 3 轮,3 轮收敛不了写 pending_human/song-generation.md
7. 5 阶段都过后写 reports/$(date +%Y-%m-%d).md 给出公司视角建议' \
  "$LOG_DIR"
```

**重要**:这个命令会**前台阻塞**直到 worker 退出(预计 30-90 分钟).

**两种启动姿势**(选一个):

### A. 前台跑(你自己等)
直接跑上面的命令,你阻塞 30-90 分钟,期间你的 CC session 不能做别的事.

### B. 后台跑 + 周期观察(推荐)
```bash
LOG_DIR="/root/ai-auto-harness/runs/songgen-e2e-$(date +%Y%m%d-%H%M%S)"
setsid nohup bash /root/ai-auto-harness/cron/launch_worker.sh \
  '<同上完整 prompt>' \
  "$LOG_DIR" </dev/null >>"$LOG_DIR/wrapper.out" 2>>"$LOG_DIR/wrapper.err" &
WORKER_PID=$!
echo "$WORKER_PID" > "$LOG_DIR/worker.pid"
disown $WORKER_PID 2>/dev/null || true
echo "worker started PID=$WORKER_PID, log_dir=$LOG_DIR"

# 然后用 Monitor 工具或周期 tail 观察(见下节)
```

---

## 五、实时监控(你陪人观察的核心活)

跑起来后,周期看以下文件,把关键事件**摘要**汇报给人类用户.**不要原文 dump 几百行 log**,要摘要.

### 5.1 监控用的 Monitor 命令(推荐)

```bash
LOG_DIR="<你的 LOG_DIR>"
WS="/root/ai-auto-harness/workspace/song-generation"

# Monitor 60-180s poll,事件来通知
PREV_PHASE=""; PREV_FIXES=0; PREV_PH=""
while kill -0 $(cat "$LOG_DIR/worker.pid") 2>/dev/null; do
    # phase 变化
    CUR_PHASE=$(jq -r .phase "$WS/state.json" 2>/dev/null || echo "<no-state>")
    [ "$CUR_PHASE" != "$PREV_PHASE" ] && echo "[$(date +%H:%M)] PHASE: $PREV_PHASE → $CUR_PHASE" && PREV_PHASE="$CUR_PHASE"
    # fixes.log 新增
    [ -f "$WS/logs/fixes.log" ] && CUR_FIX=$(wc -l < "$WS/logs/fixes.log") && \
      [ "$CUR_FIX" -gt "$PREV_FIXES" ] && \
      echo "[$(date +%H:%M)] FIX: $(tail -1 $WS/logs/fixes.log)" && PREV_FIXES=$CUR_FIX
    # pending_human 出现
    [ -d /root/ai-auto-harness/pending_human ] && CUR_PH=$(ls /root/ai-auto-harness/pending_human/*.md 2>/dev/null) && \
      [ "$CUR_PH" != "$PREV_PH" ] && [ -n "$CUR_PH" ] && \
      echo "[$(date +%H:%M)] ⚠️ PENDING_HUMAN: $CUR_PH" && PREV_PH="$CUR_PH"
    sleep 60
done
echo "[$(date +%H:%M)] worker exited"
```

### 5.2 阶段汇报模板

每个 phase 转换时,给人类用户报告一次,**不要每分钟都报**(那是噪声).

```
[10:35] PHASE: null → intake
        intake 启动,worker 正在 git clone SongGeneration repo

[10:38] PHASE: intake → fetching
        intake 完成,results/intake.json 已落盘:entry_script="...", hf_deps=[...]
        现在进入权重下载,28GB,预计 30-60 分钟

[10:45] (fetch 进度)
        fetch_weights.log 显示下到 ~5GB / 28GB,~18%

[11:30] PHASE: fetching → installing
        权重下载完(花 52 分钟),进入 venv + pip 装环境

[11:42] PHASE: installing → running
        install 完(torch 2.6.0+cu124,sm_120 兼容性问题用 nightly 修了),进入跑

[11:50] FIX: 2026-05-21T11:50 round=1 error=CUDA_OOM fix=batch_size_4_to_1
        run-and-repair 第 1 轮 OOM,改 batch_size,重试

[11:55] PHASE: running → verifying
        run 通过(第 2 轮),输出 sample/output/audio_001.mp3 4.2MB

[12:00] PHASE: verifying → done
        ✅ verify 通过,GPU 利用 87%,生成音频文件合理
        总耗时 85 分钟

[12:01] reports/2026-05-21.md 已生成 + ai-daily-scan outcomes 已回填
```

### 5.3 长时间没动静的处理

如果某个 phase 卡住超过预期(比如 fetch 卡 60 分钟 + 进度不动):
- **第一步**:tail `workspace/song-generation/logs/fetch_weights.log` 看是不是网络断了
- **第二步**:看 worker 进程是否还活:`kill -0 $(cat $LOG_DIR/worker.pid)`
- **第三步**:看 worker session 的 `runs/<id>/transcript.jsonl` 最后一条事件时间
- 都正常 → 是真在下载,继续等(28GB 慢下载可能 90 分钟)
- 进程死了 → 看 `harness.stderr.log` 找原因,**汇报给人类用户决定怎么处理**(不要自己重启)

---

## 六、产物对照表(跑完看哪儿)

| 你想看的 | 路径 |
|---|---|
| harness 完整交互轨迹 | `$LOG_DIR/harness.stdout.ndjson` |
| harness 关键事件摘要 | `$LOG_DIR/trajectory.json` |
| git clone 过程 | `$WS/logs/intake.log` |
| HF 权重拉取日志 | `$WS/logs/fetch_weights.log` |
| 权重元数据 | `$WS/results/weights.json` |
| 环境安装日志 | `$WS/logs/install_env.log` |
| GPU/torch 部署快照 | `$WS/results/environment.json` |
| 跑 test 过程 | `$WS/logs/run_and_repair.log` |
| 修复轨迹 | `$WS/logs/fixes.log` |
| 跑出来的结果 | `$WS/results/run.json` |
| 独立判定 | `$WS/results/verify.json` |
| 实际音频输出 | `$WS/repo/sample/output/*.mp3` |
| 公司视角建议日报 | `/root/ai-auto-harness/reports/<date>.md` |
| 跨日 outcomes 回填 | `/root/ai-daily-scan/state/outcomes.jsonl` |

(WS = `/root/ai-auto-harness/workspace/song-generation`)

---

## 七、成功 / 失败判定

### ✅ 成功
- `workspace/song-generation/state.json` 的 `phase` = `done`
- `results/run.json` `passed=true`
- `results/verify.json` `passed=true`
- `workspace/song-generation/repo/sample/output/` 下有 `.mp3` 或 `.flac` 文件
- `reports/<date>.md` 生成且包含 SongGen 段

### ⚠️ 部分失败(可接受,看 baseline 对比)
- `verify.json` `passed=false, failed_at=gpu_utilization` — 跑了但 GPU 利用率低
- `run.json` `passed=true` 但 verify 不过 — runner 自认通过 verify 不认

### ❌ 失败
- `workspace/song-generation/state.json` 的 `phase` = `paused_for_human`
- `/root/ai-auto-harness/pending_human/song-generation.md` 出现
- 不汇总成"失败" → 是 agent 优雅退出,**写人手处理建议**.汇报给用户 → 让用户读那个文件决定怎么做.

### ☠️ 真挂了
- worker.pid 死了但 `state.json` 还在 in-progress 阶段
- `harness.stderr.log` 有 fatal error
- 汇报全文给人类用户.**不要自己重启**.

---

## 八、跑完汇报模板(给人类用户)

```markdown
## SongGen e2e 部署测试报告

**run-id**: <LOG_DIR 路径>
**总耗时**: <分钟>
**最终状态**: ✅ 成功 / ⚠️ 部分成功 / ❌ pending_human / ☠️ 进程死

### 5 阶段进展

| 阶段 | 状态 | 耗时 | 关键事件 |
|---|---|---|---|
| intake | ✅ | 3min | clone OK,识别 entry_script=... |
| fetch-weights | ✅ | 52min | 下完 28GB(Runtime 15GB + v2-large 13GB) |
| install-env | ✅ | 12min | venv + torch 2.6.0+cu124,sm_120 verify 通过 |
| run-and-repair | ✅ | 5min | 修了 1 轮(CUDA OOM → batch_size 4→1) |
| verify | ✅ | 3min | smoke test 通过,GPU 87% 利用率 |

### 产物清单
- 实际音频: `<path>` (大小 / 时长 / 采样率)
- 报告: `reports/<date>.md`
- agent 轨迹: `<LOG_DIR>/trajectory.json`(N 个关键事件)

### 与 baseline 横向对比(可选)
- vs `auto-deploy-agent` (5/19): 我们多了独立 verify SubAgent 判定
- vs 纯 `claudecode-haha-harness` (5/20): 我们的 LLM 修复次数 N,他们 M

### API token 成本
- `result.json` 里的 `total_cost_usd` * 8 turns 估算

### 异常 / 待优化点
<列你观察到的问题>
```

---

## 九、清理建议(跑完后)

```bash
# 如果跑成功 + 你确认数据已 review,workspace 可保留作横向对比基线
# 不要立刻删 workspace/song-generation/(里面 28GB 权重 + venv,作为 baseline 价值高)

# 如果跑失败 + 想重跑:
# 1. 看 pending_human/song-generation.md 的"建议人手做的事"
# 2. 按指引处理(如配 HF_TOKEN / 装 deps)
# 3. 删 pending_human/song-generation.md
# 4. 再跑 launch_worker.sh,worker 会从 state.json 接续(不会重头下权重)
```

---

## 十、常见问题 / 已知陷阱

| 问题 | 原因 | 处理 |
|---|---|---|
| worker 启动几秒就退出,ndjson 空 | 用了 `--bare` 跳过了 skill | 用 `cron/launch_worker.sh` 正确启动姿势(IS_SANDBOX + dangerously-skip-permissions) |
| worker 启动后 30 分钟"完成"下载 | 复用了系统 `~/.cache/huggingface` | env 隔离已在 launch_worker.sh 修复;若仍发生,检查 ndjson 里 LLM 用的 HF_HOME 是不是隔离路径 |
| install-env 装完 torch 但 cuda_available=False | sm_120 wheel 没找对 | worker skill 第 0.5 步 GPU pre-flight 应该捕获;若没,看 `install_env.log` 找 root cause |
| run-and-repair 跑了 3 轮还在试 | skill 上限规则没生效 | 强制 kill worker.pid + 汇报给用户 |
| 跑得很慢但没卡 | 28GB 真下载就是慢 | 等;tail fetch_weights.log 确认在动 |

---

**结束**:跑完后所有产物路径写入汇报,人类用户来审 + 决定是否合并到 baseline 对比报告.
