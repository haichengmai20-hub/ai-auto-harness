# Phase 2 测试 Setup(待执行)

> **状态**:等用户的另一个方案测完后再来测试  
> **目的**:验证 fetch-weights / install-env / run-and-repair 三个 SubAgent 真机能跑通

## 测试目标项目

**SongGeneration**(腾讯 AI Lab 开源音乐生成大模型)

- 来源:`/root/ai-daily-scan/2026-05-12_090001_report.md` 推荐 — TOP 3 之首
- GitHub URL:`https://github.com/tencent-ailab/SongGeneration`
- HF Repos:`["tencent/SongGeneration"]`
- 估算参数:4B(v2-large)
- 估算权重大小:~15GB
- Gated:否
- 推荐路线:self_host_5090(我们要测的)

## 测试 setup(逐步)

### 前置约束

- **绝对不动** `/root/auto-deploy-agent/workspace/fb4944c4334b-SongGeneration/`
  (那是用户跑过的旧目录,含 sample/output/jsonl 等结果)
- 我们的所有产物都在 `/root/ai-auto-harness/workspace/song-generation/`(新建,隔离)
- HF cache 走 workspace 内部隔离,**绝不**污染 ~/.cache/huggingface

### 跳过 scan 测试,直接测 deploy(用户决定)

塞 fake finding 让 /auto-daily 直接选这个项目:

```bash
mkdir -p /root/ai-daily-scan/state
cat > /root/ai-daily-scan/state/findings.jsonl <<'EOF'
{"slug":"song-generation","title":"SongGeneration","description":"腾讯 AI Lab 开源音乐生成大模型","github_url":"https://github.com/tencent-ailab/SongGeneration","hf_repos":["tencent/SongGeneration"],"estimated_params_b":4,"estimated_weight_size_gb":15,"gated_repos":[],"scenario_hits":["scenario_005"],"recommended_route":"self_host_5090","next_action":"try_deploy_self_host","source_urls":["https://github.com/tencent-ailab/SongGeneration"],"confidence":"high","scan_ts":"2026-05-19T09:00:00","scan_report_path":"reports/2026-05-19_090001_report.md"}
EOF
```

### 启动命令

```bash
cd /root/ai-auto-harness && ./bin/claude-haha \
  --bare \
  --add-dir . \
  --settings .claude/settings.json \
  --print "/auto-daily"
```

(`--bare` 模式:跳 OAuth / keychain / plugin sync;skill / settings / CLAUDE.md 通过 flag 显式注入)

### 监控点(只读,不干扰)

每 60s 看一次:

```bash
# 1. 当前阶段
cat workspace/song-generation/state.json | jq '{phase, phases_done, updated_at}'

# 2. 下载进度(若在 fetch 阶段)
cat workspace/song-generation/progress.md 2>/dev/null
tail -10 workspace/song-generation/progress_*.log 2>/dev/null

# 3. agent 决策轨迹
cat runs/*/decisions.md 2>/dev/null
```

### 预期阶段时间

| 阶段 | 预计耗时 | 关键观察 |
|---|---|---|
| intake | 1-2 min | git clone 完 + state.json phase=fetching |
| fetch-weights | 15-30 min | progress.md 进度增长 + 15GB 下完 |
| install-env | 5-15 min | venv 建好 + torch sm_12 兼容(可能要装 nightly cu124)|
| run-and-repair | 3-10 min | 跑 SongGen sample 出音频文件 |
| verify | 2-3 min | smoke test 通过 |
| **总计** | **30-60 min** | |

### 成功判定

- `workspace/song-generation/state.json` phase=done
- `runs/*/run.json` passed=true
- `runs/*/verify.json` passed=true
- `reports/<date>.md` 含 song-generation 段
- `/root/ai-daily-scan/state/outcomes.jsonl` append 了 status=passed

### 同时跟用户方案做对比(用户已在跑另一方案)

跑完后对比:
- 总耗时
- 每阶段耗时
- 自主修复次数(我们 fixes_applied vs 他们手工干预次数)
- 输出质量(生成的歌曲音频对比)
- API token 消耗
- 失败模式(若有)

### 暴露设计缺陷的关键测试点(我们最想验证的)

1. **SubAgent dispatch**:Task 工具能否按 subagent_type 派出 — 没测过
2. **fetch-weights 的 background bash**:`setsid nohup huggingface-cli & ` 在 `--print` 里行不行
3. **`--print` 长跑**:30+ 分钟会不会中断(R3 红色风险)
4. **跨 cron 接续**:若 R3 中断,下次 cron 重启能否接续(R2)
5. **install-env 的 sm_12 检测**:能否正确识别 sm_12 缺失并装 nightly
6. **run-and-repair 的 3 轮上限**:LLM 会不会在第 3 轮真停下来

### 失败情况下的清理(若我们的跑跑岔了)

```bash
# 仅清理我们自己的 workspace,绝不动 /root/auto-deploy-agent/
rm -rf /root/ai-auto-harness/workspace/song-generation/
rm -rf /root/ai-auto-harness/runs/cron-*  # 若有
```

旧目录 `/root/auto-deploy-agent/workspace/fb4944c4334b-SongGeneration/` 永远不动。
