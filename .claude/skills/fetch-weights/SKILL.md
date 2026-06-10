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
4. **Xet 先试但必须 fallback**:可先 `HF_XET_HIGH_PERFORMANCE=1`,但 30min 无增长 ≥100MB 或 TLS/403 循环 >3 次,必须切 `HF_HUB_DISABLE_XET=1` 普通 HTTP 重下;`HF_HUB_ENABLE_HF_TRANSFER` 已废弃,**禁用**
5. **foreground sleep ≤ 60s/次**(R4):长等用 `setsid nohup ... &` 后台 + tail log + `kill -0 $PID` 判活
6. **state.json 每 phase 起止双写**(R2):本 skill 开头写 `phase=fetching, status=running`,return 前写 `status=done`
7. **wall-clock 上限 180min**(R3):超过且进度 < 50% → `paused_for_human`;> 50% → `paused_in_progress`,下次 cron 接续
8. **代理环境下载优化(必须)**:本机必须走代理才能访问外网(直连报 Network is unreachable),**严禁 unset proxy、严禁把 `huggingface.co` 等外网域名加进 `no_proxy`**(历史"绕代理防 503"旧规则已被证伪并删除——绕开代理=直连=断网;Fix: 2026-06-10-no-proxy-pollution-gated-403-fix)。代理 503 的正解:禁 Xet(`HF_HUB_DISABLE_XET=1`) + 降并发(`HF_HUB_DOWNLOAD_CONCURRENCY=2`)。launch_worker.sh/daily.sh 已 env-level 设这两项
9. **gated 403 即停**:下载输出含 `Access denied` / `requires approval` / `Cannot access gated repo` / `401` / `403` → 账号未获该 repo 批准,**不重试、不当网络错误处理**,直接 `blocked.append("gated_needs_approval: <repo>")` → 调 request-human-intervention → state `paused_for_human`。重试不可能让账号获批,只会烧 wall-clock

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

## 第 0 步:环境变量 + DEST 校验 + token 校验(每次跑 bash 前)

```bash
# launch_worker.sh 已 env-level 设了 HF_HOME / HF_HUB_CACHE / TRANSFORMERS_CACHE,
# 但每次新开 bash 重新 export 一遍是好习惯(防止某些边角 case)
export HF_HOME="${HF_HOME:-$WORKSPACE/.cache/huggingface}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$WORKSPACE/.cache/hf_hub}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$WORKSPACE/.cache/transformers}"

# 🔴 代理环境优化(2026-06-08-proxy-hf-download-503-fix):
# 本机必须走代理才能访问外网(直连 Network is unreachable)。
# Xet 后端起多个并发连接打爆代理 → 503 Too many open connections。
# 解法:禁 Xet + 降并发,走代理但不打爆。
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_CONCURRENCY="${HF_HUB_DOWNLOAD_CONCURRENCY:-2}"
echo "HF download: XET=disabled CONCURRENCY=$HF_HUB_DOWNLOAD_CONCURRENCY (proxy-safe)" >> "$LOG"

# 🔴 DEST 路径校验(2026-06-08-fetch-dest-path-not-injected-fix):
# 主 agent Task() prompt 应显式传入 dest_path_template;
# 若未传入,则 fallback 到默认模板。禁止自拼其他路径。
DEST_TEMPLATE="${dest_path_template:-\$WORKSPACE/.cache/hf_models/\$REPO}"
echo "DEST template: $DEST_TEMPLATE (from prompt or fallback)" >> "$LOG"

# 首次尝试用普通 HTTP 后端(非 Xet);若仍卡死,第 4 步检查磁盘/网络

# token 校验 — 没 token 会限速到 ~0.3MB/s,28GB 要下 26 小时
if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: HF_TOKEN 未传入。launch_worker.sh 应从 .env 注入。" >> "$LOG"
    # 调 request-human-intervention,reason=hf_token_missing
    exit 1
fi

# 确保 huggingface_hub 1.x(自带 `hf` 命令 + hf_xet Xet 后端);不要再装 [hf_transfer] extra
pip install -U huggingface_hub 2>&1 | tee -a "$LOG"
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
- 进程死了 + 文件未完 → 第 2 步重启(`hf download` 默认断点续传,不需要也没有 `--resume-download`)
- 进程死了 + 文件已完 → 标 done,看下一个 repo

**如果 state.fetch_state 空 OR weights_pending 全空**:
- 初始化 `state.fetch_state = {weights_done: [], weights_pending: <主 agent 传入的 hf_repos>, bg_shells: []}`

## 第 2 步:启动 background 下载(用 `hf`,不要 `huggingface-cli`)

对每个 PENDING repo(**串行**,不要并行多 repo 抢带宽):

```bash
REPO="<repo>"
DEST="$WORKSPACE/.cache/hf_models/$REPO"
mkdir -p "$DEST"
mkdir -p "$WORKSPACE/.cache/handoff"
SAFE_REPO=$(echo "$REPO" | tr '/:' '__')
SENTINEL="$WORKSPACE/.cache/handoff/fetch-weights-$SAFE_REPO.json"

