---
name: cost-analysis
description: 标准化双路成本表(API vs Self-host) — api-skeleton 内部调,统一输出格式
---

# cost-analysis

## 触发

`api-skeleton` skill 渲染"使用指导.md"里的成本对比表时调本 skill.

为什么?— `/root/ai-daily-scan` 的 Verifier 见过太多 LLM 自由发挥的成本数字(GPT-3 $0.02/1k tokens 这种 outdated 数据).抽出标准化算法 + 真实参数表,可控.

## 你的输入

```json
{
  "slug": "<project-slug>",
  "model_size_gb": 36,         // 总权重大小
  "params_b": 12,              // 激活参数量
  "is_moe": false,             // 若 MoE,GPU 显存按 active 算但 total 也要够
  "estimated_qps": 10,         // 预期峰值 QPS(用户场景估算)
  "avg_input_tokens": 2000,    // 平均输入 token 数
  "avg_output_tokens": 1000,
  "active_hours_per_day": 8,   // 活跃服务小时(峰值时段)
  "api_provider_pricing": {    // 若 scan_finding 有,可传入;否则用 fallback 表
    "input_per_million": 0.14,
    "output_per_million": 0.28
  } | null
}
```

## 工作流

### 第 1 步:API 路线月成本估算

```python
PRICING = api_provider_pricing or fallback_lookup(slug)  # 见下面"fallback 价表"

daily_input_tokens = estimated_qps * avg_input_tokens * active_hours_per_day * 3600
daily_output_tokens = estimated_qps * avg_output_tokens * active_hours_per_day * 3600

daily_cost_usd = (
    daily_input_tokens / 1_000_000 * PRICING["input_per_million"] +
    daily_output_tokens / 1_000_000 * PRICING["output_per_million"]
)
monthly_cost_usd = daily_cost_usd * 30
monthly_cost_cny = monthly_cost_usd * 7.0  # 汇率参考(写时标"按 7.0 汇率")
```

**fallback 价表**(若用户没传 pricing,用平台 cache 的当前 ~价):

```python
FALLBACK = {
    "text_llm_cheap":     {"input": 0.14,  "output": 0.28},   # DeepSeek-V4-Flash 类
    "text_llm_mid":       {"input": 1.0,   "output": 3.0},    # Qwen3-235B / Sonnet 4 类
    "text_llm_premium":   {"input": 5.0,   "output": 25.0},   # Claude Opus / GPT-5 类
    "image_gen":          {"per_image": 0.04},                # Flux / SD3
    "video_gen":          {"per_second": 0.06},               # LTX / Runway
    "audio_gen":          {"per_song": 0.05},                 # SongGen / Suno
}
# 根据 slug 关键字推断类型(粗略)
```

### 第 2 步:Self-host 路线月成本

```python
# 单卡 5090 32GB, 月成本 ¥2.5/卡/h * 24h * 30d = ¥1800/卡/月
GPU_HOURLY_RMB = 2.5
gpu_monthly = GPU_HOURLY_RMB * 24 * 30  # ¥1800

# 算需要几张卡(基于权重大小)
def gpus_needed(size_gb, is_moe, params_b):
    # 单卡 32GB 减去 framework overhead(~4GB) → 28GB usable
    per_card_usable = 28
    # FP16 推理 = 模型大小;若 MoE total 必须装下
    if is_moe:
        # MoE 全 expert 都得在 GPU 上,size_gb 是 total
        return ceil(size_gb / per_card_usable)
    else:
        # Dense:size_gb ~= params_b * 2(FP16)
        return ceil(size_gb / per_card_usable)

n_cards = gpus_needed(model_size_gb, is_moe, params_b)
monthly_cost_self_host = n_cards * gpu_monthly

# 但若 n_cards > 8,不可行(超出我们 8 卡上限)
feasible = n_cards <= 8
blocker = f"需要 {n_cards} 卡,超出本平台 8 卡上限" if not feasible else None
```

### 第 3 步:盈亏平衡 QPS 计算

```python
# 在多大 QPS 下 API 比 self-host 更贵?
# self_host_monthly = n_cards * 1800
# api_monthly(qps) = qps * tokens * 月秒 * unit_price
# 解 api_monthly == self_host_monthly 的 qps

breakeven_qps = self_host_monthly / (
    (PRICING["input_per_million"] * avg_input_tokens
     + PRICING["output_per_million"] * avg_output_tokens) / 1_000_000
    * active_hours_per_day * 3600 * 30 / 7.0  # 转 RMB
)
```

### 第 4 步:输出 markdown 表

```markdown
## 双路成本对比(基于 QPS=`<X>` / `<H>`h 活跃/天 / `<T>` tokens 平均)

| 路线 | 可行性 | 关键参数 | 月度估算 |
|---|---|---|---|
| API(`<provider>`) | ✅ | input `$<A>`/M / output `$<B>`/M | **¥`<M1>`/月**(按 `<rate>` 汇率) |
| 5090 Self-host | `<✅/❌>` | `<N>` 卡分片 / FP16 `<G>`GB VRAM | **¥`<M2>`/月** `<若不可行,写 blocker>` |

**盈亏平衡 QPS**:`<B-qps>`(超过此 QPS 自部署更划算;低于走 API)

**建议路线**:
- 当前估算 QPS=`<X>` 低于盈亏点 → API 路线占优
- 长期若 QPS 涨到 `<B-qps>` 以上,迁移 self-host(本平台可重新部署)

**备注**:
- API 价基于公开定价页(`<source url>`),可能调整
- Self-host 不含工程人力 / 灰度运维成本
- 若 self-host 需 LFS 拉权重,首次部署有 `<size>`GB 一次性下载成本
```

## 返回 schema

```json
{
  "api_cost": {
    "feasible": true,
    "monthly_cny": 51000,
    "unit_pricing": {"input_per_M": 0.14, "output_per_M": 0.28},
    "provider": "DeepSeek API"
  },
  "self_host_cost": {
    "feasible": true,
    "monthly_cny": 3600,
    "n_cards": 2,
    "vram_required_gb": 36,
    "blocker": null
  },
  "breakeven_qps": 0.7,
  "recommendation": "self_host_5090 — 当前 QPS 10 远超盈亏点 0.7",
  "markdown_table": "<完整表格>"
}
```

## 反模式

- ❌ 不要凭空写"Claude-Opus $0.001/1k token" 这种 outdated 数据
- ❌ 不要遗漏汇率说明(¥ 数字要标 "按 7.0 汇率")
- ❌ 不要把人力工程成本算进 self-host 月度(那是一次性 + 持续小额,单算)
- ❌ 不要遗漏 self-host 不可行的 blocker(显存超 8 卡 总量 → 必须 API)
