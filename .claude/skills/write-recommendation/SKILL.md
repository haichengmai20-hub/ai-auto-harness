---
name: write-recommendation
description: 主 agent 写每日总报告 reports/<date>.md + 调 MCP record_outcome 回填给 scan
allowed-tools: [Read, Write, Bash, mcp__ai_daily_scan__record_outcome]
---

# write-recommendation

主 agent 在任务 4 调你。你的工作:**渲染人读的报告** + **回填机器可读的 outcome**.

## 你的输入(主 agent 传入)

```json
{
  "run_id": "<from 主 agent>",
  "run_results": [
    {
      "slug": "...",
      "status": "passed | failed | paused_for_human | api_route | skipped_too_large",
      "scan_finding": {...},
      "intake_result": {...},
      "fetch_result": {...},
      "install_result": {...},
      "run_result": {...},
      "verify_result": {...},
      "api_skeleton_result": {...},
      "runbook_path": "reports/runbooks/<slug>-<YYYY-MM-DD>.md" or null,
      "cleanup_result": { "removed_bytes": ..., "freed_gib": ..., "skipped_reason": ... } or null,
      "pending_human_path": "pending_human/<slug>.md" or null,
      "error_class": "..." or null,
      "phase_failed_at": "..." or null,
      "fixes_applied": ["..."],
      "repair_count": 0
    }
  ],
  "pending_human_files": ["pending_human/x.md", ...],
  "resource_snapshot": {"gpu_status": "...", "disk_free_gb": 459}
}
```

(MVP:单次 cron N=1,run_results 通常只有 1 项)

## 第 1 步:渲染 `reports/<YYYY-MM-DD>.md`

**覆写**(同一天可能多次 cron 重跑,要看最新).

Template(实际写时按 run_results 内容填):

```markdown
# AI Auto 报告 — <YYYY-MM-DD>

> 生成时间:<ts>  
> Run IDs:<run_id list>

## 总览

- 今日处理项目:<n_total>
- ✅ 成功 self-host:<n_pass>
- 🟡 走 API 路线:<n_api>
- ❌ 失败:<n_fail>
- ⏸️ 待人手处理:<n_human>

## 资源状况

- **GPU**:8 卡中 `<X>` 卡可用(>2GB free)
- **磁盘**:free `<gb>` GB <若 < 100 标 ⚠️>
- **当日 LLM 成本**:$`<sum>`(从当日各 `runs/cron-*/harness.stdout.ndjson` 末尾 `result` 事件抽 `total_cost_usd` 求和;**不含本 run**,本 run 的 result 事件在报告写完后才落)

<若磁盘 < 50GB,加 ALERT 段:>
> ⚠️ **磁盘 ALERT** — 建议清理:
> - `/root/core.*`(若仍有 dump 文件)
> - `workspace/` 中 7 天前未访问的项目

## 今日处理项目详情

### `<slug>` — `<title>`

- **路径**:`self_host_5090` | `api_pilot`
- **结果**:✅ PASS / 🟡 API_ROUTE / ❌ FAILED / ⏸️ PAUSED_FOR_HUMAN
- **阶段进展**:intake ✅ / fetch ✅ / install ✅ / run ⚠️ / verify ❌
- **公司视角**(从 scan_finding):
  - 命中场景:`<scenario_hits 比如 scenario_005(AI 音乐音频)>`
  - 推荐试点产品:`<pilot_product 若 scan 给了>`
  - 验收指标:`<success_metrics 头 2 条>`
- **本次部署摘要**:
  - 修复轮数:`<repair_count>` 轮
  - 修复内容:`<fixes_applied 列表>`
  - GPU 利用:`<gpu_snapshot 简略>`(若已跑通)
- **完整 trace**:[workspace/<slug>/runs/<run_id>/](workspace/<slug>/runs/<run_id>/)(legacy 全局 `runs/<run_id>/`)
- **部署 runbook**(若 `runbook_path`):[`<runbook_path>`](`<runbook_path>`) — 复现指南 + 踩坑速查
- **Workspace 已归档**(若 `cleanup_result.removed_bytes` > 0):释放 `<freed_gib>` GiB,保留 `state.json / results / logs / output`

<若 FAILED,加:>
- **失败原因**:`<error_class>`(阶段 `<phase_failed_at>`)
- **agent 决策轨迹**:`<workspace/<slug>/runs/<run_id>/decisions.md 摘要>`

<若 PAUSED_FOR_HUMAN,加:>
- **待人手处理**:[pending_human/`<slug>`.md](pending_human/`<slug>`.md)
- **类别**:`<reason_category>`
- **下一步**:见上述文件内"建议人手做的事"

<若 API_ROUTE,加:>
- **API 骨架**:[workspace/`<slug>`/api_skeleton/](workspace/`<slug>`/api_skeleton/)
- **API 路线**:`<api_route_chosen>`
- **下一步**:cd 到骨架目录 → cp .env.example .env → 填 API_KEY → python smoke_test.py

## 待人手处理积压(从 pending_human/ 索引)

| Slug | 类别 | 卡了几天 | 文件 |
|---|---|---|---|
| `<slug>` | `<category>` | `<days>` | [link](pending_human/`<slug>`.md) |

(列出 `pending_human_files` 全部 — 不只是今天处理的)

<若无积压,写:"今日无待人手处理项目。">

## 跨日盲区(可选,Phase 4 加 coverage-gaps skill 时填)

(MVP 阶段先留空,Phase 4 自动填)

## 下一步建议

<LLM 主动写,基于以上结果。例:

- SongGeneration 跑通,scenario_005(AI 音乐)线索成熟,建议技术团队 1 周内对接 DK Soundle 试点
- LTX-Video-2.3 待人手处理(gated repo)— 请运营同学拿 license + token
- 磁盘 free 即将低于 50GB — 周末清理一次 workspace
>

---
*生成依赖:claudecode_sourcecode1(--bare)+ ai-daily-scan MCP*
```

