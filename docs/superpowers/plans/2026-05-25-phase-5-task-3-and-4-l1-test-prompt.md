# Prompt：为 ai-auto-harness Phase 5 跑 L1 测试（Task 3 + Task 4）

> 把下方 `---` 之间的整段内容**整体复制**给另一个 AI（Claude / Codex / claude-haha session 都行）。
> 该 AI 需要的能力：Read 工具读文件、Bash 工具跑 shell、Write 工具写文件。
> 期望完成时间：30-45 分钟。

---

# 任务：跑 ai-auto-harness Phase 5 的 L1 测试

你将完成 ai-auto-harness 项目 Phase 5（runbook + cleanup）实施 plan 中的 **Task 3** 和 **Task 4** 两个独立测试。两个 task 之间没有依赖（Task 4 不需要 Task 3 真产出 runbook 才能跑），你可以串行或并行执行。


---

## 人话版

**一句话**：Phase 5 的 L1 测试 prompt——复制给另一个 AI 跑，看 runbook 和 cleanup 两个 skill 合不合格。

**打比方**：像出厂质检单，复制给质检员按单子逐项检查，不通过就退回重做。

## 第 0 步：建立背景认知（必读）

按顺序读以下文件，理解项目和本轮要测的内容：

```bash
# 项目背景
cat /root/ai-auto-harness/.claude/CLAUDE.md         # 项目硬约束 + R1-R9 规则 + 落盘约定
cat /root/ai-auto-harness/CLAUDE.md                  # claude-haha 架构

# 本轮 Spec + Plan
cat /root/ai-auto-harness/docs/superpowers/specs/2026-05-25-runbook-and-cleanup-addendum.md
cat /root/ai-auto-harness/docs/superpowers/plans/2026-05-25-phase-5-runbook-and-cleanup.md

# 两个被测 skill
cat /root/ai-auto-harness/.claude/skills/write-deploy-runbook/SKILL.md
cat /root/ai-auto-harness/.claude/skills/write-deploy-runbook/_template.md
cat /root/ai-auto-harness/.claude/skills/cleanup-deployed-workspace/SKILL.md
```

读完应该理解：
- 这两个 skill 是 phase 5 新加的 SubAgent，跟在主 5 阶段流水线（intake / fetch-weights / install-env / run-and-repair / verify）末尾
- runbook-agent：从 trace 抽 AI 友好的部署 runbook 写到 `reports/runbooks/<slug>-<date>.md`
- cleanup-agent：白名单清理 workspace 的可重建产物（venv/.cache/repo），4 道防护 G1-G4 防误删

## 第 1 步：确认测试数据源就位

测试用 song-generation-run2 这个 workspace 的现成数据（5/22 跑通过的 SongGen），跑下面命令确认全在：

```bash
cd /root/ai-auto-harness

echo "=== workspace 数据 ==="
ls -la workspace/song-generation-run2/state.json \
       workspace/song-generation-run2/results/ \
       workspace/song-generation-run2/logs/ \
       workspace/song-generation-run2/output/

echo "=== trace 数据 ==="
ls -la runs/songgen-e2e-run3-resume-20260522-094040/harness.stdout.ndjson \
       runs/songgen-e2e-run3-resume-20260522-094040/meta.json
```

预期：所有文件都 ✅ 存在，state.json 显示 `phase=done, status=done`，results/ 含 `intake/fetch-weights/install-env/run-and-repair/verify.json` 共 5 份。

如有缺失文件，**立刻停止测试**，在 `pending_human/phase-5-l1-test.md` 写明缺什么，return failed_at=`step_1_data_missing`。

---

## Task 3：runbook-agent L1 测试

### 目标

让 runbook-agent SubAgent 真的跑一遍，基于 song-generation-run2 的 trace 产出 `reports/runbooks/song-generation-run2-2026-05-25.md`。验证：
1. SKILL.md 描述的 8 步工作流能完整跑通
2. `_template.md` 的 7 节结构能正确填空
3. "已知踩坑" 4 字段二元结构契约能被 LLM 遵守
4. 第 7 步敏感信息扫描真能拦住 HF_TOKEN / 绝对路径

### 怎么"启动 SubAgent"

如果你**自己就是** Claude Code / claude-haha 风格 agent，有 `Task` 工具：