# 🔴 并发防护(P2-6):同一 repo 已有 hf download 在跑就**不**再起新进程
# (实测:LLM 见下载慢就"重试"起 3 个进程写同一 --local-dir,锁竞争 → 0 MB/s)
if pgrep -f "hf download.*$REPO" >/dev/null 2>&1; then
    echo "WARN: $REPO 已有 hf download 在跑,跳过重启(防并发锁竞争)。要重启先 pkill -f 'hf download.*$REPO'" | tee -a "$LOG"
else
# 用 setsid + nohup 双重保险脱离 parent process group
setsid nohup bash -c "
  set +e
  STARTED_AT=\$(date -Iseconds)
  # 🔴 代理环境:禁 Xet + 降并发(2026-06-08-proxy-hf-download-503-fix)
  # 本机必须走代理(直连 Network is unreachable),不能 unset proxy。
  # Xet 多连接打爆代理 → 503,所以禁 Xet 走普通 HTTP。
  export HF_HUB_DISABLE_XET=1
  export HF_HUB_DOWNLOAD_CONCURRENCY=2
  echo '==== fetching $REPO at \$(date -Iseconds) ====' >> '$WORKSPACE/logs/fetch_weights.log'
  # 新版 hf download 默认断点续传(--resume-download 在 huggingface_hub 1.x 已移除)
  hf download '$REPO' \
      --local-dir '$DEST' \
      --token '$HF_TOKEN' 2>&1
  RC=\$?
  BYTES=\$(du -sb '$DEST' 2>/dev/null | awk '{print \$1}')
  python3 -c 'import json,sys,time; path,rc,bytes_,pid=sys.argv[1],int(sys.argv[2]),int(sys.argv[3] or 0),int(sys.argv[4]); json.dump({\"status\":\"done\" if rc==0 else \"failed\",\"slug\":\"'$SLUG'\",\"phase\":\"fetch-weights\",\"repo\":\"'$REPO'\",\"pid\":pid,\"exit_code\":rc,\"started_at\":\"'\"\$STARTED_AT\"'\",\"completed_at\":time.strftime(\"%Y-%m-%dT%H:%M:%S%z\"),\"log_path\":\"'$WORKSPACE/logs/fetch_weights.log'\",\"local_dir\":\"'$DEST'\",\"bytes\":bytes_}, open(path,\"w\"), ensure_ascii=False, indent=2)' '$SENTINEL' \"\$RC\" \"\${BYTES:-0}\" \"\$BASHPID\"
  exit \$RC
" >> "$WORKSPACE/logs/fetch_weights.log" 2>&1 &
PID=$!
fi
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
5. **Xet 错误计数**:`grep -Ei "tls handshake eof|403 Forbidden|xet" "$LOG" | tail -20`,若 TLS/403 循环 >3 次 → 第 4 步切 HTTP fallback

## 第 4 步:卡死判定 + 重启

如果 `.incomplete` 30min 无增长 + log 30min 无新输出:
- KillBash(shell_id) 杀 bg
- `rm "$WORKSPACE/.cache/hf_models/<repo>"/*.incomplete` 删坏的临时文件(`hf download` resume 会重建)
- 第 2 步重启(同 repo,`hf download` 默认断点续传,从已 cache 的文件接着下;无 `--resume-download` flag)
- 重启 max 2 次,仍卡 → `blocked.append("download_stuck:" + repo)` 调 request-human-intervention

如果 Xet 模式下 30min 下载增长 <100MB 或日志出现 `tls handshake eof` / `403 Forbidden` 循环 >3 次:
- KillBash(shell_id) 杀本 repo PID
- 删除该 repo 下 `.incomplete`
- 用普通 HTTP fallback 重启:
  ```bash
  HF_HUB_DISABLE_XET=1 hf download "$REPO" --local-dir "$DEST" --token "$HF_TOKEN"
  ```
- 在 `results/weights.json.repos[].fallback = "http_no_xet"` 记录

## 第 5 步:时间预算判定(跨 cron 接续核心)

