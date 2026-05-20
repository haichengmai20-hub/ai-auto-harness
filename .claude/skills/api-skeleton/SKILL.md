---
name: api-skeleton
description: 不能 self-host 时(>30B / gated 无 token / 资源不足)产 API 调用骨架 + 中文使用指导
allowed-tools: [Read, Write]
---

# api-skeleton

## 触发条件(主 agent 调你的时机)

| 触发 | 说明 |
|---|---|
| `estimated_params_b > 30` | 模型太大,5090 自部署 ROI 差 |
| intake `blocked=["gated_no_token"]` | gated repo 短期解决不了 |
| intake `blocked=["gpu_insufficient"]` + 持续 | 资源短缺 |
| `next_action="try_api_pilot"` | scan 直接判定走 API |

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "github_url": "...",
  "hf_repos": ["..."],
  "scan_finding": {  // 整个 Finding dict 透传
    "title": "...",
    "description": "...",
    "cost_estimate": {...},  // 若 scan 有给
    "estimated_params_b": ...,
    ...
  },
  "reason": "model_too_large | gated_no_token | resource_shortage | api_pilot_directly"
}
```

## 工作流(纯写文件,不跑代码)

### 第 1 步:创建骨架目录

```bash
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
mkdir -p "$WORKSPACE/api_skeleton"
```

### 第 2 步:选 API provider(优先级)

读 `scan_finding` 看是否提到具体 API。优先级:

1. **项目官方 API**(若 scan 提到、若 GitHub README 有)
2. **HuggingFace Inference API**(若是公开模型,有专属 endpoint)
3. **第三方托管**:OpenRouter / Together / Replicate / WaveSpeed 等
4. **自建反代**(若用户能自部署一个 vLLM/TGI 服务,LLM 调用走自家)

记录选哪个到 `api_route_chosen`.

### 第 3 步:写 `client.py`(最小可调用)

模板:

```python
"""<slug> — API client

用法:
    from client import <SlugCamelCase>Client
    c = <SlugCamelCase>Client()
    print(c.generate(prompt="..."))
"""
from __future__ import annotations

import os
from typing import Any

import httpx


class <SlugCamelCase>Client:
    """最小化 API 客户端 — retry / timeout / error handling 备好"""

    def __init__(self, api_key: str | None = None, base_url: str | None = None,
                  timeout_sec: float = 60.0):
        self.api_key = api_key or os.environ.get("<SLUG_UPPER>_API_KEY")
        if not self.api_key:
            raise RuntimeError(
                f"<SLUG_UPPER>_API_KEY env var missing. "
                f"See 使用指导.md 配置"
            )
        self.base_url = (base_url or os.environ.get(
            "<SLUG_UPPER>_BASE_URL", "<provider endpoint>"
        )).rstrip("/")
        self.timeout = timeout_sec

    def generate(self, prompt: str, **kwargs: Any) -> dict:
        """单次生成 — kwargs 透传到 API body"""
        resp = httpx.post(
            f"{self.base_url}/v1/<endpoint>",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json={"prompt": prompt, **kwargs},
            timeout=self.timeout,
        )
        resp.raise_for_status()
        return resp.json()


if __name__ == "__main__":
    # 命令行 smoke
    import sys
    c = <SlugCamelCase>Client()
    result = c.generate(prompt=sys.argv[1] if len(sys.argv) > 1 else "<default test prompt>")
    print(result)
```

Write 到 `$WORKSPACE/api_skeleton/client.py`.

实际写时要按项目类型替换:
- **文本**:endpoint `/v1/chat/completions`,body `{"messages": [...]}`
- **图像**:endpoint `/v1/images/generations`,body `{"prompt": "...", "n": 1, "size": "..."}`
- **音频**:endpoint `/v1/audio/generations` 或类似,body `{"text": "..."}`
- **视频**:endpoint `/v1/video/generations`,body `{"prompt": "...", "duration": 5}`

### 第 4 步:写 `smoke_test.py`

```python
"""smoke test — 最小调用验证 API + 凭证 OK"""
from client import <SlugCamelCase>Client


def main():
    c = <SlugCamelCase>Client()
    # 用项目相关的简单 prompt
    result = c.generate(prompt="<simple test prompt 项目相关,如音乐用 'simple beat'>")
    print("SMOKE OK")
    print(result)


if __name__ == "__main__":
    main()
```

### 第 5 步:写 `.env.example`

```bash
# <slug> API 凭证
# 1. 去 <provider 注册页> 注册
# 2. 创建 API key,粘贴到此处
# 3. cp .env.example .env  &&  填值
# 4. python smoke_test.py

<SLUG_UPPER>_API_KEY=
<SLUG_UPPER>_BASE_URL=<default endpoint>
```

### 第 6 步:写 `使用指导.md`(中文)

模板:

```markdown
# <项目名> API 路线使用指导