```
Task(
  subagent_type="general-purpose",  # 或 runbook-agent，看你环境
  description="L1 test runbook-agent on song-generation-run2",
  prompt="""
你按 /root/ai-auto-harness/.claude/skills/write-deploy-runbook/SKILL.md 的工作流跑一次,输入参数:

- slug: song-generation-run2
- workspace_path: /root/ai-auto-harness/workspace/song-generation-run2
- run_id: songgen-e2e-run3-resume-20260522-094040
- verify_passed: true
- verify_result: (用 Read 工具读 /root/ai-auto-harness/workspace/song-generation-run2/results/verify.json)
- github_url: https://github.com/tencent-ailab/SongGeneration

严格执行 SKILL.md 的第 0-8 步。完成后 return result schema(JSON).
"""
)
```

如果你**不是** Claude Code / 没 Task 工具，**直接按 SKILL.md 第 0-8 步自己执行**(你就是 runbook-agent 本人)。

### 验收清单（按顺序检查）

完成后必须依次跑以下验收。每条都打勾或写"❌ + 原因"。

```bash
RUNBOOK=/root/ai-auto-harness/reports/runbooks/song-generation-run2-2026-05-25.md

# 文件存在 + 大小合理
[ -f "$RUNBOOK" ] && [ $(wc -c < "$RUNBOOK") -gt 2048 ] && echo "✅ V1 runbook 文件存在且 > 2KB" || echo "❌ V1"

# 7 节标题齐全（grep 标题关键字）
grep -q "frontmatter" "$RUNBOOK" || grep -qE "^---$" "$RUNBOOK" && echo "✅ V2 节1 frontmatter" || echo "❌ V2"
grep -qE "给 AI 的部署 prompt|AI prompt" "$RUNBOOK" && echo "✅ V3 节2 AI prompt" || echo "❌ V3"
grep -qE "前置要求|GPU.*显存" "$RUNBOOK" && echo "✅ V4 节3 前置要求" || echo "❌ V4"
grep -qE "Stage [1-5]" "$RUNBOOK" && echo "✅ V5 节4 5 stage" || echo "❌ V5"
grep -qE "已知踩坑|错误.*修复" "$RUNBOOK" && echo "✅ V6 节5 错误速查" || echo "❌ V6"
grep -qE "成本|cost|耗时" "$RUNBOOK" && echo "✅ V7 节6 成本摘要" || echo "❌ V7"
grep -qE "trace|runs/" "$RUNBOOK" && echo "✅ V8 节7 trace 指针" || echo "❌ V8"

# "已知踩坑" 4 字段二元结构(至少 1 个)
grep -B1 -A6 "已知踩坑" "$RUNBOOK" | grep -qE "触发条件|根因|修复|验证" && echo "✅ V9 踩坑 4 字段格式" || echo "❌ V9"

# 至少有 3 条踩坑(SongGen 实际 4-7 条:torch sm_120/torchcodec/pkg_resources/third_party)
TRAP_COUNT=$(grep -c "已知踩坑" "$RUNBOOK")
[ "$TRAP_COUNT" -ge 3 ] && echo "✅ V10 踩坑条数 $TRAP_COUNT >= 3" || echo "❌ V10 踩坑条数 $TRAP_COUNT < 3"

# 敏感信息扫描 — 任一返回非空 = ❌
grep -qE "hf_[a-zA-Z0-9]{30,}" "$RUNBOOK" && echo "❌ V11 HF_TOKEN 真值泄漏" || echo "✅ V11 无 HF_TOKEN 泄漏"
grep -qE "sk-ant-[a-zA-Z0-9_-]{20,}" "$RUNBOOK" && echo "❌ V12 Anthropic key 泄漏" || echo "✅ V12 无 API key 泄漏"
grep -qF "/root/ai-auto-harness/" "$RUNBOOK" && echo "❌ V13 绝对路径泄漏" || echo "✅ V13 无绝对路径泄漏"

# 落盘
[ -f /root/ai-auto-harness/workspace/song-generation-run2/results/runbook.json ] && echo "✅ V14 results/runbook.json 写了" || echo "❌ V14"
[ -f /root/ai-auto-harness/workspace/song-generation-run2/logs/runbook.log ] && echo "✅ V15 logs/runbook.log 写了" || echo "❌ V15"

# decisions.md append
grep -q "runbook-agent" /root/ai-auto-harness/runs/songgen-e2e-run3-resume-20260522-094040/decisions.md && echo "✅ V16 decisions.md 有 runbook-agent 行" || echo "⚠️ V16 (decisions.md 可能本来就不存在, 不致命)"
```

### 失败处理

如任一 V1-V15 失败：
- **不要**重试 N 次（R 规则禁止），最多重试 1 次
- 第二次仍失败 → 写 `/root/ai-auto-harness/pending_human/phase-5-task-3.md`，含失败的验收项 + 实际产出片段 + 你的诊断
- 在 final report 里标 Task 3 status=`failed`，列出失败的 V 编号

