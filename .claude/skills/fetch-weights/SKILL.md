---
name: fetch-weights
description: 拉 HF 权重 — background bash + BashOutput poll + 跨 cron 接续
allowed-tools: [Read, Write, Bash, BashOutput, KillBash]
agent: fetch-agent
---

# fetch-weights

## 🔴 硬规则(违反 = 跑挂 / 作弊)

参见项目级 `/root/ai-auto-harness/.claude/CLAUDE.md` R1-R7。本 skill 关键复述:

1. **只下,不装**:本 phase 严禁起任何 `pip install` / venv 创建,带宽给下载用(R5)
2. **`hf` 不是 `huggingface-cli`**:后者已废弃,统一用 `hf download ... --token "$HF_TOKEN"`(R7)
3. **HF_TOKEN 必须显式传**:不要靠 env 默认捡,`--token "$HF_TOKEN"` 显式写在命令里
4. **HF_HUB_ENABLE_HF_TRANSFER=1**:加速到 ~200MB/s(不开默认 ~10-20MB/s,28GB 要下 40min vs 4min)
5. **foreground sleep ≤ 60s/次**(R4):长等用 `setsid nohup ... &` 后台 + tail log + `kill -0 $PID` 判活
6. **state.json 每 phase 起止双写**(R2):本 skill 开头写 `phase=fetching, status=running`,return 前写 `status=done`
7. **wall-clock 上限 180min**(R3):超过且进度 < 50% → `paused_for_human`;> 50% → `paused_in_progress`,下次 cron 接续

## 落盘约定(必读)

- **日志**:`$WORKSPACE/logs/fetch_weights.log` — `hf download` 全输出 + poll 摘要 append
- **进度摘要**:`$WORKSPACE/progress.md`(人读,每次 poll 写一行)
- **结果**:`$WORKSPACE/results/fetch.json` 和 `$WORKSPACE/results/weights.json`(权重元数据)
- 旧约定 `progress_<repo>.log` 被废弃,改用统一的 `logs/fetch_weights.log`

```bash
mkdir -p "$WORKSPACE/logs" "$WORKSPACE/results"
LOG="$WORKSPACE/logs/fetch_weights.log"
echo "==== fetch-weights start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=fetch-weights slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "hf_repos": ["..."],
  "gated_repos": ["..."],
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "run_id": "<from 主 agent>"
}
```

## 第 0 步:环境变量 + token 校验(每次跑 bash 前)

```bash
# launch_worker.sh 已 env-level 设了 HF_HOME / HF_HUB_CACHE / TRANSFORMERS_CACHE,
# 但每次新开 bash 重新 export 一遍是好习惯(防止某些边角 case)
export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$WORKSPACE/.cache/hf_hub}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$WORKSPACE/.cache/transformers}"

# 加速:开 hf_transfer rust 后端,~200MB/s vs 默认 ~10-20MB/s
export HF_HUB_ENABLE_HF_TRANSFER=1

# token 校验 — 没 token 会限速到 ~0.3MB/s,28GB 要下 26 小时
if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: HF_TOKEN 未传入。launch_worker.sh 应从 .env 注入。" >> "$LOG"
    # 调 request-human-intervention,reason=hf_token_missing
    exit 1
fi

# 装 hf_transfer(若未装,首次跑需要),`hf` 命令在新版 huggingface_hub 自带
pip install -U "huggingface_hub[hf_transfer]" 2>&1 | tee -a "$LOG"
```

**强制**:每次 `hf download` 前都必须 export 上面 4 个 + 显式 `--token "$HF_TOKEN"`。

## 第 1 步:读 state.json,判断接续模式

```bash
# 已下完的 repo 跳过
DONE=$(jq -r '.fetch_state.weights_done // [] | .[]' "$WORKSPACE/state.json")
PENDING=$(jq -r '.fetch_state.weights_pending // [] | .[]' "$WORKSPACE/state.json")
BG_SHELLS=$(jq -c '.fetch_state.bg_shells // []' "$WORKSPACE/state.json")
```

**如果 state.fetch_state.bg_shells 非空**:
- 用 BashOutput(shell_id) 看是否还活着(CC 的 shell_id 是 session 内句柄,session 重启后失效;此时用 `ps -p $PID` 或 `kill -0 $PID` 看 OS 进程是否还在)
- 进程活着 + 文件还在长 → 直接跳到第 3 步 poll
- 进程死了 + 文件未完 → 第 2 步用 `--resume-download` 重启
- 进程死了 + 文件已完 → 标 done,看下一个 repo

**如果 state.fetch_state 空 OR weights_pending 全空**:
- 初始化 `state.fetch_state = {weights_done: [], weights_pending: <主 agent 传入的 hf_repos>, bg_shells: []}`

## 第 2 步:启动 background 下载(用 `hf`,不要 `huggingface-cli`)

对每个 PENDING repo(**串行**,不要并行多 repo 抢带宽):

