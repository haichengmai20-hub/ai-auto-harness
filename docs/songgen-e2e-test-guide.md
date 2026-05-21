# SongGeneration E2E 实跑指南(给陪同 AI)

> **任务**:启动一次 ai-auto-harness 真实自动部署测试,目标 SongGen,**跑通**(不是文档练习).
> **你的角色**:启动 worker → 观察 → 卡住就接续 → 成功为止.

---

## 0. 红线(必读,1 分钟)

**不可触碰**:
- `/root/auto-deploy-agent/workspace/fb4944c4334b-SongGeneration/`(横向 baseline)
- `/root/ai-workspace/20260520_110924-songgeneration/`(横向 baseline)
- `~/.cache/huggingface/`(用户的训练 cache,不可读不可写)
- 用户的训练进程

**只能写的位置**:
- `/root/ai-auto-harness/runs/<你的 LOG_DIR>/`
- `/root/ai-auto-harness/workspace/song-generation/`(worker 写,你只读)
- `/root/ai-auto-harness/pending_human/`(worker 写)
- `/root/ai-auto-harness/reports/`(worker 写)

**你不是 worker**:不要在自己 session 跑 `pip install` / `git clone` / `huggingface-cli` — 那是 worker 进程的事.你的工作是**启动 + 观察 + 接续**.

---

## 1. 启动前 6 步硬 preflight(任一不过停)

```bash
# 1.1 GPU 至少 1 卡 free > 28GB
nvidia-smi --query-gpu=index,memory.free --format=csv,noheader,nounits | awk '$2 > 28000 {ok=1} END {exit !ok}' && echo "✓ GPU OK" || { echo "✗ GPU 不够,中止"; exit 1; }

# 1.2 磁盘 free > 80GB
DF_FREE=$(df -BG /root | awk 'NR==2 {print $4}' | tr -d 'G')
[ "$DF_FREE" -gt 80 ] && echo "✓ 磁盘 OK (${DF_FREE}G free)" || { echo "✗ 磁盘不够 (${DF_FREE}G);要 > 80G 中止"; exit 1; }

# 1.3 .env 配置好
test -s /root/ai-auto-harness/.env && echo "✓ .env OK" || { echo "✗ .env 缺失,中止"; exit 1; }

# 1.4 claude-haha 可用
/root/ai-auto-harness/bin/claude-haha --version > /dev/null && echo "✓ claude-haha OK" || { echo "✗ claude-haha 启动失败,中止"; exit 1; }

# 1.5 workspace 干净(残留会让 worker 走接续逻辑而不是 fresh 部署)
if [ -d /root/ai-auto-harness/workspace/song-generation ]; then
  echo "⚠️ 发现残留 workspace/song-generation/,要 fresh 跑就先清"
  # 清理(确认后):
  # rm -rf /root/ai-auto-harness/workspace/song-generation
  # rm -f /root/ai-auto-harness/pending_human/song-generation.md
fi

# 1.6 之前的 pending_human 清理
ls /root/ai-auto-harness/pending_human/song-generation.md 2>/dev/null && {
  echo "⚠️ 有 pending_human/song-generation.md 残留,清掉:"
  # rm /root/ai-auto-harness/pending_human/song-generation.md
}
```

---

## 2. 启动(背景跑,你随时能 monitor)

