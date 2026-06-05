# Xet 传输不稳定 + 下载后完整性校验

> 通用经验:fetch-weights SubAgent 用 `hf download` 拉大文件(>1GB)卡死、或 run-and-repair
> 阶段报"模型文件损坏/截断"时读本文件。来源:Fix #30(controlfoley CLAP 模型 469MB vs 预期 2.2GB)。

## 现象

- `hf download` 在 Xet 后端(`transfer.xethub.hf.co`)反复 `tls handshake eof` + `403 Forbidden`,死循环卡 24h 无实质进度
- `.incomplete` 文件消失了(看起来"下完了"),但文件大小不足 → 传到 run-and-repair 才报错(推理崩)
- Xet 日志在 `<workspace>/.cache/huggingface/xet/logs/`

## 根因

- Xet 协议在网络不稳定时:(1) TLS 连接死循环 (2) 数据未完整写入但 `.incomplete` 被清理
- fetch-weights 旧判定只看"`.incomplete` 消失"=完成,**没有"下载正确"(文件大小比对)的判定**

## 兜底策略(fetch-weights 必做)

1. **先试 Xet,但设上限**:30min 内下载量增长 < 100MB → 判定 Xet 卡死,自动 fallback:
   ```bash
   HF_HUB_DISABLE_XET=1 hf download <repo> --local-dir <path> --token "$HF_TOKEN"
   ```
2. **TLS/403 循环 > 3 次** → 立即切普通 HTTP(`HF_HUB_DISABLE_XET=1`),不要硬等
3. `HF_XET_HIGH_PERFORMANCE=1` 从"推荐"降级为"可选,但必须有 fallback"

## 下载后完整性校验(不可省)

下完后比对实际文件大小 vs HF manifest(`siblings[].size`),差异 > 5% = 损坏,删掉重下:

```bash
bash scripts/validate-fetch-weights.sh <workspace> <repo_id> [local_dir]
```

- 在线:自动拉 `https://huggingface.co/api/models/<repo_id>` 当 manifest
- 离线/测试:传第 4 个参数 `manifest_json`(HF 形状 `{"siblings":[{"rfilename","size"}]}`)
- 回归测试:`bash scripts/tests/test-validators.sh`(含 469-vs-2200 size-mismatch case,复现 controlfoley 损坏)

## 反模式

- ❌ 只检查 `.incomplete` 消失就认为下载完成
- ❌ Xet `tls handshake eof` / `403` 循环 > 3 次还硬等(浪费 24h wall-clock + $20+ API)
- ❌ 下载完不比对大小,把半截文件传给 run-and-repair

## 关联

- Fix: `docs/superpowers/fixes/2026-06-03-fetch-weights-no-download-integrity-check-fix.md`(#30)
- Fix: `docs/superpowers/fixes/2026-06-02-fetch-weights-hf1.x-modernization-fix.md`(#27,hf 1.x 命令现代化)
- R 规则: R7(hf 1.x 对齐 + Xet)
- 校验脚本: `scripts/validate-fetch-weights.sh` / 测试: `scripts/tests/test-validators.sh`
