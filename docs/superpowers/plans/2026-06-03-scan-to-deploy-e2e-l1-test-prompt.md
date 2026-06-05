# scan-to-deploy E2E L1 Test Prompt

> Fix: `docs/superpowers/fixes/2026-06-03-scan-to-deploy-never-e2e-verified-fix.md`

## 目标

验证 `/auto-daily` 的 scan → pick → intake 前半链路,只跑到创建 `workspace/<slug>/state.json` 和 intake artifacts,不下载权重、不装环境、不跑推理。

## 前置检查

```bash
cd /root/ai-auto-harness
bash scripts/healthcheck-mcp.sh
bash scripts/healthcheck-daemon.sh
```

## 启动方式

用 worker 保留 hooks/skills,不要用 `--bare`:

```bash
cd /root/ai-auto-harness
RUN_ID="scan-to-deploy-l1-$(date +%Y%m%d-%H%M%S)"
bash cron/launch_worker.sh \
  "请使用 auto-daily skill 跑 L1: 调 ai_daily_scan scan_today/get_recent_findings,选择 1 个候选,只 dispatch intake-agent;intake 完成后停止,不要 fetch-weights/install/run/verify。验收 workspace/<slug>/state.json 存在且 results/intake.json 存在。" \
  "runs/$RUN_ID"
```

## 验收

```bash
cd /root/ai-auto-harness
latest="$(ls -td runs/scan-to-deploy-l1-* | head -1)"
bash scripts/validate-run-discipline.sh "$latest/harness.stdout.ndjson"
find workspace -maxdepth 2 -name state.json -newer "$latest/meta.json" -print
```

期望:

- `scripts/healthcheck-mcp.sh` PASS。
- `discipline-report.json` 中 `task_called >= 1`。
- 至少一个新/接续 workspace 有 `state.json`。
- 对应 workspace 有 `results/intake.json`。
- 不应出现 `hf download` / `pip install` / run-and-repair 命令。

## 失败判定

- MCP 工具缺 `scan_today/get_recent_findings/record_outcome/analyze_project` → 修 MCP 配置或 `/root/ai-daily-scan/mcp_server.py`。
- `task_called=0` 且 Bash 大量增长 → 回到 R9 fix,hook/skill 约束未生效。
- 直接进入 fetch/install → L1 prompt 未被遵守,重跑并明确“只到 intake 停止”。