```bash
LOG_DIR="/root/ai-auto-harness/runs/songgen-e2e-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
echo "LOG_DIR=$LOG_DIR"

# 用 setsid + nohup 让 worker 脱离父进程
setsid nohup bash /root/ai-auto-harness/cron/launch_worker.sh \
  '你的任务是部署 SongGeneration 项目并验证它真能跑.

【硬性要求】调用 auto-deploy skill,严格按 5 阶段流水线:intake → fetch-weights → install-env → run-and-repair → verify.每个阶段都要落盘 logs/<phase>.log 和 results/<phase>.json.

【前置信息(已 scan 过,直接用)】
- 项目: SongGeneration(腾讯 AI Lab 开源音乐生成 4B 模型)
- github_url: https://github.com/tencent-ailab/SongGeneration
- hf_repos: ["lglg666/SongGeneration-Runtime", "lglg666/SongGeneration-v2-large"]
  权重在 lglg666/ 社区镜像,公开 repo 不需 HF_TOKEN
- 总下载: ~28GB(Runtime 15GB + v2-large 13GB)
- 参数量: 4B(过 30B 阈值)
- recommended_route: self_host_5090
- slug: song-generation(有横杠)
- 已知 5090 sm_120 + torch 2.6 有兼容性 quirks,install-env 必跑 torch.cuda.is_available()

【workspace】所有产物落 /root/ai-auto-harness/workspace/song-generation/

【绝对不要】
- 不要复用系统 ~/.cache/huggingface(env 已隔离,但 skill 内 bash 也必须 export $HF_HOME)
- 不要并行 pip(损坏 venv,见 install-env skill 硬规则)
- 不要在 verify 阶段修代码(verify 只判定)
- 不要硬试 > 3 轮(写 pending_human 比硬试好)

【期望耗时】30-90 分钟.fetch 阶段权重 28GB 真下,预计 30-60 分钟.

【完成标志】
- workspace/song-generation/state.json phase=done
- results/verify.json passed=true
- workspace/song-generation/repo/ 下有实际音频输出(*.flac / *.mp3)
- reports/$(date +%Y-%m-%d).md 已生成' \
  "$LOG_DIR" </dev/null >>"$LOG_DIR/wrapper.out" 2>>"$LOG_DIR/wrapper.err" &

WORKER_PID=$!
echo "$WORKER_PID" > "$LOG_DIR/worker.pid"
disown $WORKER_PID 2>/dev/null || true

echo "✅ worker started PID=$WORKER_PID"
echo "   LOG_DIR=$LOG_DIR"
echo "   预计 30-90 分钟"

# 立刻验证 worker 起来了
sleep 8
ps -p $WORKER_PID > /dev/null && echo "✓ 8 秒后仍 alive" || { echo "✗ 8 秒就死了,看 $LOG_DIR/wrapper.err"; cat "$LOG_DIR/wrapper.err"; }
```

---

## 3. 监控(被动等 + 主动报告)

### 3.1 后台 monitor 脚本(每 60 秒检查一次)

```bash
LOG_DIR="<你的 LOG_DIR>"
WS="/root/ai-auto-harness/workspace/song-generation"
PID=$(cat "$LOG_DIR/worker.pid")

# 用 Monitor 工具(若你是 CC 自己),command:
#   PREV_PHASE=""; PREV_FIX=0; PREV_PH=""; ITER=0
#   while kill -0 $PID 2>/dev/null; do
#       ITER=$((ITER+1))
#       # phase 变化
#       CUR=$(jq -r .phase "$WS/state.json" 2>/dev/null || echo "init")
#       [ "$CUR" != "$PREV_PHASE" ] && echo "[$(date +%H:%M)] PHASE → $CUR" && PREV_PHASE="$CUR"
#       # fixes 新增
#       if [ -f "$WS/logs/fixes.log" ]; then
#           CF=$(wc -l < "$WS/logs/fixes.log")
#           [ "$CF" -gt "$PREV_FIX" ] && echo "[$(date +%H:%M)] FIX: $(tail -1 "$WS/logs/fixes.log")" && PREV_FIX=$CF
#       fi
#       # pending_human 出现
#       if ls /root/ai-auto-harness/pending_human/song-generation.md 2>/dev/null; then
#           [ "$PREV_PH" != "1" ] && echo "[$(date +%H:%M)] ⚠️ PENDING_HUMAN 写了 — 看文件" && PREV_PH=1
#       fi
#       # 每 10 轮(10 分钟)给一次 heartbeat,即便没事件
#       [ $((ITER % 10)) -eq 0 ] && echo "[$(date +%H:%M)] heartbeat: phase=$CUR ITER=$ITER"
#       sleep 60
#   done
#   echo "[$(date +%H:%M)] worker exited"
```

### 3.2 给人类用户汇报的频率

