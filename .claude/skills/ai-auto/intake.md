---
name: intake
description: 项目部署第一阶段 — clone + 读 README + preflight(GPU/磁盘/gated/30B)
allowed-tools: [Read, Write, Bash, Grep]
agent: intake-agent
---

# intake

## 工作流(按顺序)

### 1. workspace 初始化

```bash
SLUG="<from main agent>"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
mkdir -p "$WORKSPACE"/{.cache/huggingface,.cache/hf_hub,.cache/transformers,repo}
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
git clone --depth=1 "$GITHUB_URL" repo
```

失败 → `return {"blocked": ["git_clone_failed", "<error msg>"]}`

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
grep -rn "from_pretrained" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | head -20
grep -rn "hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | head -20
```

提取实际引用的 repo 名,与主 agent 传入的 `hf_repos` 比对.补全或修正.

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

## 返回 schema

```json
{
  "entry_script": "python -m flux t2i --output out.png",
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```
