# Phase 5 L1 测试回顾 — 2026-05-25

**测试执行**: 通过 `launch_worker.sh` 驱动 claude-haha worker 执行
**Run 目录**: `runs/phase5-l1-test-20260525-154424/`
**Worker 耗时**: ~5 min | 花费: $4.27 | 42 turns
**测试结论**: Task 3 ✅ pass / Task 4 ✅ pass

---

## 一、Task 3 (runbook-agent) 有待改善的点

### P3-1 [中] fixes.log 降级抽取未在 SKILL.md 明确

**现象**: SongGen 的 workspace 没有 `logs/fixes.log`（原始 worker 没写），runbook-agent 需从 `results/run-and-repair.json` 的 `repairs` 数组降级抽取踩坑。

**改善**: SKILL.md 第 1 步"聚合数据源"应加降级逻辑：
```
FIXES_LOG="$WORKSPACE/logs/fixes.log"
if [ ! -f "$FIXES_LOG" ]; then
    echo "WARN: fixes.log 缺失,从 results/run-and-repair.json 的 repairs 字段降级抽取" >> "$LOG"
fi
```
同时说明降级时 4 字段格式需 LLM 从 repairs JSON 推导，非直接 grep。

**优先级**: 中 — 目前 LLM 自行降级成功，但明确写可减少下次不同 LLM 的不确定性。

---

### P3-2 [中] _template.md 节编号与 SKILL.md 步骤编号不一致

**现象**:
- _template.md 节编号: 1(AI prompt) → 2(前置要求) → 3(5 stage) → 4(踩坑) → 5(成本) → 6(trace) → 7(失败 case)
- SKILL.md 步骤引用: 第 5 步"生成 AI prompt(节 2)", 第 3 步"生成 5 stage 指令(节 4?)"

**改善**: 统一编号。建议 _template.md 节编号从 0 开始对应 SKILL.md 步骤编号，或在 SKILL.md 里用"节名"而非"节号"引用。

**优先级**: 中 — 不影响本次 LLM 执行，但会让后续维护者困惑。

---

### P3-3 [低] 踩坑条数筛选规则不明确

**现象**: `results/run-and-repair.json` 记了 3 条 repair（third_party/pkg_resources/torchcodec），加 torch sm_120 = 4 条。但 `install-env.json` 还提到 `omegaconf/hydra` 冲突（被 skip 未修），是否算踩坑不明确。

**改善**: SKILL.md 第 4 步应明确：
- 只抽**导致 repair 的踩坑**（有实际修复命令的）
- 不抽**被 skip 的冲突**（没修就没法给"修复"字段）
- 或给被 skip 的标 `⚠️ 未修复,需人工判断`

**优先级**: 低 — 目前 4 条踩坑覆盖了所有实际修复，信息足够。

---

### P3-4 [低] "腅环境" 错字

**现象**: 产出的 runbook Stage 3 标题出现"腅环境"（非标准汉字），应为"装环境"或"安装环境"。

**改善**: _template.md 在 Stage 3 标题处用固定文字而非让 LLM 生成，或在 SKILL.md 加"标题用标准中文: Stage 1=clone / Stage 2=拉权重 / Stage 3=装环境 / Stage 4=推理 / Stage 5=验证"。

**优先级**: 低 — 不影响 AI 消费，但影响人读体验。

---

### P3-5 [高] huggingface-cli 违反 R7 规则

**现象**: 产出的 runbook Stage 2 命令用了 `huggingface-cli download`，但 R7 规则明确要求用 `hf download`。

**改善**:
1. _template.md Stage 2 示例命令改为 `hf download`
2. SKILL.md 第 3 步加"抽取 fetch-weights 命令时，把 `huggingface-cli` 替换为 `hf`（R7 规则）"
3. 第 7 步敏感信息扫描加一条: `grep -E "huggingface-cli" "$RUNBOOK_PATH"`，命中则替换

**优先级**: 高 — 违反已建立的硬规则，下个 AI 按此 runbook 执行会继承错误命令。

---

### P3-6 [低] 验收脚本踩坑计数 grep 不精确

**现象**: L1 test prompt 里 `grep -c "已知踩坑"` 匹配了 7 次（AI prompt 节和踩坑速查节都有"已知踩坑"文字），但实际条目只有 4 条。V10 通过是因为 7 > 3，但语义上不精确。

**改善**: 验收脚本改为 `grep -cE "^### 已知踩坑 [0-9]"` 只匹配标题行。

**优先级**: 低 — 不影响本次判断（7 > 3 仍通过），但会让后续测试更精确。

---

## 二、Task 4 (cleanup-agent) 有待改善的点

### P4-1 [高] cleanup.log 缺 PHASE_END 标记