```bash
# 主 agent 启动 → 现在多久了($RUN_DIR = ${AI_HARNESS_RUN_DIR:-runs/$RUN_ID},
# slug 已知时即 workspace/<slug>/runs/<id>;Fix: 2026-06-08-run-dir-into-workspace)
RUN_DIR="${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}"
META_START=$(jq -r .started_at "$RUN_DIR/meta.json")
ELAPSED_SEC=$(( $(date +%s) - $(date -d "$META_START" +%s) ))
```

如果 ELAPSED_SEC > 3000(50 分钟)且当前下载进度 < 80%:
- **不 kill bg shell**(让它继续在后台,nohup + setsid 确保 CC 退出后仍跑)
- 更新 state.json `paused_in_progress=true`
- return `{"weights_done": [...], "paused_in_progress": true}`
- 主 agent 跳到任务 4 写报告"in progress",**下次 cron 接续**

## 第 6 步:Gated 二次拦截

若运行时遇到 **401 / 403 / `Access denied` / `requires approval` / `Cannot access gated repo`**(intake preflight 漏检了——注意 HF 对"gated 但账号未获批"返回的是 403 "Access denied. This repository requires approval.",不是 401):
- KillBash(shell_id)
- **不重试**——重试不可能让账号获批,只会烧 wall-clock
- 调 **request-human-intervention** skill,reason_category=`auth_missing`,what_blocked=`gated repo <repo> 需要用该 HF_TOKEN 的账号在 HF 网页上接受 license / 申请审批`
- return `{"blocked": true, "paused_for_human": true}`

## 第 7 步:全部完成 + 建 symlink 到 README 要求的相对路径

每个 repo 下完(进度 100% + .incomplete 消失 + 退出 0):
- **必须跑完整性校验**:
  ```bash
  bash scripts/validate-fetch-weights.sh "$WORKSPACE" "$REPO" "$DEST"
  ```
  校验失败(缺文件 / 大小差异 >5%) → 删除坏文件并按第 4 步 fallback 重下;不要把损坏文件传给 run-and-repair
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
- ❌ 不要 `rm -rf .cache` — `hf download` 默认断点续传,重跑即继续
- ❌ **不要并发起多个 `hf download` 写同一 `--local-dir`**(P2-6 实测:3 进程锁竞争 → 0 MB/s)— 起新进程前先 `pgrep -f "hf download.*<repo>"`,有就别起
- ❌ **不要加 `--resume-download`**(huggingface_hub 1.x 已移除该 flag,加了直接报错)— 默认就续传
- ❌ **不要用 `HF_HUB_ENABLE_HF_TRANSFER=1`**(已废弃 FutureWarning)— 用 `HF_XET_HIGH_PERFORMANCE=1`
- ❌ **不要只检查 `.incomplete` 消失就判 done** — 必须跑 `scripts/validate-fetch-weights.sh` 比对 manifest size
- ❌ **不要让 Xet TLS/403 循环超过 3 次还继续等** — 切 `HF_HUB_DISABLE_XET=1` fallback
- ❌ **不要在代理环境下开 Xet 多连接跑 `hf download`** — Xet 多连接打爆代理 → 503 Too many open connections；应 `HF_HUB_DISABLE_XET=1` 禁 Xet 走普通 HTTP(2026-06-08-proxy-hf-download-503-fix)
- ❌ **不要在无直连外网的机器上 unset proxy/no_proxy** — 会断网 → Network is unreachable
- ❌ **不要把 `huggingface.co` 等外网域名加进 `no_proxy`** — 等于强制直连 = 断网(2026-06-10 实测把 fetch 全挂);`no_proxy` 只放内网 IP / 可直连的国内 API host
- ❌ **不要把 gated 403 当网络错误重试** — `Access denied...requires approval` 是账号权限问题,重试 0 收益,直接走第 6 步 paused_for_human

## ChangeLog

- **2026-06-02** — 对齐 huggingface_hub 1.x + 并发下载硬防护
  - 变更类型: 硬约束 + 反模式
  - 影响范围: 硬规则 4 / 第 0 步 export + pip / 第 2 步 setsid 下载块 / 第 1 步接续 / 第 4 步重启 / 反模式段
  - 动机: `--resume-download` 在 1.x 报错、`HF_HUB_ENABLE_HF_TRANSFER` FutureWarning、3 进程并发写同 dir 锁竞争 0 MB/s(P2-4/P2-9/P2-6)
  - 证据: [fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md](../../../docs/superpowers/fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md) + [fixes/2026-06-02-concurrent-download-zombie-guard-fix.md](../../../docs/superpowers/fixes/2026-06-02-concurrent-download-zombie-guard-fix.md)
  - 规则: `hf download` 默认续传(无 `--resume-download`);加速用 `HF_XET_HIGH_PERFORMANCE=1`;起新下载前 `pgrep -f "hf download.*<repo>"`
