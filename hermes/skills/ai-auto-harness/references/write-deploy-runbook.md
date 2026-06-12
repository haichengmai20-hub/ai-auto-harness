# write-deploy-runbook playbook(Hermes 子代理)

从本次部署 trace 抽 AI 友好的部署手册,让人或 AI 30-60min 复现。verify 失败也要写(踩坑章节对下次有价值)。

## 落盘

runbook `reports/runbooks/<slug>-<YYYY-MM-DD>.md`;日志 `logs/runbook.log`;结果 `results/runbook.json`。

## 方法 = 模板 + 填空(不许自由发挥)

第 0 步:`cat /root/ai-auto-harness/.claude/skills/write-deploy-runbook/_template.md` 套骨架(模板与 CC 版共用)。

**7 节结构严格固定**(validate-runbook.sh 靠 `^## N\.` 抓节):1=给 AI 的部署 prompt / 2=前置要求 / 3=5 Stage 完整指令 / 4=已知踩坑速查 / 5=成本耗时 / 6=trace 指针 / 7=失败 case 标记。

数据源:state.json + results/*.json + logs/fixes.log + $RUN_DIR/decisions.md。fixes.log 缺失 → 从 results/run.json 的 fixes_applied + install.json 降级抽取。

## 关键填写规则

- **frontmatter status 推导**:verify true→`success`;5 stage 走完但 verify false→`incomplete_verify_failed`;卡在中途→`paused_at_<phase>`(主 agent 传 force_status);资源拒→`blocked_<reason>`
- **total_cost_usd**:Hermes 下成本数据从 Hermes 内置追踪取;取不到**写 `null` 不写 0.0**(0.0 暗示免费)
- **duration_min**:唯一来源 = state.json 的 started_at→updated_at 实际差值;**严禁**用 AI prompt 节里的"预计耗时"
- **Stage 标题逐字**:`Stage 1: clone` / `Stage 2: 拉权重` / `Stage 3: 装环境` / `Stage 4: 推理` / `Stage 5: 验证`(出现过"腅环境"错字直接判失败)
- **踩坑 4 字段块**(触发条件/根因/修复/验证修复成功),不许散文;有修复命令的必写;skip 的冲突写但标"⚠️ 未修复";纯 INFO 不写
- **命令抽取**:从 logs 抽**成功的**那条;每 stage 必有命令+成功标志+预计耗时,没跑到的 stage 标 ⚠️ 而不是编命令

## 第 7 步:敏感信息 + R 规则扫描(硬性最后一步)

```bash
grep -E "hf_[a-zA-Z0-9]{30,}|sk-ant-[a-zA-Z0-9_-]{20,}" "$RUNBOOK_PATH"   # 泄密
grep -F "/root/ai-auto-harness/" "$RUNBOOK_PATH"                           # 绝对路径
grep -E "huggingface-cli\s+(download|upload|login)" "$RUNBOOK_PATH"        # R7
grep -E "pip\s+install\s+.*--no-cache-dir" "$RUNBOOK_PATH"                 # R6
```
任一命中 → 替换(`${HF_TOKEN}` / `${HARNESS_ROOT}/` / `hf download` / 删 flag)后重扫到全过。**事实优先级:R 规则 > trace 实录**(runbook 是给后人执行的,留 deprecated 命令=继承错误)。

## 落盘 + 返回

`results/runbook.json`(heredoc 求值):

```json
{"slug":"...","runbook_path":"reports/runbooks/<slug>-<date>.md","runbook_bytes":0,
 "status":"success","ai_prompt_word_count":0,"stage_count":5,"traps_documented":0,"completed_at":"..."}
```

decisions.md append 一行;PHASE_END。**summary 原样含 runbook.json 全文**(主 agent 要把 runbook_path 透传给报告和 cleanup)。

## 反模式

- ❌ 只写 reports/runbooks/ + logs + results 三处,**其他文件只读不写**(state.json 是主 agent 的)
- ❌ 纯 LLM 自由写整份;❌ 节编号自创;❌ "凑"没跑到的 stage