**现象**: cleanup.log 有 `PHASE_START` 但没有 `PHASE_END`，违反 R8 规则。

```
=== PHASE_START phase=cleanup slug=... ts=2026-05-25T15:52:41+08:00 ===
... (各种操作)
==== cleanup end at 2026-05-25T15:54:31+08:00 ====
# ❌ 缺: === PHASE_END   phase=cleanup slug=... status=done ts=... ===
```

**改善**: SKILL.md 第 5 步"写 results/cleanup.json + 返回"里补：
```bash
echo "=== PHASE_END   phase=cleanup slug=$SLUG status=done ts=$(date -Iseconds) ===" >> "$LOG"
```

**优先级**: 高 — R8 是硬规则，monitor 靠 PHASE_END 抓完成事件，缺了会导致监控误判"cleanup 未完成"。

---

### P4-2 [中] cleanup.json dry_run 模式下 `removed` 字段语义不准

**现象**: `cleanup.json` 的字段叫 `removed: []`，但 dry_run 模式下实际什么都没删，叫 "removed" 有误导性。

**改善**: dry_run 模式下用 `would_remove` 代替 `removed`：
```json
// dry_run=true
{
  "would_remove": ["venv", "hf_cache"],
  "kept": ["state.json", "results", "logs", "output"],
  ...
}
// dry_run=false
{
  "removed": ["venv", "hf_cache"],
  "kept": ["state.json", "results", "logs", "output"],
  ...
}
```

**优先级**: 中 — 不影响功能，但影响人读理解和下游消费者（如 auto-status）的判断。

---

### P4-3 [中] G3 防护 runbook_path 相对/绝对路径不明确

**现象**: 传入的 `runbook_path` 是 `reports/runbooks/song-generation-run2-2026-05-25.md`（相对路径），cleanup-agent 在 G3 检查时需要判断文件存在且 >1KB，但相对路径是相对于 CWD 而非 `$HARNESS_ROOT`。

**改善**: SKILL.md 应明确：
- `runbook_path` 必须是**绝对路径**（如 `/root/ai-auto-harness/reports/runbooks/...`）
- 或明确是**相对于 `$HARNESS_ROOT`** 的路径，检查时拼接 `$HARNESS_ROOT/$runbook_path`

**优先级**: 中 — 本次 CWD 恰好是 $HARNESS_ROOT 所以通过了，但换个 CWD 就会 G3 误判。

---

### P4-4 [低] freed_bytes 与 du -sh 输出差异

**现象**: cleanup.log 写 `would rm venv (8.1G)`，但 `freed_bytes=8,573,045,260` ≈ 7.98 GB。差异来自 `du -sh` 用 1G=1024³ 而 freed_bytes 用 1GB=1000³。

**改善**: SKILL.md 或 cleanup.json 加一个 `freed_gib` 字段用 GiB 单位，与 `du -sh` 对齐：
```json
{
  "freed_bytes": 8573045260,
  "freed_gib": 7.98,
  "freed_human": "8.0 GiB (dry_run, not actually freed)"
}
```

**优先级**: 低 — 不影响功能，只是显示一致性。

---

### P4-5 [高] 故意触发防护测试未执行

**现象**: L1 test plan 要求"强烈推荐补做"4 个故意失败的 case（G1 路径不在 workspace 下 / G2 run_id 不存在 / G3 runbook 不存在 / G4 verify_passed=false），但 worker 未执行。

**改善**:
1. 在 L1 test prompt 里把"强烈推荐补做"改为"**必做**"
2. 每个防护测试可以独立启动一个轻量 worker（`dry_run=true` + 构造错误输入），看 return 的 `skipped: true, skipped_reason: "G<N>_..."` 是否符合预期
3. 预估额外耗时 10-15 min

**优先级**: 高 — 没有故意失败测试就不能确认防护真能拦。G3 路径问题（P4-3）就是这类测试能发现的。

---

### P4-6 [中] repo 和 .cache 不存在但未报 WARN

**现象**: workspace 里 `repo/` 和 `.cache/` 目录不存在（原始部署没放在 workspace 或已被删），cleanup-agent 的 cleanup.log 只写了 `skipped .cache (not exist)` 但没提 repo。

**改善**: cleanup-agent 白名单遍历应每个目标都检查存在性，不存在的都明确 log：
```
[DRY] would rm -rf .../repo (NOT EXIST, skip)
[DRY] would rm -rf .../.cache (NOT EXIST, skip)
[DRY] would rm -rf .../venv (8.1G)
[DRY] would rm -rf .../hf_cache (14M)
```

**优先级**: 中 — 影响审计完整性，让人误以为 repo 被 cleanup 删了。

---

## 三、跨 Task 的系统性改善