---

## Task 4：cleanup-agent dry_run L1 测试

### 目标

让 cleanup-agent SubAgent 在 `dry_run=true` 模式下跑一次，验证：
1. 4 道防护 G1-G4 都触发到（每道有 log 输出）
2. 白名单逻辑正确（应该 would rm: venv 8.1GB, hf_cache 14MB；不动 state/results/logs/output）
3. dry_run 模式真的不删任何东西（磁盘大小前后一致）
4. state.json 在 dry_run 下不被改

### 启动 SubAgent

类似 Task 3。如有 Task 工具：

```
Task(
  subagent_type="general-purpose",
  description="L1 test cleanup-agent on song-generation-run2 (dry_run)",
  prompt="""
你按 /root/ai-auto-harness/.claude/skills/cleanup-deployed-workspace/SKILL.md 的工作流跑一次,输入参数:

- slug: song-generation-run2
- workspace_path: /root/ai-auto-harness/workspace/song-generation-run2
- run_id: songgen-e2e-run3-resume-20260522-094040
- verify_passed: true
- runbook_path: reports/runbooks/song-generation-run2-2026-05-25.md  (Task 3 产物,如 Task 3 没跑就用任意已存在的 >1KB 文件路径绕过 G3)
- dry_run: true
- force_cleanup_incomplete: false

严格执行 SKILL.md 第 1-5 步,return result schema (JSON).
关键:DRY_RUN=true 时绝对不要真删任何东西。
"""
)
```

### 测试前快照（关键！）

跑 cleanup 之前先记下磁盘大小，用于跑完对比：

```bash
WS=/root/ai-auto-harness/workspace/song-generation-run2

echo "=== cleanup 前快照 ==="
du -sh "$WS" "$WS"/{venv,hf_cache,logs,output,results,state.json} 2>&1
md5sum "$WS/state.json"   # 记 state.json 的 md5
```

### 验收清单（按顺序检查）

```bash
WS=/root/ai-auto-harness/workspace/song-generation-run2
LOG="$WS/logs/cleanup.log"
RESULT="$WS/results/cleanup.json"

# 落盘
[ -f "$LOG" ] && echo "✅ V1 cleanup.log 写了" || echo "❌ V1"
[ -f "$RESULT" ] && echo "✅ V2 cleanup.json 写了" || echo "❌ V2"

# log 含 [DRY] 标记
grep -q "\[DRY\]" "$LOG" && echo "✅ V3 dry_run 模式日志正确(含 [DRY])" || echo "❌ V3"

# log 列出 would rm 的目标
grep -qE "would rm.*venv" "$LOG" && echo "✅ V4 venv 在清单" || echo "❌ V4"
grep -qE "would rm.*hf_cache|skipped.*hf_cache" "$LOG" && echo "✅ V5 hf_cache 在清单(或被识别为 not exist)" || echo "❌ V5"

# results/cleanup.json: dry_run=true
jq -r '.dry_run' "$RESULT" | grep -q "true" && echo "✅ V6 cleanup.json dry_run=true" || echo "❌ V6"

# results/cleanup.json: freed_bytes > 0 (估算值)
FREED=$(jq -r '.freed_bytes' "$RESULT")
[ "$FREED" -gt 1000000000 ] && echo "✅ V7 估算 freed_bytes=$FREED > 1GB" || echo "❌ V7 freed_bytes=$FREED 太小"

# state.json 不被改(md5 不变)
NEW_MD5=$(md5sum "$WS/state.json" | awk '{print $1}')
# 跟你之前快照对比(手动)
echo "ℹ️ V8 state.json md5=$NEW_MD5 (应跟测试前快照一致)"

# 磁盘大小不变(dry_run 不真删)
NEW_SIZE=$(du -sb "$WS" | awk '{print $1}')
echo "ℹ️ V9 workspace 新大小=$NEW_SIZE bytes (应跟测试前快照一致或差异 < 1MB)"

# 4 道防护是否都触发 log
grep -q "G1" "$LOG" && echo "✅ V10 G1 触发" || echo "⚠️ V10 (G1 可能没显式写,看实现)"
grep -q "G2" "$LOG" && echo "✅ V11 G2 触发" || echo "⚠️ V11"
grep -q "G3" "$LOG" && echo "✅ V12 G3 触发" || echo "⚠️ V12"
grep -q "G4" "$LOG" && echo "✅ V13 G4 触发" || echo "⚠️ V13"

# decisions.md append
grep -q "cleanup-agent" /root/ai-auto-harness/runs/songgen-e2e-run3-resume-20260522-094040/decisions.md 2>/dev/null && echo "✅ V14 decisions.md 有 cleanup-agent 行" || echo "⚠️ V14 (decisions.md 可能不存在)"
```

