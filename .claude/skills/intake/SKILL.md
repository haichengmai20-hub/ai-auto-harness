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
  - **python 版本判定(2026-06-10)**:优先取 `pyproject.toml` 的 `requires-python` / `setup.py`/`setup.cfg` 的 `python_requires` 字段为准;repo 没声明才允许从 README/代码特征推断,且 intake.json 里必须标 `"python_version_confidence": "low"`(实测 "3.10+ (inferred)" 这种推断经常不准,害 install 阶段重装)
- `$WORKSPACE/repo/requirements*.txt`
- `$WORKSPACE/repo/*example*.py`、`inference*.py`、`demo*.py`、`app.py`
- `$WORKSPACE/repo/configs/*.yaml`(若有)

### 3.5 判定 entry_type(F13)

```bash
ET=script
if ls "$WORKSPACE/repo"/{run_backend.sh,server.py,app.py,api.py} >/dev/null 2>&1 \
   || grep -rqiE "vllm serve|uvicorn|fastapi|flask run|\.launch\(|\.serve\(|gradio" \
        "$WORKSPACE/repo" --include="*.py" --include="*.md" --include="*.sh" 2>/dev/null; then
  ET=service
fi
echo "entry_type=$ET" | tee -a "$LOG"
```

`service` 时,从 README quickstart「启动服务 / 发请求」段 + 启动脚本 + config 抽出 descriptor(best-effort,全包,标 confidence):

- `start_cmd`:启动后端的命令,把选定 GPU(`gpu_picks[0]`)按项目的传法注入(`--gpus N` / `CUDA_VISIBLE_DEVICES=N` / config);传法不明在 `warnings` 标注
- `ready_signal`:优先找 health/任意 GET 端点 → `{"type":"http","url":"http://127.0.0.1:<port>/health","expect_status":200}`;没有则退 log 型 → `{"type":"log","pattern":"Uvicorn running|Application startup complete|Running on http"}`
- `port`:从启动命令/config/README 抽;抽不到填 0 并 `warnings`
- `infer_cmd`:从 README 的请求示例构造(curl / 项目自带 client),**必须**把结果写到 `output_path`(curl 加 `-o <output_path>`)
- `output_path`:推理产物相对 `repo/` 的路径
- `stop_cmd`:项目有停止命令则填,无则留空(run/cleanup 直接杀 PID)
- `confidence`:README 给全=high;靠框架默认推=medium/low

连 `start_cmd` 都推不出 → `blocked: ["service_descriptor_incomplete"]`(走现有失败处理→paused_for_human)。

> ⚠️ `app.py` 不一定是服务(可能是 CLI)。判定后**读 app.py 头部确认**有 server/launch 语义(`uvicorn.run`/`app.run`/`.launch(`/`serve`)再定 service;只是 argparse CLI 的 `app.py` 仍按 script。

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
   --argjson result '{"entry_script":"...","entry_type":"script","service":null,"hf_deps":[...],"gpu_picks":[...],"blocked":[]}' \
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
  "entry_type": "script",
  "service": null,
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
  "entry_type": "script",
  "service": null,
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```

service 项目时 `entry_type` 填 `"service"`,`service` 填完整 descriptor:

```json
{
  "entry_script": null,
  "entry_type": "service",
  "service": {
    "start_cmd": "python server.py --port 8001",
    "ready_signal": {"type": "http", "url": "http://127.0.0.1:8001/health", "expect_status": 200},
    "port": 8001,
    "infer_cmd": "curl -s -X POST http://127.0.0.1:8001/infer -d '{\"prompt\":\"test\"}' -o output_path",
    "output_path": "results/output.json",
    "stop_cmd": "",
    "confidence": "high"
  },
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```

## ChangeLog

- **2026-06-10** — python 版本判定优先 requires-python 字段,推断必标 low confidence
  - 变更类型: 流程 / schema 语义
  - 影响范围: 第 3 步读核心文件
  - 动机: intake.json 常见 "3.10+ (inferred, not pinned)" 推断不准,害 install 阶段重装
  - 证据: [fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md](../../../docs/superpowers/fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md)

- **2026-06-16** — entry_type 检测 + service descriptor(F13)
  - 变更类型: schema + 流程
  - 影响范围: 新增第 3.5 步(entry_type 判定 + service descriptor 推断);return schema 加 `entry_type`/`service` 两字段;第 7 步 jq `--argjson result` 携带 `entry_type`/`service`;第 8 步落盘 JSON 同步加两字段
  - 动机: F1 服务型项目支持 — vLLM/Gradio/Flask 类项目须先起后端服务再发请求,原来只认 `python3 script.py` 的单脚本路径全挂
  - 证据: [fixes/2026-06-16-service-type-inference-fix.md](../../../docs/superpowers/fixes/2026-06-16-service-type-inference-fix.md)