> 由 ai-auto-harness 自动生成 — 触发原因:<reason>

## 项目简介

<从 scan_finding.description 抄一段;若没有,看 hf_repos 第一个 model card 摘 1-2 句>

**核心能力**:<scan_finding 提到的能力,比如"文生图"/"长上下文 LLM"等>

**为什么不走 self-host**:

<按 reason 选段>

**reason = model_too_large**:
项目模型参数量 `<X>B`,超过本平台 self-host 阈值 30B.
自部署需要 `<N>` 张 5090 分片(单卡 32GB),GPU 月成本约 `<¥M>`/月(按 ¥2.5/卡/h × 24h × 30d × N).
API 路线月成本约 `<¥M2>`/月(scan 估算),性价比明显占优.

**reason = gated_no_token**:
项目使用 gated repo `<repo>`,需要:
1. 去 https://huggingface.co/`<repo>` 网页点 "Agree to share contact info" 同意 license
2. 去 https://huggingface.co/settings/tokens 创建 read token
3. 在 `/root/ai-auto-harness/.env` 加 `HF_TOKEN=hf_xxx`
4. 删除 `pending_human/<slug>.md` 让平台重新尝试 self-host

完成上述 4 步后可重新跑 `/auto-deploy <github_url>`(self-host 路线);或继续走本 API 方案.

**reason = resource_shortage**:
当前 5090 集群资源不足以分配给本项目.可:
1. 等其他项目跑完释放 GPU,重新尝试 self-host
2. 或直接走本 API 方案

## 注册 + 拿 API key

<具体步骤,含链接>

例(若是 OpenRouter):
1. 打开 https://openrouter.ai/keys
2. 用 GitHub / Google 登录
3. 点 "Create Key",输入名称,选 "All models" 或限定 `<model>` 路径
4. 复制 `sk-or-v1-xxx` 形式的 key

## 配置

```bash
cd /root/ai-auto-harness/workspace/<slug>/api_skeleton
cp .env.example .env
# 编辑 .env,填入 API_KEY
```

## 跑 smoke test

```bash
pip install httpx
python smoke_test.py
```

预期输出:`SMOKE OK` + 一段生成结果.

## 成本对比(双路)

| 路线 | 月度估算 | 优点 | 缺点 |
|---|---|---|---|
| API | ¥`<X>` | 即开即用 / 无运维 / quota 按需 | 单次 ~$`<Y>` / QPS 受限 / 数据出墙(隐私) |
| Self-host | ¥`<Z>` | 单次成本低 / 无限并发 / 数据可控 | 需 N 卡 + 运维 / 模型可能不完全开源 |

## 上线建议

- **灰度**:接 1 个产品 / 1% 流量,跑 1-2 周看 P95 延迟 / error_rate
- **监控**:QPS / latency / error_rate / 月度成本曲线
- **降级方案**:
  - 同 vendor 平替模型(列 1-2 个)
  - 切回 self-host 的触发条件(如月成本 > ¥`<阈值>` 时迁移)
- **合规**:`<provider>` 数据处理条款链接 + 内部隐私评审清单

## 后续

- 若觉得 API 效果好但贵 → 考虑 self-host(等本平台条件满足)
- 若效果不达预期 → 看 scan 报告里的"竞品对比"段,可能有更合适的 model
```

### 第 7 步:更新 state.json

```bash
jq --arg ph done \
   --arg route "$API_ROUTE" \
   --arg sk "$WORKSPACE/api_skeleton" \
   '.phase = $ph
    | .phases_done += ["api_skeleton"]
    | .api_skeleton_result = {skeleton_path: $sk, api_route_chosen: $route, ready: true}
    | .updated_at = "'$(date -Iseconds)'"' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

## 返回 schema

```json
{
  "skeleton_path": "/root/ai-auto-harness/workspace/<slug>/api_skeleton",
  "ready": true,
  "api_route_chosen": "official | hf_inference | openrouter | together | wavespeed | self_hosted_proxy",
  "files_written": ["client.py", "smoke_test.py", ".env.example", "使用指导.md"]
}
```

## 反模式

- ❌ 不要试图真的调 API(没 API key,smoke 由人手跑)
- ❌ 不要让 client.py 复杂化(retry / 池化 / 流式 — 先 minimal,人需要时自己加)
- ❌ 不要把 API_KEY 直接写到代码里(必须用 env var)
- ❌ 不要在使用指导里写虚的"建议接入 monitoring"— 给具体可执行步骤
- ❌ 不要把 client.py / smoke_test.py 写到 workspace/<slug>/repo/(那是项目 git clone 的);写到 workspace/<slug>/api_skeleton/(我们自己的)