Write 到 `reports/<YYYY-MM-DD>.md`(用 `date +%Y-%m-%d`).

## 第 2 步:Bash 写入 + git add(因 --bare 跳了 SessionEnd hook,手动)

```bash
DATE=$(date +%Y-%m-%d)
mkdir -p reports
# 上一步已经 Write 到 reports/$DATE.md

# 手动 commit(不是必须,但报告变更追踪)
cd /root/ai-auto-harness
git add reports/$DATE.md memory/projects/ 2>/dev/null || true
git commit -m "auto-run $(date +%Y-%m-%d-%H%M): 报告 + memory 更新" 2>/dev/null || true
```

## 第 3 步:回填给 scan(MCP record_outcome)

```python
# 对每个 run_result 项调一次
for result in run_results:
    mcp__ai_daily_scan__record_outcome(
        slug=result["slug"],
        status=result["status"],  # passed | failed | paused_for_human | api_route | skipped_too_large
        run_id=run_id,
        error_class=result.get("error_class"),
        phase_failed_at=result.get("phase_failed_at"),
        notes=f"<简短 notes,如 'API 路线 OpenRouter,见 api_skeleton'>",
        repair_count=result.get("repair_count", 0),
    )
```

这步**不能跳** — scan 内部下次跑会读 outcomes.jsonl 自动 skip 已成功的项目(去重),也会影响 next_action 推荐.

**MCP 调用失败时的 fallback(2026-06-10 外部 review #20 采纳)** — 结果绝不能静默丢:

```bash
# record_outcome 抛错/超时 → 本地暂存,下次 cron 的 auto-daily 任务 1 重试回填
echo '{"slug":"<slug>","status":"<status>","run_id":"<run_id>","error_class":null,"notes":"...","ts":"'$(date -Iseconds)'"}' \
  >> /root/ai-auto-harness/state/outcomes-pending.jsonl
```

## 第 4 步:`workspace/<slug>/state.json` phase=done

```bash
WORKSPACE="workspace/<slug>"
jq '.phase = "done"
    | .completed_at = "'$(date -Iseconds)'"
    | .final_status = "<status>"' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

## 返回 schema

```json
{
  "report_path": "reports/2026-05-19.md",
  "outcomes_recorded": 1,
  "git_commit_attempted": true
}
```

## 反模式

- ❌ 不要写很长的报告 — 控制在阅读时间 < 3 分钟(总 < 200 行 markdown)
- ❌ 不要重复"今日总评"那种模糊段 — 我们的报告是"项目级 deploy 结果",不是"今日趋势"
- ❌ 不要忘记调 record_outcome — scan 不知道你跑过会重复推荐
- ❌ 不要把 SubAgent 内部决策轨迹原文搬进报告(太长)— 只摘 "改了 batch_size 4→1, OOM 解决"这种结论
- ❌ 不要尝试 git push — 那是用户的事,我们只 commit 本地
- ❌ 不要忘渲染 `runbook_path` 链接 — 它是下游 AI 复用本次部署的唯一入口
- ❌ 不要在 `runbook_path` 为 null 时强写链接(失败 case 也可能没 runbook)— 用 `<若 runbook_path:>` 守卫

## ChangeLog

- **2026-06-10** — 报告加当日 LLM 成本行 + record_outcome 失败 fallback
  - 变更类型: schema(报告模板)+ 流程
  - 影响范围: 报告模板"资源状况"段 / 第 3 步 record_outcome
  - 动机: 日报没有成本可见性;MCP 调用失败时 outcome 静默丢失,scan 下次重复推荐同一项目
  - 证据: [fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md](../../../docs/superpowers/fixes/2026-06-10-external-review-sentinel-wallclock-runs-fix.md)