**只在以下时刻汇报**(不要每分钟报):
- phase 变化(`null → fetching → installing → running → verifying → done`)
- `fixes.log` 新增(agent 触发了修复)
- `pending_human/song-generation.md` 出现(agent 求救)
- 超过 10 分钟无事件(给一个 heartbeat,免得用户以为卡了)
- worker 退出(成功 / 失败 / 死了)

格式:
```
[10:35] PHASE: null → intake          (开始 clone repo)
[10:38] PHASE: intake → fetching      (intake 完,28GB 下载启动,预计 30-60 分钟)
[11:30] PHASE: fetching → installing  (下完,进入装环境)
[11:42] FIX: 装 torch nightly cu124   (sm_120 不支持 stable,自动修)
[11:45] PHASE: installing → running
[11:50] FIX: batch_size 4 → 1         (CUDA OOM 修复)
[11:55] PHASE: running → verifying
[12:00] PHASE: verifying → done       ✅ 成功!
```

---

## 4. 各阶段预期 + 卡住判定

| 阶段 | 预期耗时 | 卡住信号 | 处理 |
|---|---|---|---|
| intake | 1-3 min | 3 min 后还在 phase=null | 看 wrapper.err / harness.stderr,可能 CC 没起来 |
| fetching | 30-60 min | progress.md 10 min 无变化 + fetch_weights.log 10 min 无新输出 | **耐心等更久**(网络抖动),20 min 后还死 → 看是不是 worker 死了 |
| installing | 5-15 min | install_env.log 5 min 无新输出 + 进程在 wait | 看是不是 pip 卡住,可能 Privoxy 拦了 pypi |
| running | 3-15 min | run_and_repair.log 5 min 无新 + GPU 利用率 0 | 让 worker 自己 retry(它内部 max 3 轮) |
| verifying | 2-5 min | verify.log 5 min 无新 | 检查 worker 是否还活 |

**通用判定卡死**:`kill -0 $PID` 看 worker 是否还活.

---

## 5. 跑死了怎么办(重要 — 这是"跑通"的关键)

### 5.1 worker 进程死了(`kill -0 $PID` 失败)

**先看死前**:
```bash
LOG_DIR="<...>"
tail -50 "$LOG_DIR/harness.stderr.log"      # API 错误 / OOM / panic
tail -100 "$LOG_DIR/harness.stdout.ndjson" | grep -E '"is_error":true|"subtype":"error"'
tail "$LOG_DIR/cron.status"                  # exit code
```

**根据死因**:

| 死因 | 处理 |
|---|---|
| API 401 / token 用完 | 报告用户,等 token 充值 |
| context exceeded(--print 模式上下文爆了) | 见 5.2 接续 |
| OOM / killed | 看 dmesg;workspace 是否完整,可接续 |
| 网络 fatal | 看 ndjson 找具体哪步,重试 |
| stderr 空 + 进程消失 | 看是不是 systemd / OOM killer.尝试接续 |

### 5.2 接续 — worker 死了但已经下了部分权重(关键场景)

`workspace/song-generation/state.json` 还在,phase 显示半途:

```bash
WS="/root/ai-auto-harness/workspace/song-generation"
cat "$WS/state.json" | jq '{phase, phases_done}'
# 例:phase=fetching, phases_done=[intake]
```

**直接重启 worker**(workspace 保留,state.json 让它接续):

```bash
NEW_LOG_DIR="/root/ai-auto-harness/runs/songgen-e2e-resume-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$NEW_LOG_DIR"

setsid nohup bash /root/ai-auto-harness/cron/launch_worker.sh \
  '继续之前未完成的 SongGeneration 部署.

【关键】workspace/song-generation/state.json 已存在,phase 显示在哪个阶段被中断,**调 auto-recover skill 接续**(不要 auto-deploy 重头来,那会重下 28GB).

【前置信息】(同前置,这里省略,但 worker 应该从 state.json 读到)

【完成标志】state.json phase=done + verify.json passed=true' \
  "$NEW_LOG_DIR" </dev/null >>"$NEW_LOG_DIR/wrapper.out" 2>>"$NEW_LOG_DIR/wrapper.err" &
```

worker 看到 state.phase=fetching → 调 fetch-weights skill → skill 内读 state.fetch_state → resume 已下载部分.

### 5.3 fetch 卡住但 worker 还活

