# Memory Index

> ai-auto-harness 的经验积累文件索引。新 SubAgent 启动时可读本索引了解有哪些经验可用。

## lessons/ — 通用踩坑经验（跨项目复用）

| 文件 | 内容 | 适用阶段 |
|---|---|---|
| `torch-sm12.md` | RTX 5090 sm_12 兼容性：torch nightly 安装、requirements.txt pin 冲突、numpy ABI | install-env, run-and-repair |
| `flash-attn-build.md` | flash-attn 编译失败：prebuilt wheel 选择、fallback 策略 | install-env, run-and-repair |
| `hf-gated.md` | HF gated repo token + license 同意流程 | fetch-weights |
| `xet-tls-unstable.md` | Xet 传输卡死(tls eof/403 循环)兜底切普通 HTTP + 下载后大小校验(防 469MB vs 2.2GB 截断) | fetch-weights |
| `monitor-patterns.md` | 陪跑监控经验库：进程异常、R 规则违反、hook 失效、deprecated 命令 | 所有阶段(monitor 用) |
