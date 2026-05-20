---
name: fetch-weights
description: 拉 HF 权重 — background bash + BashOutput poll + 跨 cron 接续
allowed-tools: [Read, Write, Bash, BashOutput, KillBash]
agent: fetch-agent
---

# fetch-weights

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

## 第 0 步:环境变量隔离(每次跑 bash 前都必须 export)

```bash
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export TRANSFORMERS_CACHE="$WORKSPACE/.cache/transformers"
```

**强制**:任何后续 huggingface-cli / python -c "from huggingface_hub" 调用前都必须先 export 这三个,否则会污染全局 cache.

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

## 第 2 步:启动 background 下载

对每个 PENDING repo(若并行下载多个,串行 OR 控制 2-3 个并发):

```bash
# 用 setsid + nohup 双重保险脱离 parent process group
setsid nohup huggingface-cli download \
    "<repo>" \
    --local-dir "$WORKSPACE/.cache/hf_models/<repo>" \
    --resume-download \
    > "$WORKSPACE/progress_<repo>.log" 2>&1 &
PID=$!
echo $PID > "$WORKSPACE/.cache/<repo>.pid"
```

通过 CC `Bash(run_in_background=true)` 调用,记录 shell_id.

**立即更新 state.json**:
```bash
jq --arg shell "$SHELL_ID" --arg pid "$PID" --arg repo "<repo>" --arg ts "$(date -Iseconds)" \
   '.fetch_state.bg_shells += [{id: $shell, pid: ($pid | tonumber), repo: $repo, started_at: $ts, log_path: ("progress_" + $repo + ".log")}]' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

## 第 3 步:Poll 循环(每 60-180s)

```bash
# 用 BashOutput(shell_id) 看新输出
BashOutput(shell_id=<...>)

# 或读 log 文件 tail
tail -20 "$WORKSPACE/progress_<repo>.log"
```

每次 poll 都做这几件事:

1. **进度估算**:从 huggingface-cli 输出抽 MB 数字(stderr 通常含 `xxx MB / yyy MB`),算百分比
2. **写 progress.md**:
   ```markdown
   - 2026-05-19T10:42 — fetching <repo>: 12.3GB / 23GB (53%), incomplete 文件还在长
   ```
3. **磁盘检查**:`df -h "$WORKSPACE"` 看 free,< 30GB → kill 全部 bg + 报告 disk_low
4. **`.incomplete` 文件大小变化检查**:
   ```bash
   ls -la "$WORKSPACE/.cache/hf_models/<repo>"/*.incomplete 2>/dev/null
   ```
   记录每次 size,若 30min 无变化 → 卡了

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

## 第 7 步:全部完成

每个 repo 下完(进度 100% + .incomplete 消失 + 退出 0):
- 移到 weights_done
- 从 weights_pending 移除
- 更新 state.json

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
- ❌ 不要不 export `HF_HOME` 等就跑 huggingface-cli — 会污染 ~/.cache/huggingface
- ❌ 不要在 cron 快到时间但还在下时 kill 进程 — 让它后台继续
