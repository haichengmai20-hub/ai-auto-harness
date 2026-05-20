---
name: verifier-corrector
description: 写完报告后做事实核验 + 把 ❌ 声明回写正文(借鉴 ai-daily-scan 的 Verifier+Corrector 模式)
allowed-tools: [Read, Edit, Bash]
---

# verifier-corrector

## 触发

`write-recommendation` skill 完成报告写入**之后**,可选触发本 skill 做一次 sanity check。

为什么有这个 skill?— 借鉴 `/root/ai-daily-scan` 的设计:LLM 写报告时容易"自由发挥"出错误数字、错误 URL,事后独立核验 + 回写比写时就准确更可靠.

## 你的输入

```json
{
  "report_path": "reports/2026-05-19.md",
  "run_results": [...]  // 同 write-recommendation 输入
}
```

## 工作流

### 第 1 步:抽报告里的关键声明

读 `report_path`,人工 grep 出:

1. **数字声明**:
   - 成本估算(¥ / $ 数字)
   - 显存占用(GB / GiB 数字)
   - 推理速度(tok/s / sec / RTF)
   - 参数量(B 数字)
   - 文件大小
2. **URL**:GitHub / HuggingFace / 第三方链接
3. **API 定价**(若 api-skeleton 段提到)

每条声明记录:
- 声明文本(原文摘录)
- 来源(run_result 哪个字段 / scan_finding / 自己生成)
- 报告中的行号

### 第 2 步:独立核验

对每条:

**URL** → `curl -sI` 看 HTTP 状态:

```bash
curl -sI "<url>" 2>&1 | head -3
# 200 / 301 → ✅ 存在
# 404 / 5xx → ❌
```

**数字声明** → 与 source 对照:

- 若来自 `scan_finding.cost_estimate`(scan analyst 算的)→ 直接信任(scan 内部已经做过 Verifier)
- 若来自 `run_result.gpu_snapshot`(我们自己测的)→ 直接信任(实测数字)
- 若是 LLM "自由发挥"出来的(不在任何结构化 source 里)→ ⚠️ 标记可疑

**API 定价**:
- 若有 source_urls 指向官方定价页 → curl 看一眼能否 fetch(verify 链接存在,不爬内容)
- 若是 LLM 凭空写的具体价格 → 标记可疑

### 第 3 步:回写

任何 ❌ 或可疑声明:

```python
Edit report_path:
    old_string = "<原声明>"
    new_string = "<原声明> ⚠️[待核实]"
```

报告末尾追加一个核验表:

```markdown
## 报告自检 — verifier-corrector 输出

| 状态 | 声明位置 | 声明 | 核验结果 | 行动 |
|---|---|---|---|---|
| ✅ | L42 | "github.com/x/y" | curl 200 | 无 |
| ❌→修正 | L58 | "推理速度 50 tok/s" | run.json 实测 27 tok/s | 已 Edit 为 "推理速度 27 tok/s(本次实测)" |
| ⚠️ | L73 | "市场份额 30%" | LLM 自由发挥,无 source | 标记 [待核实] |

**自检结论**:`<N>` 条声明,`<P>` ✅,`<F>` 修正,`<S>` 标可疑.报告整体可信度 `<高/中/低>`.
```

### 第 4 步:决定要不要让人手 review

如果"标可疑" + "修正" 数 > 3 条 → 在报告**顶部**加一段提示:

```markdown
> ⚠️ **本报告含 `<N>` 处可疑声明,verifier-corrector 已标记 [待核实]。建议人工审阅末尾"报告自检"段后再分发。**
```

## 返回 schema

```json
{
  "claims_checked": 12,
  "verified": 8,
  "corrected": 2,
  "suspicious": 2,
  "high_alert": false,
  "edited_report_path": "reports/2026-05-19.md"
}
```

## 反模式

- ❌ 不要核验"主观判断"(如"建议优先试点"这种 — 不是 fact claim)
- ❌ 不要把可疑声明直接删除(留着 + 加标记,人决定)
- ❌ 不要因为 1-2 处可疑就废掉整个报告
- ❌ 不要核验"内部" trace 文件(runs/<id>/*.json 是审计材料,不是给人看的报告)
