---
name: intake
description: 项目部署第一阶段 — clone + 读 README + preflight(GPU/磁盘/gated/30B)
allowed-tools: [Read, Write, Bash, Grep]
agent: intake-agent
---

# intake

## 落盘约定(必读)

本 SubAgent 的所有产物:

- **日志**:`$WORKSPACE/logs/intake.log` — 所有 bash stdout/stderr 用 `2>&1 | tee -a "$LOG"` append 写入
- **结果**:`$WORKSPACE/results/intake.json` — return schema 的 JSON,**覆写**
- 主 agent 收到 return 后还会同时写一份到 `$RUN_DIR/intake.json`(本次 cron 快照;`$RUN_DIR` = `${AI_HARNESS_RUN_DIR:-runs/$RUN_ID}`,slug 已知时即 `workspace/<slug>/runs/<id>/`)

约定见 `/root/ai-auto-harness/.claude/CLAUDE.md` "落盘约定"段.

## 工作流(按顺序)

### 1. workspace 初始化

```bash
SLUG="<from main agent>"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
mkdir -p "$WORKSPACE"/{.cache/huggingface,.cache/hf_hub,.cache/transformers,repo,logs,results}

# 后续所有 bash 命令的输出 append 到这个日志
LOG="$WORKSPACE/logs/intake.log"
echo "==== intake start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=intake slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

写初始 state.json:

```bash
cat > "$WORKSPACE/state.json" <<JSON
{
  "slug": "$SLUG",
  "github_url": "<from input>",
  "hf_repos": <from input>,
  "estimated_params_b": <from input>,
  "estimated_weight_size_gb": <from input>,
  "gated_repos": <from input>,
  "scenario_hits": <from input>,
  "phase": "intake",
  "phases_done": [],
  "started_at": "$(date -Iseconds)",
  "updated_at": "$(date -Iseconds)"
}
JSON
```

### 2. 克隆

```bash
cd "$WORKSPACE"
git clone --depth=1 "$GITHUB_URL" repo 2>&1 | tee -a "$LOG"
```

失败 → `return {"blocked": ["git_clone_failed", "<error msg>"]}`(stderr 已 append 到 LOG)

### 3. 读核心文件

用 Read 工具读(优先级):
- `$WORKSPACE/repo/README.md`(找 Quickstart / Inference / Demo 章节)
- `$WORKSPACE/repo/setup.py` 或 `pyproject.toml`
- `$WORKSPACE/repo/requirements*.txt`
- `$WORKSPACE/repo/*example*.py`、`inference*.py`、`demo*.py`、`app.py`
- `$WORKSPACE/repo/configs/*.yaml`(若有)

### 4. 推断 entry_script

优先级:
1. README quickstart / inference 章节里的 shell 命令
2. setup.py 的 `console_scripts` 入口
3. inference.py / demo.py / app.py(若是 self-contained CLI)
4. 都找不到 → `return {"blocked": ["entry_script_unknown"]}`

### 5. 校准 hf_deps

```bash
grep -rn "from_pretrained" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | tee -a "$LOG" | head -20
grep -rn "hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | tee -a "$LOG" | head -20
```

提取实际引用的 repo 名,与主 agent 传入的 `hf_repos` 比对.补全或修正.

### 5.5 提取 weight_target_paths(必做 — fetch-weights 靠这个建 symlink)

很多项目的 inference 代码 hardcode 了权重相对路径(`ckpt/`、`weights/<name>/`、`models/...`),与 HF repo 名不一致。fetch-weights 下完默认放在 `$WORKSPACE/.cache/hf_models/<repo>/`,跑 inference 时找不到 → 必须建 symlink。

intake 阶段先把 mapping 找出来,fetch-weights 拿着 mapping 建 symlink。

```bash
# 找 inference / demo / app 脚本里 hardcode 的相对路径
grep -rnE "ckpt/|weights/|models/|checkpoints/|pretrained/" \
     "$WORKSPACE/repo/" --include="*.py" --include="*.sh" --include="*.md" --include="*.yaml" \
     2>/dev/null | tee -a "$LOG" | head -40

# 读 README quickstart 章节里给的目录结构(常是 tree 形式)
grep -A 30 -iE "directory structure|folder structure|file layout|目录结构|weights? folder" \
     "$WORKSPACE/repo/README.md" 2>/dev/null | tee -a "$LOG"
```

抽出来 mapping,写到 `intake.json.weight_target_paths`:

```json
"weight_target_paths": [
  {"hf_repo": "lglg666/SongGeneration-Runtime", "target_rel": "ckpt"},
  {"hf_repo": "lglg666/SongGeneration-v2-large", "target_rel": "songgeneration_base"}
]
```

`target_rel` 是相对 `$WORKSPACE/repo/` 的路径。找不到就空数组 + 标 `warnings: ["weight_paths_unknown"]`,fetch-weights 会按默认放并 warn。

### 6. Preflight(调 preflight-gpu-disk skill)

按 `.claude/skills/ai-auto/preflight-gpu-disk.md` 的 4 类检查:GPU / 磁盘 / Gated / Size。

汇总 blocked 数组.

### 7. 更新 state.json

```bash
jq --arg phase fetching \
   --argjson result '{"entry_script":"...","hf_deps":[...],"gpu_picks":[...],"blocked":[]}' \
   '.phase = $phase | .phases_done += ["intake"] | .intake_result = $result | .updated_at = "'$(date -Iseconds)'"' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

### 失败处理

- `blocked` 非空 → 调 **request-human-intervention skill** 写 `pending_human/<slug>.md`,state.phase=`paused_for_human`
- 不要自己重试(主 agent 决策)

### 8. 返回前落盘 results JSON

```bash
cat > "$WORKSPACE/results/intake.json" <<JSON
{
  "entry_script": "<推断出的>",
  "hf_deps": [...],
  "weight_target_paths": [
    {"hf_repo": "<org>/<repo>", "target_rel": "<相对 repo/ 的路径>"}
  ],
  "gpu_picks": [...],
  "blocked": [...],
  "warnings": [...],
  "ready_to_fetch": <true|false>,
  "completed_at": "$(date -Iseconds)"
}
JSON
echo "==== intake end at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_END   phase=intake slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

## 返回 schema(同时 return 给主 agent)

```json
{
  "entry_script": "python -m flux t2i --output out.png",
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```
