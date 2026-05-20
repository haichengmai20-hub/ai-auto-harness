---
name: coverage-gaps
description: 跨日盲区追踪 — 看近 N 天哪些 scenario 0 次成功部署,给报告写"是否加权重"提示
allowed-tools: [Read, Bash, mcp__ai_daily_scan__*]
---

# coverage-gaps

## 触发

`write-recommendation` skill 写报告时调本 skill,产出"## 跨日盲区"段内容.

借鉴 ai-daily-scan 的设计:**已知"盲区"信息**(连续 N 天某业务线 0 命中)是产品决策的重要信号,平台主动暴露它能帮老板/产品同事 catch 这种"信号缺失".

## 你的输入

```json
{
  "days": 7,
  "company_scenarios": ["scenario_001", "scenario_002", ..., "scenario_007"]
}
```

(默认 days=7;company_scenarios 从 `/root/ai-daily-scan/config/company_profile.jsonl` 抽,有 7 条业务线)

## 工作流

### 第 1 步:读 outcomes.jsonl(scan 那边 CC 回填的)

```bash
OUTCOMES="/root/ai-daily-scan/state/outcomes.jsonl"
# 近 N 天 status=passed 的
jq -c "select(.ts > \"$(date -d "$DAYS days ago" -Iseconds)\" and .status == \"passed\")" "$OUTCOMES" 2>/dev/null
```

### 第 2 步:同时拉 scan 的 findings 历史 看 scenario_hits

```python
recent = mcp__ai_daily_scan__get_recent_findings(days=DAYS)
# 每条 finding 有 scenario_hits 字段
```

把 outcomes 和 findings 用 slug 关联:

```python
deploy_outcome = {o["slug"]: o["status"] for o in outcomes}
# scenario → 关联的 passed 项目数
scenario_deploys = defaultdict(int)
scenario_attempts = defaultdict(int)
for f in recent:
    slug = f["slug"]
    status = deploy_outcome.get(slug, "untried")
    for scenario in f.get("scenario_hits", []):
        scenario_attempts[scenario] += 1
        if status == "passed":
            scenario_deploys[scenario] += 1
```

### 第 3 步:找盲区

```python
# 公司 7 业务线
all_scenarios = company_scenarios  # ["scenario_001", ..., "scenario_007"]

scenario_label = {  # 从 company_profile.jsonl 读 name 字段
    "scenario_001": "AI 聊天/虚拟陪伴",
    "scenario_002": "图像生成/编辑",
    "scenario_003": "视频生成/编辑",
    "scenario_004": "文档/笔记/OCR/翻译",
    "scenario_005": "AI 音乐/音频创作",
    "scenario_006": "社媒内容工具",
    "scenario_007": "综合创作工作台",
}

gaps = []
for s in all_scenarios:
    attempts = scenario_attempts.get(s, 0)
    deploys = scenario_deploys.get(s, 0)
    label = scenario_label.get(s, s)
    if deploys == 0 and attempts == 0:
        gaps.append({
            "scenario": s, "label": label,
            "kind": "blind_spot",  # scan 都没扫到这个场景的项目
            "msg": f"近 {DAYS} 天 scan 0 命中 — 是否要在 scan 的 search query 加权重?"
        })
    elif deploys == 0 and attempts > 0:
        gaps.append({
            "scenario": s, "label": label,
            "kind": "deploy_fail",  # 扫到了但部署都没成功
            "msg": f"近 {DAYS} 天 scan 推荐了 {attempts} 个候选但 0 成功部署 — 设计/资源/审批阻塞?"
        })
    elif deploys < attempts // 3:
        gaps.append({
            "scenario": s, "label": label,
            "kind": "deploy_low",
            "msg": f"近 {DAYS} 天 scan 推荐 {attempts} 个,只 {deploys} 个成功部署({deploys*100//attempts}%)— 命中率偏低"
        })
```

### 第 4 步:产报告 markdown 段

```markdown
**近 `<DAYS>` 天部署覆盖**(7 条业务线):

| 业务线 | 候选数 | 成功数 | 覆盖率 |
|---|---|---|---|
| scenario_001 (AI 聊天/陪伴) | 3 | 2 | 67% |
| scenario_005 (AI 音乐/音频) | 1 | 1 | 100% |
| scenario_003 (视频生成) | 2 | 0 | **0%** ⚠️ |
| scenario_007 (综合工作台) | 0 | 0 | — |

**盲区与建议**:
- ⚠️ scenario_003(视频生成):近 7 天 scan 推荐了 2 个但部署都没成功 — 是 gated repo 卡了还是 GPU 显存不够?见 pending_human/ 检查
- 💡 scenario_007(综合工作台):近 7 天 scan 0 命中 — 是否值得在 search query 加权重?
- ✅ scenario_005(AI 音乐):本月有突破(SongGeneration 跑通)
```

(没盲区时简单写"近 X 天 7 条业务线均有命中且部署成功")

## 返回 schema

```json
{
  "days_window": 7,
  "scenario_stats": {
    "scenario_001": {"attempts": 3, "deploys": 2, "rate": 0.67},
    ...
  },
  "gaps": [
    {"scenario": "scenario_003", "kind": "deploy_fail", "msg": "..."}
  ],
  "markdown_section": "<完整 markdown 段,供 write-recommendation 拼到报告>"
}
```

## 反模式

- ❌ 不要把 7 条业务线全部列出来(太长),只列**有数据或盲区**的
- ❌ 不要把"建议"写成"必须" — coverage-gaps 是参考信号,不是命令
- ❌ 不要单天 outcomes 就下结论(N 至少 7 天,周/月周期更稳)
- ❌ 不要遗漏 attempts=0 的 scenario(那才是真盲区)
