# 代理环境 HuggingFace 下载 503 处理

> 跨项目通用经验：公司 HTTP 代理环境下拉 HuggingFace 权重时遇到的 503 问题及解法。

## 现象

- `hf download` 报 `httpx.ProxyError: 503 Too many open connections`
- 下载卡死，长时间 0 增长
- LLM 重试起多个并发进程，加剧问题

## 根因

1. 公司 HTTP 代理（如 172.16.6.179:61080）连接池有限（约 10-20 并发）
2. `hf download` 默认 Xet 后端（`HF_XET_HIGH_PERFORMANCE=1`）起多个并发连接
3. 多连接 + 代理 = 打爆代理连接池 → 503

## 关键发现（实测验证）

**本机无直连外网能力**：`unset HTTPS_PROXY HTTP_PROXY` 后 curl 测试报 `[Errno 101] Network is unreachable`。
所以**不能 unset proxy 或加 no_proxy 绕过代理**，必须走代理但控制并发。

## 正确解法：禁 Xet + 降并发（已落地）

```bash
# launch_worker.sh / daily.sh 已加，env-level 生效
export HF_HUB_DISABLE_XET=1          # 禁 Xet 多连接后端，走普通 HTTP 单连接
export HF_HUB_DOWNLOAD_CONCURRENCY=2 # 限制并发连接数，不打爆代理

# SubAgent setsid 块内也需 re-export（子 shell 可能不继承）
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_CONCURRENCY=2
hf download <repo> --local-dir <path> --token "$HF_TOKEN"
```

**为什么不选其他方案**：
- ❌ `no_proxy` 加 `huggingface.co` → 本机无直连外网，加了也没用（Network is unreachable）
- ❌ `unset HTTPS_PROXY HTTP_PROXY` → 同上，断网
- ❌ 继续用 Xet（`HF_XET_HIGH_PERFORMANCE=1`）→ Xet 起多个并发连接，打爆代理 → 503

## 验证代理下载是否正常

```bash
# 走代理 + 禁 Xet
HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_CONCURRENCY=2 \
  hf download google/magenta-realtime-2 --local-dir /tmp/test --token "$HF_TOKEN"
# 期望：开始下载，速度约 5-20MB/s（代理带宽限制）
```

## 相关

- Fix: [2026-06-08-proxy-hf-download-503-fix.md](../docs/superpowers/fixes/2026-06-08-proxy-hf-download-503-fix.md)
- SKILL: [.claude/skills/fetch-weights/SKILL.md](.claude/skills/fetch-weights/SKILL.md) 硬规则 8