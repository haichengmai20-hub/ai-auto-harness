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
4. `no_proxy` 不含 `huggingface.co`，所有 HF 流量走代理

## 三种解法（按优先级）

### 方案 A：no_proxy 加 HuggingFace 域名（推荐，已落地）

```bash
# launch_worker.sh / daily.sh 已加，env-level 生效
export no_proxy="${no_proxy:+$no_proxy,}huggingface.co,.huggingface.co,cdn-lfs.huggingface.co,huggingface-ml-artifacts.s3.amazonaws.com"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}huggingface.co,.huggingface.co,cdn-lfs.huggingface.co,huggingface-ml-artifacts.s3.amazonaws.com"
```

优点：env-level 设一次，所有子进程继承，SubAgent 无需额外操作。
注意：`setsid nohup bash -c` 子 shell 需确认 no_proxy 被继承（通常会被继承，但最好也 unset proxy 做双保险）。

### 方案 B：unset proxy（双保险，fetch-weights SKILL.md 已加）

```bash
# 每次 hf download 前执行
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
```

优点：最彻底，完全不走路由表里的代理。
注意：只影响当前 shell 及子进程，不影响全局。

### 方案 C：降并发 --num-workers 1（兜底）

```bash
HF_HUB_DOWNLOAD_CONCURRENCY=1 hf download <repo> --local-dir <path> --token "$HF_TOKEN"
```

优点：即使走代理也不会打爆连接池。
注意：速度较慢（单连接），仅在前两种方案无效时使用。

## 推荐组合

**方案 A + B 组合**：launch_worker.sh 设 `no_proxy`（方案 A），SubAgent 每次 bash 再 `unset proxy`（方案 B），双保险。

## 验证直连是否生效

```bash
# 不走代理
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
curl -sI https://huggingface.co/api/models/google/magenta-realtime-2 | head -3
# 期望: HTTP/2 200（直连成功）

# 对比: 走代理
HTTPS_PROXY=http://172.16.6.179:61080/ curl -sI https://huggingface.co/api/models/google/magenta-realtime-2 | head -3
# 可能: HTTP/1.1 503（代理打爆）
```

## 相关

- Fix: [2026-06-08-proxy-hf-download-503-fix.md](../docs/superpowers/fixes/2026-06-08-proxy-hf-download-503-fix.md)
- SKILL: [.claude/skills/fetch-weights/SKILL.md](.claude/skills/fetch-weights/SKILL.md) 硬规则 8