### 故意触发防护测试（强烈推荐补做）

为了确认 4 道防护真能拦截，做 4 个故意失败的 case：

```bash
# G1 防护测试: workspace_path 不在 /root/ai-auto-harness/workspace/
# 让 cleanup-agent 跑 workspace_path=/tmp/test, 期望它 raise + 不动磁盘

# G2 防护测试: run_id=不存在的 ID
# 期望 raise + 写 pending_human

# G3 防护测试: runbook_path 不存在
# 期望 raise

# G4 防护测试: verify_passed=false 且 force_cleanup_incomplete=false
# 期望 skipped=true, reason=G4_verify_not_passed
```

每个 case 跑完看 return JSON 的 `skipped: true, skipped_reason: "G<N>_..."` 是否符合。

### 失败处理

同 Task 3，最多重试 1 次，失败写 pending_human/phase-5-task-4.md。

---

## 最终 Report 格式（你必须用这个格式给用户回复）

跑完两个 task 后，用以下 markdown 格式 report：

```markdown
## Phase 5 L1 测试报告

### Task 3 — runbook-agent
- **状态**: ✅ pass / ❌ fail / ⚠️ partial
- **产出文件**: `reports/runbooks/song-generation-run2-2026-05-25.md` (大小: X KB)
- **7 节齐全**: V1 ✅ / V2 ✅ / V3 ✅ / V4 ✅ / V5 ✅ / V6 ✅ / V7 ✅ / V8 ✅
- **踩坑条数**: N（V10）
- **敏感扫描**: HF_TOKEN ✅ / API_KEY ✅ / 绝对路径 ✅（V11/V12/V13）
- **落盘**: results/runbook.json ✅ / logs/runbook.log ✅
- **失败的验收项**: <如有，列 V 编号 + 实际产出片段>
- **建议改 skill 的地方**: <如发现 SKILL.md 表述不清 / 模板坑 / 哪里 LLM 容易绕过>

### Task 4 — cleanup-agent dry_run
- **状态**: ✅ pass / ❌ fail / ⚠️ partial
- **落盘**: logs/cleanup.log ✅ / results/cleanup.json ✅
- **dry_run 标识**: V3 ✅ / V6 ✅
- **白名单清单**: would rm: venv (8.1GB), ...（V4/V5）
- **估算 freed_bytes**: X GB（V7）
- **state.json 不变**: ✅/❌（V8，含 md5 比对）
- **磁盘不变**: ✅/❌（V9，含前后大小）
- **4 道防护**: G1 ✅ / G2 ✅ / G3 ✅ / G4 ✅（V10-V13）
- **故意触发防护**: G1 ✅ / G2 ✅ / G3 ✅ / G4 ✅ (如做了)
- **失败的验收项**: <如有>
- **建议改 skill 的地方**: <如有>

### 给用户 review 的关键文件
1. **runbook**: `/root/ai-auto-harness/reports/runbooks/song-generation-run2-2026-05-25.md`
2. **cleanup log**: `/root/ai-auto-harness/workspace/song-generation-run2/logs/cleanup.log`
3. **cleanup result**: `/root/ai-auto-harness/workspace/song-generation-run2/results/cleanup.json`
4. **(如有 pending_human)**: `/root/ai-auto-harness/pending_human/phase-5-task-*.md`

### 总体结论
- Task 3 是否可进入 plan Task 5（改 auto-deploy 主 skill 串联）: **YES / NO**
- Task 4 是否可进入 plan Task 5：**YES / NO**
- 若 NO，阻塞点是什么 + 需用户决策的问题
```

---

## 注意事项

1. **不要修 SKILL.md 或 _template.md** — 即使发现问题也只在 report 里"建议改的地方"提，让用户决定。
2. **不要真清磁盘** — Task 4 严格 dry_run=true，task 3 不会动磁盘。
3. **不要污染其他 workspace** — 只动 `/root/ai-auto-harness/workspace/song-generation-run2/` 和 `/root/ai-auto-harness/reports/runbooks/`。
4. **R 规则适用** — 你也算 SubAgent，遵守 R1（workspace 隔离）/ R4（禁连续 sleep）/ R8（PHASE 标记）等。
5. **commit** — 测试完后**不要自动 commit**，让用户 review 完手动 commit。
6. **最多重试 1 次** — 失败就写 pending_human，不要硬试。

---

完成后给用户最终 report（用上面的 markdown 格式），等用户决定 next step。
