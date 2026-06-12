# fetch-weights playbook(Hermes 子代理)

拉 HF 权重 — setsid nohup 后台 + sentinel + 跨 cron 接续。

## 🔴 硬规则(违反 = 跑挂/作弊)

1. **只下不装**:严禁 pip install / venv(R5 串行带宽)
2. **`hf` 不是 `huggingface-cli`**;`--token "$HF_TOKEN"` 显式传(没 token 限速 0.3MB/s)
3. **代理铁律(fix #36)**:本机无直连外网,**严禁 unset proxy、严禁把 huggingface.co 等外网域名加进 no_proxy**(= 强制直连 = Network is unreachable)。代理 503 的正解 = `HF_HUB_DISABLE_XET=1` + `HF_HUB_DOWNLOAD_CONCURRENCY=2`
4. **无 `--resume-download`**(huggingface_hub 1.x 已移除,加了报错;默认就续传)
5. **gated 403 即停**:输出含 `Access denied`/`requires approval`/`Cannot access gated repo`/401/403 → 账号未获批,**不重试不当网络错误**,直接 paused_for_human(重试不可能让账号获批)
6. **R4**:单次 sleep ≤60s,连续 sleep 禁,poll ≤8 次;退出让 cron 接续比空转便宜 1000 倍
7. **R2**:开头写 state `phase=fetching, status=running`,return 前写终态
8. **wall-clock 180min(R3)**:超时进度>50% → paused_in_progress;否则 paused_for_human

## 落盘

日志 `$WORKSPACE/logs/fetch_weights.log`;进度 `$WORKSPACE/progress.md` + `progress.json`(每 poll 一行);结果 `results/fetch.json` + `results/weights.json`;sentinel `$WORKSPACE/.cache/handoff/fetch-weights-<safe_repo>.json`。

## 第 0 步(每条 bash 前缀)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh   # 含代理/HF env 恢复
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2
echo "=== PHASE_START phase=fetch-weights slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

- intake 已判 gated:`jq -r '.preflight.gated_ok' results/intake.json` 为 false → 直接走 gated 停止分支,不试下载
- `[ -z "$HF_TOKEN" ]` → pending_human(hf_token_missing)
- DEST 模板(主 agent 注入,**禁自拼**):`$WORKSPACE/.cache/hf_models/<org>/<repo>`(嵌套,不是 org--repo)

## 第 1 步:接续判定

读 `state.fetch_state.{weights_done, weights_pending, bg_shells}`:
- bg_shells 有 PID → `kill -0` + **查 `/proc/<pid>/stat` 第 3 列 `Z`(僵尸=死,容器 PID 1 不收尸)**:活着且文件在长 → 跳第 3 步 poll;死了未完 → 第 2 步重启(默认续传);死了已完 → 标 done
- fetch_state 空 → 初始化 weights_pending = hf_repos

## 第 2 步:启动后台下载(每 repo 串行)

```bash
REPO="<org>/<repo>"; DEST="$WORKSPACE/.cache/hf_models/$REPO"; mkdir -p "$DEST" "$WORKSPACE/.cache/handoff"
SAFE_REPO=$(echo "$REPO" | tr '/:' '__')
SENTINEL="$WORKSPACE/.cache/handoff/fetch-weights-$SAFE_REPO.json"
# 并发防护:已有同 repo 下载在跑就不再起(3 进程写同 dir 锁竞争 → 0 MB/s)
if pgrep -f "hf download.*$REPO" >/dev/null 2>&1; then
    echo "WARN: $REPO 已在下载,跳过重启" | tee -a "$LOG"
else
setsid nohup bash -c "
  set +e
  STARTED_AT=\$(date -Iseconds)
  export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2
  hf download '$REPO' --local-dir '$DEST' --token '$HF_TOKEN' 2>&1
  RC=\$?
  BYTES=\$(du -sb '$DEST' 2>/dev/null | awk '{print \$1}')
  python3 -c 'import json,sys,time; path,rc,bytes_,pid=sys.argv[1],int(sys.argv[2]),int(sys.argv[3] or 0),int(sys.argv[4]); json.dump({\"status\":\"done\" if rc==0 else \"failed\",\"slug\":\"'$SLUG'\",\"phase\":\"fetch-weights\",\"repo\":\"'$REPO'\",\"pid\":pid,\"exit_code\":rc,\"started_at\":\"'\"\$STARTED_AT\"'\",\"completed_at\":time.strftime(\"%Y-%m-%dT%H:%M:%S%z\"),\"log_path\":\"'$WORKSPACE/logs/fetch_weights.log'\",\"local_dir\":\"'$DEST'\",\"bytes\":bytes_}, open(path,\"w\"), ensure_ascii=False, indent=2)' '$SENTINEL' \"\$RC\" \"\${BYTES:-0}\" \"\$BASHPID\"
  exit \$RC
" >> "$WORKSPACE/logs/fetch_weights.log" 2>&1 &
PID=$!
echo $PID > "$WORKSPACE/.cache/$(basename $REPO).pid"
fi
```

🔴 **禁自创 wrapper 丢 sentinel 终态写入**(scail 实测:手写 wrapper 死了 5h 还报 running)。要改参数就在上面模板上改。
🔴 **跨 cron 必须用 setsid nohup,不要用 Hermes terminal(background=true)** — 后者挂在 Hermes 进程下,cron run 结束可能被回收。
启动后立即 jq 把 `{pid, repo, started_at}` append 进 `state.fetch_state.bg_shells`。

## 第 3 步:poll(≤8 次)

每次 poll 一条命令完成观察(可 `sleep 55 && tail` 合并等待+采样,R4.6 间隔 30→45→60s):
0. **PID 死(含僵尸)→ 立即按 sentinel 同款 schema 补写终态**(status=dead + du 实测 bytes),绝不带着假 running return
1. `du -sb $DEST` 算进度百分比 → append progress.md + progress.json
2. 磁盘 `df -h`,free < 30GB → kill 本 PID 文件里的下载 + blocked(disk_low)
3. `.incomplete` 30min 无变化 → 卡死:kill(自有 PID)+ 删 `.incomplete` + 重启(max 2 次,仍卡 → pending_human)
4. log 出现 gated 403 文案 → 硬规则 5,paused_for_human

## 第 4 步:时间预算(跨 cron 核心)

elapsed > 50min 且进度 < 80% → **不 kill 后台**,state 写 `paused_in_progress=true`(phase 不变),return。下次 cron 接续。

## 第 5 步:完成 → 校验 + symlink

每 repo:`.incomplete` 消失 + exit 0 后**必须**:
```bash
bash scripts/validate-fetch-weights.sh "$WORKSPACE" "$REPO" "$DEST"
```
失败(缺文件/大小差>5%)→ 删坏文件重下,不许把损坏权重传给 run。

然后按 `results/intake.json.weight_target_paths` 建 symlink:
```bash
jq -r '.weight_target_paths // [] | .[] | "\(.hf_repo) \(.target_rel)"' "$WORKSPACE/results/intake.json" | while read REPO TARGET_REL; do
    SRC="$WORKSPACE/.cache/hf_models/$REPO"; DST="$WORKSPACE/repo/$TARGET_REL"
    mkdir -p "$(dirname "$DST")"
    [ -e "$DST" ] && [ ! -L "$DST" ] && mv "$DST" "$DST.bak"
    ln -sfn "$SRC" "$DST"
done
```
mapping 空 → `warnings += ["symlink_skipped"]`,不 block。

## 第 6 步:落盘 + 返回

`results/fetch.json`:`{"weights_done":[...], "failed":[], "paused_in_progress":false, "bytes_total":N, "completed_at":"..."}`(bash heredoc 求值,禁字面量);`results/weights.json` 记每 repo 的 local_dir/bytes/started_at/completed_at/resumed。
更新 state(R2 终态)+ `PHASE_END` 标记。**summary 原样含 fetch.json 全文**。

## 反模式

- ❌ 前台跑下载(snapshot_download/无 timeout bash)— 必须 setsid nohup 后台
- ❌ 并发多进程写同一 --local-dir;❌ `--resume-download`;❌ `HF_HUB_ENABLE_HF_TRANSFER`(废弃)
- ❌ unset proxy / no_proxy 加外网域名;❌ gated 403 重试;❌ 只看 .incomplete 消失就判 done
- ❌ 动别人 workspace 的下载进程(R1);❌ 连续 sleep 当 poll(R4)
- ❌ cron 快结束时 kill 还在跑的下载 — 让它后台继续