`huggingface-cli download` 是 background bash 跑的,worker 可能在 poll BashOutput.让它自己处理(skill 里有"30min 无增长 → kill 重启 max 2 次").

**只有等待 30 分钟以上还死锁** 才介入:`tail $WS/logs/fetch_weights.log` 看具体 repo + 找 `.incomplete` 文件验证是不是真的没动.

### 5.4 pending_human 写了(agent 求救)

```bash
cat /root/ai-auto-harness/pending_human/song-generation.md
```

按文件里"建议人手做的事"做 → 删 pending_human 文件 → 5.2 接续.

---

## 6. 成功判定(都满足才算)

```bash
WS="/root/ai-auto-harness/workspace/song-generation"

# 1. state.phase = done
jq -e '.phase == "done"' "$WS/state.json"

# 2. run + verify 都 passed
jq -e '.passed == true' "$WS/results/run.json"
jq -e '.passed == true' "$WS/results/verify.json"

# 3. 真实音频输出存在
find "$WS/repo" -name "*.flac" -o -name "*.mp3" -o -name "*.wav" | head -5
# 任一文件大小 > 100KB → 真的输出了音频

# 4. 报告生成
ls /root/ai-auto-harness/reports/$(date +%Y-%m-%d).md

# 5. trajectory.json 显示完整流程
jq '.[] | .name' "$LOG_DIR/trajectory.json" | sort -u
# 应该看到 Skill / Bash / Read / Edit / Write 等
```

5 项都过 → 跑通了,汇报用户.

---

## 7. 跑完汇报模板

```markdown
## ✅ SongGen E2E 测试成功

**LOG_DIR**: <路径>
**总耗时**: <H 小时 M 分钟>
**总 API 成本**: <$X,从 result.json total_cost_usd 抽>

### 阶段汇总
| 阶段 | 状态 | 耗时 | 关键事件 |
|---|---|---|---|
| intake | ✅ | Xmin | entry_script=..., hf_deps=[...] |
| fetch | ✅ | Xmin | 实际下载 X GB(Runtime + v2-large) |
| install | ✅ | Xmin | torch X.Y.Z+cuXXX,sm_120 兼容 |
| run | ✅ | Xmin | 修复 N 轮,fixes=[...] |
| verify | ✅ | Xmin | GPU 利用 X%,生成音频文件 |

### 实际输出
- 音频文件: <path>(大小 / 时长)
- 公司视角报告: reports/<date>.md(摘几行高亮)

### 横向对比(若你能看 baseline 的话)
- 5/20 auto-deploy-agent: 3 小时(fetch 3h)
- 5/20 纯 claudecode-haha-harness: <参考 ai-workspace/20260520_110924>
- 本次 ai-auto-harness: <我们的耗时>

### 异常 / 改进
<列你观察到的>
```

---

## 8. 不可作弊检查(跑完用户会验)

```bash
# A. cache 确实隔离了
ls /root/ai-auto-harness/runs/songgen-e2e-*/.cache/huggingface/hub/ 2>/dev/null
# 应该看到 models--lglg666--SongGeneration-* 在我们的隔离 cache 里,不是系统 cache

# B. 真的下载了 28GB 而不是软链接
du -sh /root/ai-auto-harness/workspace/song-generation/.cache/hf_models/ 2>/dev/null
du -sh /root/ai-auto-harness/runs/songgen-e2e-*/.cache/huggingface/ 2>/dev/null
# 总和应该接近 28GB

# C. workspace 内的 venv 是新的(不复用其他位置的)
ls /root/ai-auto-harness/workspace/song-generation/venv/bin/python && \
  echo "OK 独立 venv" || echo "FAIL"
```

---

## 9. 一句话目标

**不要做完美主义,做完成主义** — 跑通比跑漂亮重要.

第一次跑失败不丢人,**5.2 接续协议**就是为此设计的.关键是:
- 不要 panic kill
- 不要重头来(workspace 保留 + state.json 接续)
- worker 内部 3 轮上限是设计 — 触发 pending_human 不是失败,是优雅退出 → 处理 → 接续

加油.跑通后给用户一份汇报.
