# intake playbook(Hermes 子代理)

第一阶段:clone + 读 README + 资源 preflight(GPU/磁盘/gated/30B)。

## 落盘

- 日志 `$WORKSPACE/logs/intake.log`(所有 bash `2>&1 | tee -a "$LOG"` append)
- 结果 `$WORKSPACE/results/intake.json`(覆写)

## 第 0 步(每条 bash 前缀)

```bash
source /root/ai-auto-harness/hermes/scripts/guard.env.sh
```

## 1. workspace 初始化

```bash
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
mkdir -p "$WORKSPACE"/{.cache/huggingface,.cache/hf_hub,.cache/transformers,.cache/handoff,repo,logs,results}
LOG="$WORKSPACE/logs/intake.log"
echo "==== intake start at $(date -Iseconds) ====" >> "$LOG"
echo "=== PHASE_START phase=intake slug=$SLUG run_id=$RUN_ID ts=$(date -Iseconds) ==="
```

写初始 state.json(R2):slug/github_url/hf_repos/estimated_params_b/estimated_weight_size_gb/gated_repos/scenario_hits/`phase:"intake"`/`status:"running"`/phases_done:[]/started_at/updated_at。

## 2. clone

```bash
cd "$WORKSPACE" && git clone --depth=1 "$GITHUB_URL" repo 2>&1 | tee -a "$LOG"
```

失败 → return `{"blocked": ["git_clone_failed", "<msg>"]}`。

## 3. 读核心文件 → 推断 entry_script

优先级:README quickstart/inference 章节命令 → setup.py console_scripts → inference.py/demo.py/app.py。都没有 → `blocked: ["entry_script_unknown"]`。

**python 版本判定**:以 `pyproject.toml` 的 `requires-python` / `setup.py` 的 `python_requires` 为准;repo 没声明才允许推断,且必须标 `"python_version_confidence": "low"`。

## 4. 校准 hf_deps + 提取 weight_target_paths(必做)

```bash
grep -rn "from_pretrained\|hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" 2>/dev/null | tee -a "$LOG" | head -20
grep -rnE "ckpt/|weights/|models/|checkpoints/|pretrained/" "$WORKSPACE/repo/" --include="*.py" --include="*.sh" --include="*.md" --include="*.yaml" 2>/dev/null | tee -a "$LOG" | head -40
```

产出 `weight_target_paths: [{"hf_repo": "...", "target_rel": "<相对 repo/ 的路径>"}]` — fetch 阶段靠它建 symlink。找不到 → 空数组 + `warnings: ["weight_paths_unknown"]`。

## 5. Preflight(GPU / 磁盘 / Gated / 30B)

### GPU
```bash
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader,nounits
```
- 单卡 used ≥ 25000 MiB → 该卡不参与分配(🔴 那是用户的训练,绝不算"残留",绝不清)
- 其余按 free 降序取 Top N;选中卡 free ≥ 需求 + 2048 MiB
- **聚合检查(P4)**:`need_MiB = estimated_weight_size_gb × 1024 × 1.5`;`Σ(可用卡 free) < need_MiB` → `blocked: ["gpu_vram_insufficient: free=XGB, need=YGB"]`;推荐卡数 `ceil(need_MiB / (30×1024))`
- **前提**:聚合判定仅当项目支持多卡切分(README/代码有 device_map="auto"/torchrun --nproc/TP 迹象);单体模型按最大单卡 free 判
- GPU 不够但 README 有 API 端点 → 不 block,`warnings: ["api_route_available"]` + `gpu_picks: []` + entry_script="api-skeleton"

### 磁盘
`df -BG /root` 的 free ≥ estimated_weight_size_gb + 50 → ok;否则 `blocked: ["disk_low: ..."]`。

### Gated(eagle 实测教训,必须试探下载)
```bash
curl -s "https://huggingface.co/api/models/<org>/<name>" | jq -r '.gated // "false"'
# gated != false 的每个 repo 必须实测(auto-gated 也要求账号先接受 license):
HF_HOME="$WORKSPACE/.cache/huggingface" hf download <repo> config.json --token "$HF_TOKEN" 2>&1
```
- 成功 → `gated_check[repo]="ok"`
- 401/Unauthorized → `blocked: ["gated_no_token: <repo>"]`
- **403 / "Access denied" / "requires approval" / "Cannot access gated repo"** → `blocked: ["gated_needs_approval: <repo>"]`(token 有但账号没获批,**不算 ok**)
- "Network is unreachable"/超时 → 试探不可信,**严禁据此 gated_ok=true**,`blocked: ["preflight_network_error: <repo>"]`

### 30B
`estimated_params_b > 30` → `blocked: ["model_too_large"]`(主 agent 应已过滤,double check)。

## 6. 失败处理

`blocked` 非空 → 写 `pending_human/<slug>.md`(格式:原因类别/我尝试过什么/被卡在哪/建议人手做的事/上下文;末尾注明"处理完删本文件");jq 更新 state `phase=paused_for_human` + `.pending_human={reason,written_to,ts}`。不要自己重试。

## 7. 落盘 + 返回

jq 更新 state:`.phase="fetching" | .phases_done += ["intake"] | .intake_result=<result> | .status="done" | .updated_at=now`(blocked 时不切 phase)。

`results/intake.json` 用 **bash heredoc** 写(❌ 严禁用文件写工具原样写含 `$(date)` /`<占位符>` 的模板 — 会落成字面量):

```json
{
  "entry_script": "...", "hf_deps": [...], "weight_target_paths": [...],
  "gpu_picks": [...], "blocked": [], "warnings": [],
  "python_version": "...", "python_version_confidence": "high|low",
  "preflight": {"gated_ok": true, "free_disk_gb": 0},
  "ready_to_fetch": true, "completed_at": "<date -Iseconds 求值>"
}
```

```bash
echo "==== intake end ====" >> "$LOG"
echo "=== PHASE_END   phase=intake slug=$SLUG status=done ts=$(date -Iseconds) ==="
```

**返回 summary 必须原样包含上面完整 JSON**(主 agent 只能看到 summary)。