```bash
REPO="<repo>"
DEST="$WORKSPACE/.cache/hf_models/$REPO"
mkdir -p "$DEST"

# 用 setsid + nohup 双重保险脱离 parent process group
setsid nohup bash -c "
  export HF_HUB_ENABLE_HF_TRANSFER=1
  echo '==== fetching $REPO at \$(date -Iseconds) ====' >> '$WORKSPACE/logs/fetch_weights.log'
  hf download '$REPO' \
      --local-dir '$DEST' \
      --token '$HF_TOKEN' \
      --resume-download 2>&1
" >> "$WORKSPACE/logs/fetch_weights.log" 2>&1 &
PID=$!
echo $PID > "$WORKSPACE/.cache/$(basename $REPO).pid"
echo "Started $REPO as PID=$PID" | tee -a "$LOG"
```

**禁止**:
- ❌ `huggingface-cli download`(已废弃,有 warning,且不支持 hf_transfer 加速)
- ❌ `python -c "from huggingface_hub import snapshot_download; snapshot_download(...)"` in **foreground**(阻塞 LLM turn,且 LLM 没法 poll)
- ❌ `kill <pid>` 任何不是从本 PID 文件 `$WORKSPACE/.cache/*.pid` 出来的进程(R1:不动别人 workspace 的进程)

通过 CC `Bash(run_in_background=true)` 调用,记录 shell_id.

**立即更新 state.json**:
```bash
jq --arg shell "$SHELL_ID" --arg pid "$PID" --arg repo "<repo>" --arg ts "$(date -Iseconds)" \
   '.fetch_state.bg_shells += [{id: $shell, pid: ($pid | tonumber), repo: $repo, started_at: $ts, log_path: ("progress_" + $repo + ".log")}]' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

## 第 3 步:Poll 循环(**不 sleep loop,8 turn 上限**)

**核心反模式提醒**(R4 全条):
- ❌ **连续 sleep 绝对禁**(R4.2):上一 turn 是 sleep,这一 turn 不许 sleep。run2 实测连续 sleep 600 × 4 = 40min 烧 4 个 turn 干 0 件事
- ❌ 单次 `sleep > 60s` 禁(R4.1)
- ❌ poll 累计 > 8 个 turn 禁(R4.5),超过即 `paused_in_progress` return

正确 poll:

- 每个 turn 调一次 `tail -50 $WORKSPACE/logs/fetch_weights.log` + `kill -0 $PID && echo alive` + `du -sh $DEST`
- **不 sleep,直接 tail**;bg 进程是 nohup + setsid 起的,LLM 退出/休眠不影响下载
- 真要等带宽刷新:**单个** sleep ≤ 60s,**只能一次,下次必须做别的**
- **8 turn 后还没下完**(28GB 下到 < 50%) → 写 `paused_in_progress=true` + state.json 更新 + return,让下次 cron 接续。**比硬等划算 1000 倍**(cron 接续 = 0 token,sleep loop = 每 turn full-context)

```bash
PID=$(cat "$WORKSPACE/.cache/<repo>.pid")
if kill -0 $PID 2>/dev/null; then
    STATUS="alive"
else
    STATUS="dead"