### S-1 [高] SKILL.md 对 LLM 的约束不够硬

**现象**: 多个改善点（P3-5 R7 违规 / P3-4 错字 / P4-1 缺 PHASE_END）本质上都是 SKILL.md 的约束被 LLM "自由发挥"绕过。

**改善**: 学习 launch_worker.sh 的 `--append-system-prompt` 模式：
- 在 runbook-agent 和 cleanup-agent 的 SKILL.md 里加"反模式"清单更醒目（❌ + 后果）
- 或在 dispatch SubAgent 时也传 `--append-system-prompt`（目前 SubAgent 没这个机制）
- 或在 _template.md 里把容易出错的字段（如 Stage 2 命令）用固定文字而非占位符

**优先级**: 高 — 这是主 agent dispatch 架构的系统性问题，每个 SubAgent 都会遇到。

---

### S-2 [中] 验收脚本应自动化

**现象**: 本次验收靠我手动逐条跑 bash + python3，容易遗漏。

**改善**: 把 V1-V16 的验收逻辑写成一个 `scripts/validate-runbook.sh` 和 `scripts/validate-cleanup.sh`，L1 test prompt 改为调用脚本。

**优先级**: 中 — 下次 e2e 测试（Task 8）会需要重复验收。

---

### S-3 [低] runbook.json.traps_documented 与 runbook 内实际条目数应交叉校验

**现象**: `runbook.json` 写 `traps_documented: 4`，但验证时 `grep -c "已知踩坑"` = 7（含 AI prompt 节重复引用）。

**改善**: `validate-runbook.sh` 里加：
```bash
TRAP_IN_JSON=$(python3 -c "import json; print(json.load(open('results/runbook.json'))['traps_documented'])")
TRAP_IN_MD=$(grep -cE "^### 已知踩坑 [0-9]" reports/runbooks/xxx.md)
[ "$TRAP_IN_JSON" -eq "$TRAP_IN_MD" ] || echo "❌ traps_documented=$TRAP_IN_JSON but actual=$TRAP_IN_MD"
```

**优先级**: 低 — 数据一致性校验，防止 LLM 乱填。

---

## 四、优先级汇总

| 优先级 | ID | 简述 | 改 SKILL.md? | 改 _template.md? | 改 L1 test? |
|---|---|---|---|---|---|
| **高** | P3-5 | huggingface-cli → hf (R7) | ✅ | ✅ | |
| **高** | P4-1 | cleanup.log 缺 PHASE_END | ✅ | | |
| **高** | P4-5 | 故意触发防护未做 | | | ✅ |
| **高** | S-1 | SKILL.md 对 LLM 约束不够硬 | ✅ | ✅ | |
| **中** | P3-1 | fixes.log 降级抽取未明确 | ✅ | | |
| **中** | P3-2 | 节编号不一致 | ✅ | ✅ | |
| **中** | P4-2 | dry_run 下 removed 语义不准 | ✅ | | |
| **中** | P4-3 | G3 runbook_path 相对/绝对不明确 | ✅ | | |
| **中** | P4-6 | repo/.cache 不存在未报 WARN | ✅ | | |
| **中** | S-2 | 验收脚本应自动化 | | | ✅ |
| **低** | P3-3 | 踩坑筛选规则不明确 | ✅ | | |
| **低** | P3-4 | "腅环境" 错字 | | ✅ | |
| **低** | P3-6 | 验收 grep 不精确 | | | ✅ |
| **低** | P4-4 | freed_bytes vs du 单位差异 | ✅ | | |
| **低** | S-3 | traps_documented 交叉校验 | | | ✅ |

**建议执行顺序**:
1. 先修 4 个 **高** 优先级（P3-5 + P4-1 + P4-5 + S-1），改完重跑 L1 test 验证
2. 再修 6 个 **中** 优先级
3. **低** 优先级可在 Task 8 e2e 测试前统一修

---

## 五、本次测试产出清单

| 文件 | 路径 | 大小 |
|---|---|---|
| runbook markdown | `reports/runbooks/song-generation-run2-2026-05-25.md` | 8,114 bytes (257 行) |
| runbook JSON | `workspace/song-generation-run2/results/runbook.json` | 281 bytes |
| runbook log | `workspace/song-generation-run2/logs/runbook.log` | 103 bytes |
| cleanup JSON | `workspace/song-generation-run2/results/cleanup.json` | 414 bytes |
| cleanup log | `workspace/song-generation-run2/logs/cleanup.log` | 713 bytes |
| decisions append | `runs/songgen-e2e-run3-resume-20260522-094040/decisions.md` | +2 行 |
| L1 test ndjson | `runs/phase5-l1-test-20260525-154424/harness.stdout.ndjson` | 100 lines |
