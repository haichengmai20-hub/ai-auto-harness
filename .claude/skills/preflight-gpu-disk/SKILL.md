---
name: preflight-gpu-disk
description: GPU / 磁盘 / gated repo / 模型规模 资源 preflight 子能力 — intake / install skill 调
---

# preflight-gpu-disk

intake / install 阶段调本子能力做资源 preflight。

## GPU preflight

```bash
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader,nounits
```

输出每张卡 `index, used_MiB, free_MiB, total_MiB`(MiB)。

**判定规则**:
- 单卡 `used ≥ 25000`(MiB,即 ~25GB)→ 该卡**不参与分配**
- 其余卡按 `free` 降序,取 Top N(N=项目需要的 GPU 数,从 README/config 推断)
- 选中卡 `free ≥ 项目预估需求(MiB)+ 2048`(2GB safety) → ok
- 否则 → `blocked.append("gpu_insufficient")`

**空闲显存聚合检查 (2026-06-11 P4 fix)**:
- 单卡空闲检查不够 — 即使 N 张卡各自有足够空闲，也需验证**总计空闲 VRAM ≥ 模型总需求**
- 计算: `sum_free_MiB = Σ(可用卡的 free_MiB)`, `need_MiB = estimated_weight_size_gb * 1024 + 4096`(4GB safety for activations/KV cache)
- `sum_free_MiB < need_MiB` → `blocked.append("gpu_vram_insufficient: free=<sum_free/1024>GB, need=<need/1024>GB, recommend=<ceil(need/32768)> cards")`
- 同时输出推荐 GPU 数: `recommended_gpus = ceil(model_params_b * 2 / 32)` (BF16, 32GB per card, with overhead)
  - 例: 14B → 14*2/32 ≈ 1, 但加 T5+CLIP+VAE ≈ 42GB → ceil(42/32) = 2 太紧 → 实际需 ceil(42+8/32) = 3~4 卡

**API skeleton 降级 (2026-06-11 P4 fix)**:
- 如果 `blocked` 含 `gpu_insufficient` 或 `gpu_vram_insufficient`,**且**项目有可用 API 端点(README 提到 OpenAI API / gradio client / REST endpoint):
  - 不直接 blocked,而是在 `warnings` 加 `"api_route_available: 可走 API 调用绕过 GPU 限制"`
  - `gpu_picks = []`, `entry_script = "api-skeleton"` — 让后续阶段走轻量 API 调用路径

## 磁盘 preflight

```bash
df -h /root | awk 'NR==2 {print $4}'  # Avail 字段
```

把 `<value>G` 转 GB int(去掉 G/M 后缀)。

**判定**:
- `free_gb ≥ estimated_weight_size_gb + 50` → ok
- 否则 → `blocked.append("disk_low: free=<X>GB, need=<Y>GB")`
- 同时提示用户清理 `/root/core.*` 或 `workspace/` 老项目

## Gated Repo preflight

对 `hf_repos[]` 中每个 repo:

```bash
curl -s "https://huggingface.co/api/models/<org>/<name>" | jq -r '.gated // "false"'
```

- 输出 `"manual"` 或 `"auto"` → 是 gated
- 输出 `"false"` / null → 公开

对每个 gated repo,**必须**试探下载小文件(不能只看 `.gated` 字段 + "有 HF_TOKEN" 就放行——auto-gated 也要求该账号先在 HF 网页接受 license):

```bash
HF_HOME="$WORKSPACE/.cache/huggingface" hf download <repo> config.json --token "$HF_TOKEN" 2>&1
```

按输出分类(2026-06-10 eagle 实测教训):

- 成功 → 该 token 账号已获批,`gated_check[repo]="ok"`
- 含 "401" / "Unauthorized" → `blocked.append("gated_no_token: <repo>")`
- 含 **"403" / "Access denied" / "requires approval" / "Cannot access gated repo"** → `blocked.append("gated_needs_approval: <repo>")` — token 有但账号没接受 license/没过审,**不算 gated_ok**
- 含 "Network is unreachable" / "Connection" / 超时 → **试探不可信,严禁据此给 gated_ok=true**,`blocked.append("preflight_network_error: <repo>")`,这是基础设施问题先修网络

## 模型规模 preflight

```python
# 主 agent 传入 estimated_params_b
if estimated_params_b > 30:
    blocked.append(f"model_too_large: {estimated_params_b}B > 30B threshold")
```

主 agent 应该已过滤,这里 double check。

## 返回

```json
{
  "gpu_picks": [3, 4],
  "blocked": [],
  "free_disk_gb": 580,
  "gated_check": {"<repo>": "ok|needs_token"}
}
```

## ChangeLog

- **2026-06-10** — gated 试探分类扩展(403/Access denied)+ 网络不可达不许放行 + huggingface-cli → hf
  - 变更类型: 硬约束 + schema 语义
  - 影响范围: Gated Repo preflight 段
  - 动机: eagle(nvidia/Eagle2.5-8B)gated-未获批返回 403 "Access denied. This repository requires approval.",旧文只认 401 → intake 给了 `gated_ok: true`,fetch 阶段才撞 403 浪费整个 run;且当时断网导致试探 inconclusive 也被放行;试探命令还在用已废弃的 huggingface-cli(R7)
  - 证据: [fixes/2026-06-10-no-proxy-pollution-gated-403-fix.md](../../../docs/superpowers/fixes/2026-06-10-no-proxy-pollution-gated-403-fix.md)
  - 验证: ✅ `hf download nvidia/Eagle2.5-8B config.json --token $HF_TOKEN` 稳定复现 403 文案
