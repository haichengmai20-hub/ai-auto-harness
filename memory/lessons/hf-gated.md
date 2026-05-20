# HuggingFace Gated Repo 处理

> 通用经验:任何 SubAgent 拉 HF 权重时遇到 401 / Unauthorized 都读本文件。

## 现象

- `huggingface-cli download <repo>` 返回 **401 Unauthorized**
- 或 web 上看 repo 顶部有 "You need to accept terms of use" 横幅
- 或 `curl -s https://huggingface.co/api/models/<repo>` 的 `.gated` 字段是 `"manual"` 或 `"auto"`

## 探测方法(intake preflight 用)

```bash
curl -s "https://huggingface.co/api/models/<org>/<name>" | jq -r '.gated // "false"'
```

- `"manual"` / `"auto"` → gated
- `"false"` / null → 公开

## 已知 gated repo 列表(平台经验 cache,持续更新)

- `black-forest-labs/FLUX.1-schnell` — manual,需要网页同意 + HF_TOKEN
- `black-forest-labs/FLUX.1-dev` — manual
- `meta-llama/*`(Llama 全系列)— manual
- `mistralai/*`(部分)— manual
- `stabilityai/stable-diffusion-3-medium` — manual
- `google/gemma-*`(部分)— manual

## 处理流程

1. **检查 `$HF_TOKEN` 是否设置**:
   ```bash
   [ -n "$HF_TOKEN" ] && echo "token set" || echo "missing"
   ```

2. **没 token**:
   - 调 `request-human-intervention` skill
   - reason_category=`auth_missing`
   - what_blocked=`gated repo <repo> 需要 HF token`
   - next_steps_suggested:
     - 去 https://huggingface.co/<repo> 网页 → 点 "Agree to share contact info" 同意 license
     - 去 https://huggingface.co/settings/tokens → 创建 read token
     - 把 token 加到 `/root/ai-auto-harness/.env`:`HF_TOKEN=hf_xxx`
     - 删除 `pending_human/<slug>.md` 让平台重新尝试

3. **有 token,先 smoke**:下载 repo 的 `README.md` 试探权限:
   ```bash
   HF_HOME="$WORKSPACE/.cache/huggingface" \
   huggingface-cli download <repo> README.md --quiet 2>&1
   ```
   - 成功 → 真正下载主权重
   - 401 → token 有但 **license 没同意**(不同于无 token)→ 走 step 2

## token vs license 区分

| 状态 | 表现 |
|---|---|
| 无 token | `curl -H "Authorization: Bearer $HF_TOKEN"` 返回 401 + `auth required` |
| 有 token 无 license | 返回 401 + `you need to be granted access` 或类似 |
| 有 token 有 license | 200 OK |

提示用户时要说清楚是哪一种。
