---
name: request-human-intervention
description: 任何 SubAgent 主动 raise 时调 — 写 pending_human/<slug>.md
allowed-tools: [Read, Write, Bash]
---

# request-human-intervention

## 你的输入

```json
{
  "slug": "<project-slug>",
  "reason_category": "auth_missing | stuck_repair_3x | resource_shortage | model_too_large | credential_needed | unknown_failure",
  "what_tried": ["..."],
  "what_blocked": "...",
  "next_steps_suggested": ["..."]
}
```

## 工作流

### 1. Write `pending_human/<slug>.md`

```markdown
# <slug> — 需要人手介入

**时间**:<ts>
**原因类别**:<reason_category>
**当前阶段**:<state.phase>

## 我尝试过什么
- <bullet>
- <bullet>

## 我被卡在哪
<具体描述>

## 建议人手做的事
- <bullet>
- <bullet>

## 上下文
- workspace: `workspace/<slug>/`
- trace: `runs/<run-id>/`
- state: <state.json 摘要>

---
处理完后**手动删除本文件** → 下次 cron 才会重新尝试
```

### 2. 更新 state.json

```bash
jq --arg ph paused_for_human \
   --arg reason "$REASON" \
   --arg written "pending_human/$SLUG.md" \
   --arg ts "$(date -Iseconds)" \
   '.phase = $ph | .pending_human = {reason: $reason, written_to: $written, ts: $ts}' \
   "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

## 返回

```json
{
  "wrote_to": "pending_human/<slug>.md",
  "blocked": true
}
```