- **2026-06-04** — 加下载完整性校验 / Xet fallback / handoff sentinel
  - 变更类型: 流程 / schema / 反模式
  - 影响范围: 硬规则 4 / 第 2 步后台下载 / 第 3-4 步 poll+fallback / 第 7 步 done 判定 / 反模式
  - 动机: ControlFoley Xet 卡死 24h 且 CLAP 权重只有 469MB,fetch 阶段未发现
  - 证据: [fixes/2026-06-03-fetch-weights-no-download-integrity-check-fix.md](../../../docs/superpowers/fixes/2026-06-03-fetch-weights-no-download-integrity-check-fix.md) + [fixes/2026-05-29-polling-handoff-mechanism-fix.md](../../../docs/superpowers/fixes/2026-05-29-polling-handoff-mechanism-fix.md)
  - 验证: ⬜ 待验证(`scripts/validate-fetch-weights.sh` fixture + ControlFoley 校验)
- **2026-06-08** — 代理环境 HF 下载优化:禁 Xet + 降并发(非 unset proxy)
  - 变更类型: 硬约束 + 反模式 + 流程
  - 影响范围: 硬规则 8(修正) / 第 0 步 env export / 第 2 步 setsid 下载块 / 反模式段
  - 动机: 公司代理连接池有限,Xet 多连接打爆代理 → 503；实测本机无直连外网能力(unset proxy → Network is unreachable),改为禁 Xet + 降并发走代理
  - 证据: [fixes/2026-06-08-proxy-hf-download-503-fix.md](../../../docs/superpowers/fixes/2026-06-08-proxy-hf-download-503-fix.md)
  - 验证: ⬜ 待验证(重跑 magenta-realtime fetch 阶段)
- **2026-06-08** — DEST 路径显式注入:第 0 步加 DEST 校验,主 agent Task() prompt 传入 dest_path_template
  - 变更类型: 流程 / 约束
  - 影响范围: 第 0 步 DEST 校验 / auto-deploy/SKILL.md fetch dispatch prompt / auto-daily/SKILL.md fetch dispatch prompt
  - 动机: magenta-realtime 实测 5 个 hf download 进程拼出 3 种不同 --local-dir 路径,SKILL.md 规定的 .cache/hf_models/$REPO 没人用;根因是 Task() prompt 未传 DEST,SubAgent 自拼
  - 证据: [fixes/2026-06-08-fetch-dest-path-not-injected-fix.md](../../../docs/superpowers/fixes/2026-06-08-fetch-dest-path-not-injected-fix.md)
  - 验证: ⬜ 待验证(重跑 magenta-realtime fetch 阶段)
- **2026-06-10** — 删除过时"绕代理"规则 + gated 403 即停
  - 变更类型: 硬约束(删除矛盾旧规则)+ 反模式 + 流程
  - 影响范围: 硬规则 8/9 / 第 6 步 Gated 二次拦截 / 反模式段
  - 动机: 旧规则 8("把 huggingface.co 加 no_proxy / unset 代理防 503")与 2026-06-08 修正版同时存在且编号冲突,用户照旧规则配 `.env` 后 fetch 全断网(本机无直连);另 HF gated-未获批返回 403 "Access denied...requires approval",旧文只认 401,eagle 漏检
  - 证据: [fixes/2026-06-10-no-proxy-pollution-gated-403-fix.md](../../../docs/superpowers/fixes/2026-06-10-no-proxy-pollution-gated-403-fix.md)
  - 验证: ✅ cron 等价环境 `hf download gpt2 config.json` 经代理成功;`nvidia/Eagle2.5-8B` 稳定复现 403 文案
- ❌ 不要 wait 一个 bg shell — poll
- ❌ 不要不 export `HF_HOME` 等就跑下载 — 会污染 ~/.cache/huggingface
- ❌ 不要在 cron 快到时间但还在下时 kill 进程 — 让它后台继续
- ❌ **不要用 `huggingface-cli`** — 已废弃,无 hf_transfer 加速,统一用 `hf`
- ❌ **不要 `--token` 留空** — 没 token 限速到 0.3MB/s,28GB 要下 26h
- ❌ **不要 foreground `snapshot_download()`** — 阻塞 LLM,没法 poll
- ❌ **不要看到别人 workspace 有半成品权重就 `du -sh` 他/`kill` 他的下载进程**(R1) — 即使带宽抢占明显,也只能耐心 poll 自己的
- ❌ **不要连续 `sleep 300 && sleep 600` 当 poll**(R4) — 浪费 turn 等于烧钱