fi
SIZE=$(du -sb "$DEST" 2>/dev/null | awk '{print $1}')
echo "$(date -Iseconds) PID=$PID status=$STATUS size=$SIZE" >> "$WORKSPACE/progress.md"
tail -30 "$WORKSPACE/logs/fetch_weights.log"
```

每次 poll 做的事:

1. **进度估算**:`du -sb $DEST` 拿当前字节数 / 预估总 size,算百分比
2. **写 progress.md**:`- 2026-05-19T10:42 — fetching <repo>: 12.3GB / 23GB (53%), PID=12345 alive`
3. **磁盘检查**:`df -h "$WORKSPACE"` 看 free,< 30GB → KillBash 本 run 的 PID + 报告 disk_low(R1:**只杀本 PID 文件里的**)
4. **`.incomplete` 文件大小变化检查**:`ls -la "$DEST"/*.incomplete 2>/dev/null`,记录每次 size,若 30min 无变化 → 卡了

## 第 4 步:卡死判定 + 重启

如果 `.incomplete` 30min 无增长 + log 30min 无新输出:
- KillBash(shell_id) 杀 bg
- `rm "$WORKSPACE/.cache/hf_models/<repo>"/*.incomplete` 删坏的临时文件(huggingface-cli resume 会重建)
- 第 2 步重启(同 repo,带 `--resume-download`,会从已 cache 的文件接着下)
- 重启 max 2 次,仍卡 → `blocked.append("download_stuck:" + repo)` 调 request-human-intervention

## 第 5 步:时间预算判定(跨 cron 接续核心)

```bash
# 主 agent 启动 → 现在多久了
META_START=$(jq -r .started_at "runs/$RUN_ID/meta.json")
ELAPSED_SEC=$(( $(date +%s) - $(date -d "$META_START" +%s) ))
```

如果 ELAPSED_SEC > 3000(50 分钟)且当前下载进度 < 80%:
- **不 kill bg shell**(让它继续在后台,nohup + setsid 确保 CC 退出后仍跑)
- 更新 state.json `paused_in_progress=true`
- return `{"weights_done": [...], "paused_in_progress": true}`
- 主 agent 跳到任务 4 写报告"in progress",**下次 cron 接续**

## 第 6 步:Gated 二次拦截

若运行时遇到 401(intake preflight 漏检了):
- KillBash(shell_id)
- 调 **request-human-intervention** skill,reason_category=`auth_missing`,what_blocked=`gated repo <repo> 需要 HF_TOKEN + license 同意`
- return `{"blocked": true, "paused_for_human": true}`

## 第 7 步:全部完成 + 建 symlink 到 README 要求的相对路径

每个 repo 下完(进度 100% + .incomplete 消失 + 退出 0):
- 移到 weights_done
- 从 weights_pending 移除
- 更新 state.json

### 7.5 建 symlink(关键 — 不然 inference 找不到权重)

读 `$WORKSPACE/results/intake.json.weight_target_paths`,对每个映射建 symlink:

```bash
INTAKE="$WORKSPACE/results/intake.json"
jq -r '.weight_target_paths // [] | .[] | "\(.hf_repo) \(.target_rel)"' "$INTAKE" | while read REPO TARGET_REL; do
    SRC="$WORKSPACE/.cache/hf_models/$REPO"
    DST="$WORKSPACE/repo/$TARGET_REL"
    mkdir -p "$(dirname "$DST")"
    # 若 DST 已存在(repo 自带空 dir),先删掉再 ln
    if [ -e "$DST" ] && [ ! -L "$DST" ]; then
        echo "WARN: $DST exists as real dir, renaming to $DST.bak" | tee -a "$LOG"
        mv "$DST" "$DST.bak"
    fi
    ln -sfn "$SRC" "$DST"
    echo "symlink: $DST → $SRC" | tee -a "$LOG"
done
```

若 `weight_target_paths` 为空(intake 没找出来) → 写 `results/fetch.json.warnings += ["symlink_skipped: no target paths"]`,但**不** block;run-and-repair 跑 entry_script 时若 file-not-found,LLM 会自己看 stderr 找路径。

## 第 8 步:return 前落盘 results JSON

```bash
# results/fetch.json — fetch 阶段总结
cat > "$WORKSPACE/results/fetch.json" <<JSON
{
  "weights_done": [...],
  "failed": [],
  "paused_in_progress": <true|false>,
  "bytes_total": <int>,
  "completed_at": "$(date -Iseconds)"
}
JSON

# results/weights.json — 权重元数据(便于事后核查每个 repo 下了多久 / 多大)
cat > "$WORKSPACE/results/weights.json" <<JSON
{
  "repos": [
    {
      "repo": "tencent/SongGeneration",
      "local_dir": "$WORKSPACE/.cache/hf_models/tencent/SongGeneration",
      "bytes": <int>,
      "started_at": "<from state.fetch_state>",
      "completed_at": "$(date -Iseconds)",
      "resumed": <true|false>,
      "resume_count": <int>
    }
  ]
}
JSON

echo "==== fetch-weights end at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_END   phase=fetch-weights slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

全部 done → return:

```json
{
  "weights_done": ["org/repo1", "org/repo2"],
  "failed": [],
  "paused_in_progress": false,
  "bytes_total": 12345678901
}
```

## 返回 schema 完整版

```json
{
  "weights_done": ["..."],
  "failed": [{"repo": "...", "error_class": "stuck|network|gated|other", "msg": "..."}],
  "paused_in_progress": false,
  "blocked": false,
  "paused_for_human": false,
  "bytes_total": 0
}
```

## 反模式总结

- ❌ 不要用 `Bash(timeout=600)` 跑下载 — 长任务必须 background
- ❌ 不要 `rm -rf .cache` — 用 `--resume-download` 继续
- ❌ 不要 wait 一个 bg shell — poll
- ❌ 不要不 export `HF_HOME` 等就跑下载 — 会污染 ~/.cache/huggingface
- ❌ 不要在 cron 快到时间但还在下时 kill 进程 — 让它后台继续
- ❌ **不要用 `huggingface-cli`** — 已废弃,无 hf_transfer 加速,统一用 `hf`
- ❌ **不要 `--token` 留空** — 没 token 限速到 0.3MB/s,28GB 要下 26h
- ❌ **不要 foreground `snapshot_download()`** — 阻塞 LLM,没法 poll
- ❌ **不要看到别人 workspace 有半成品权重就 `du -sh` 他/`kill` 他的下载进程**(R1) — 即使带宽抢占明显,也只能耐心 poll 自己的
- ❌ **不要连续 `sleep 300 && sleep 600` 当 poll**(R4) — 浪费 turn 等于烧钱
