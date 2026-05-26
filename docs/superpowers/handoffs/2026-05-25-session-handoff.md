# ai-auto-harness 长 session handoff — 2026-05-25

> 上一 session 接近 token 上限,本文档让新 session 用 < 5K context 拾起长期任务。
>
> **新对话第一句直接 paste 第 §8 那段** 就能恢复工作。

---

## §1. 项目 30 秒画像

**ai-auto-harness** = 基于 Claude Code 源码 fork 的 cron-driven 平台,每天:

1. 从 ai-daily-scan(上游 Python 平台,MCP 接通)取当日 AI 项目候选
2. 主 agent 用 `Task()` dispatch 5 个 SubAgent 串行部署:`intake → fetch-weights → install-env → run-and-repair → verify`
3. 写日报 `reports/<date>.md` + MCP 回填 outcome

工作目录:`/root/ai-auto-harness/`(基于 `claudecode_sourcecode1` fork)。

---

## §2. 当前状态(版本与完成度)

### v1.0(2026-05-19 立项 → 2026-05-22 实现完成)

- 12 个 skill 实现完成(auto-daily / auto-deploy / intake / fetch-weights / install-env / run-and-repair / verify / ...)
- 7 个 phase plan 全部 ✅:`docs/superpowers/plans/2026-05-19-phase--1 ~ phase-4.md`
- **SongGen e2e 试跑过 2 次**(run2 + run3),暴露 LLM 自觉度极低问题(R 规则只在 skill prompt 里被忽视)

### v1.0 → v1.1 之间的硬约束加固(本周加,已上线)

- `.claude/CLAUDE.md` 加 **R1-R9 硬规则**(workspace 隔离 / 不 kill 别人 PID / 禁 sleep loop / 串行带宽 / 禁 --no-cache-dir / 用 `hf` 不 `huggingface-cli` / PHASE_START/END / 主 agent 只 Task() 不亲自 bash)
- `.claude/hooks/post-tool-use.sh` 改成 **python3 实现的 PostToolUse 硬约束 hook**,实时检测 R1/R4/R6/R9 违规 → `hookSpecificOutput.additionalContext` 注入 LLM 下一 turn
- `cron/launch_worker.sh` + `cron/daily.sh` 加 trap cleanup + worker.pid + 启动前扫僵尸 + `--append-system-prompt` 反复强调 R 规则
- `memory/lessons/torch-sm12.md` 追加 "requirements.txt pin 冲突剥离" + "numpy 降级" 经验

### v1.1(2026-05-25,phase 5 — runbook + cleanup)

- **设计已完成**(本 session 的 brainstorming 走完 5 个 section,用户都 OK)
- **代码已在另一个 claude session 实现完成**:
  - `.claude/skills/write-deploy-runbook/SKILL.md` + `_template.md` 已存在
  - `.claude/skills/cleanup-deployed-workspace/SKILL.md` 已存在
- **L1 测试已跑**:`runs/phase5-l1-test-20260525-154424/` Task 3 ✅ + Task 4 ✅,花费 $4.27 / 42 turns
- **retro 报告已写**:`docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md` 列了 15 条改善点(4 高 / 6 中 / 5 低)

---

## §3. 🔴 硬约束(新 session 必须遵守)

### R-HO-1 不许动用户训练
- 用户 GPU 在跑训练,nvidia-smi 看到 4 卡 29GB 占用 = 用户的,**不是我们 run 的残留**
- 任何"清 GPU"操作禁

### R-HO-2 不许动 runs/ 下的实际权重文件
- 用户报 `runs/songgen-e2e-run2-20260521-132245/.cache/` 13G + `runs/songgen-e2e-20260521-124245/.cache/` 9G 残留权重
- 用户**自己会处理**,新 session 只能在 **设计/spec/skill 层面**讨论"为什么 cleanup 没覆盖 runs/.cache,要不要改"
- **不许 `rm -rf` 这些目录**

### R-HO-3 只动 phase 5 相关代码文件
- 允许:`.claude/skills/{write-deploy-runbook,cleanup-deployed-workspace}/*`、相关 spec / plan / retro / handoff
- 不许:用户的训练数据、其他 workspace、其他 skill 文件(除非 retro 明确要求)

### R-HO-4 不重做已完成的事
- Phase 5 代码已经被另一个 claude session 写完。**不重写 SKILL.md / _template.md 整文件**,只按 retro 列的点做 patch 式修改
- L1 测试已跑过,**不重跑** L1(除非 fix 完想 re-validate)

### R-HO-5 brainstorming + writing-plans 走过了
- 设计已 OK,**不再开 brainstorming**
- 直接进 retro 验证 + 修复 + (可选)重跑 L1

---

## §4. 上次 session 走到哪里(中断点)

| 阶段 | 状态 |
|---|---|
| Brainstorming(spec 5 section) | ✅ 全部完成,5 section 都 OK |
| 写 spec addendum | ❌ 未写(用户说"代码已在另一 session 实现",跳过) |
| 写 phase 5 plan | ❌ 未写(同上) |
| 读 retro 报告 | ✅ 完成 |
| **核实 retro 15 条改善点** | ⏸️ **进行到一半** — 已确认 skill 文件存在 + L1 产物存在 + runs/.cache 残留属实 |
| 应用修复 | ❌ 未开始 |
| 报告改了什么 | ❌ 未开始 |

**接续起点**:retro 15 条改善点的核实 + 修复。

---

## §5. retro 15 条改善点速查(已读,有判断)

| ID | 优先级 | 是否属实(我的初判) | 难度 |
|---|---|---|---|
| **P3-5** huggingface-cli → hf (R7 违反) | 高 | ✅ 属实(产出 runbook 确实有 `huggingface-cli`,违反新加的 R7) | 易,改 `_template.md` Stage 2 + SKILL.md 加替换步骤 |
| **P4-1** cleanup.log 缺 PHASE_END | 高 | ✅ 属实(确认 `workspace/song-generation-run2/logs/cleanup.log` 只 713 字节,可 grep PHASE_END 验) | 易,加一行 echo |
| **P4-5** 故意触发防护测试未做 | 高 | ⚠️ 属实但**不是 code bug** — 是测试覆盖度问题。需要补 4 个故意失败 case 重跑 L1 | 中,需要新 L1 prompt + ~10-15min worker 跑 |
| **S-1** SKILL.md 约束太软 | 高 | ⚠️ 半属实 — 但 SubAgent 不能传 `--append-system-prompt`(CC 限制)。建议改 `_template.md` 把易错字段写死 | 中 |
| **P3-1** fixes.log 降级抽取未明确 | 中 | ✅ 属实(SongGen workspace 真没 `fixes.log`) | 易,SKILL.md 加 fallback 说明 |
| **P3-2** _template.md / SKILL.md 节编号不一致 | 中 | ✅ 待 grep 验证,设计上应统一 | 易,改命名引用 |
| **P4-2** dry_run 下 `removed` 语义不准 | 中 | ✅ 属实,改成 `would_remove` 更准 | 易 |
| **P4-3** G3 runbook_path 相对 / 绝对不明确 | 中 | ✅ 属实,需明确规定 | 易 |
| **P4-6** repo / .cache 不存在未报 WARN | 中 | ✅ 属实(cleanup.log 只提 .cache,没提 repo) | 易 |
| **S-2** 验收脚本自动化 | 中 | ✅ 合理建议,新建 `scripts/validate-{runbook,cleanup}.sh` | 中 |
| **P3-3** 踩坑筛选规则不明确 | 低 | ✅ 属实 | 易 |
| **P3-4** "腅环境" 错字 | 低 | ✅ 属实(LLM 生成错字),fix:`_template.md` 把 stage 标题写死 | 易 |
| **P3-6** 验收 grep 不精确 | 低 | ✅ 属实(`grep -c "已知踩坑"` 匹配 AI prompt 节复述,虚高) | 易 |
| **P4-4** freed_bytes vs du 单位 | 低 | ✅ 属实(1G=1024³ vs 1GB=1000³) | 易,加 `freed_gib` 字段 |
| **S-3** traps_documented 交叉校验 | 低 | ✅ 属实 | 易,validate 脚本加一行 |

**用户隐含问的第 16 条:cleanup 没覆盖 `runs/<run-id>/.cache/`(13G+9G 残留)**

- 这**不是 retro 显式列出的**,是用户实测后报的
- 真实性:✅ 已实测确认 22G 残留
- 根因:cleanup-deployed-workspace skill 只清 `workspace/<slug>/` 下的 venv/.cache/repo,**没动 runs/<run-id>/.cache/`** 这块 launch_worker.sh 创建的 isolated cache
- 设计层取舍(需要新 session 与用户讨论):
  - 选 A:cleanup 同时清自己 run 的 `runs/<run-id>/.cache/`(简单,推荐)
  - 选 B:cleanup 同时清**所有已 done/archived run 的** `runs/*/.cache/`(更激进,可能误删)
  - 选 C:加一个独立 skill `cleanup-runs-cache`,人手或 cron 触发
  - 选 D:文档化"runs/<run-id>/.cache 不归 cleanup 管,用 `find runs/ -mtime +7 -name .cache -exec rm -rf {} \;` 周清"

---

## §6. 关键文件指针(新 session 直接 Read 这些恢复 context)

**必读(优先级)**:

1. `.claude/CLAUDE.md` — R1-R9 硬规则(180 行)
2. `docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md` — 15 条改善点完整内容
3. `.claude/skills/write-deploy-runbook/SKILL.md` + `_template.md` — 待修对象 1
4. `.claude/skills/cleanup-deployed-workspace/SKILL.md` — 待修对象 2

**参考(按需读)**:

5. `README.md` — 项目自描述 + R 规则强制机制
6. `docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md` — v1.0 完整设计 (59KB,大致扫即可)
7. `.claude/hooks/post-tool-use.sh` — 硬约束 hook 实现
8. `cron/launch_worker.sh` + `cron/daily.sh` — 启动脚本(理解 isolated cache 在 `$LOG_DIR/.cache`)
9. `memory/lessons/torch-sm12.md` — 已沉淀的踩坑经验
10. L1 测试产物:
    - `reports/runbooks/song-generation-run2-2026-05-25.md` (8KB)
    - `workspace/song-generation-run2/results/{runbook,cleanup}.json`
    - `workspace/song-generation-run2/logs/{runbook,cleanup}.log`
    - `runs/phase5-l1-test-20260525-154424/harness.stdout.ndjson`

**不要 reload 的(浪费 context)**:

- 任何 `node_modules/` / `bin/` / `src/` 下的 CC 源码 — 不改它
- 用户的训练数据(`/root/hanjiaqi/` 之类)— 完全无关

---

## §7. 推荐工作流(新 session 直接照做)

```
Step 1: 读 §6 必读 4 个文件(~30K context)
Step 2: 按 §5 优先级表,从 4 个"高"开始 patch 式修复
        - P3-5 + P4-1 改 SKILL.md + _template.md(易)
        - P4-5 需要决定:补 L1 测试 4 个故意失败 case → 写 prompt → 用户自己跑(我不许跑长 worker)
        - S-1 改 _template.md 把易错字段写死(易)
Step 3: 6 个"中"批量改,1-2 turn 解决
Step 4: 5 个"低"批量改,1 turn 解决
Step 5: cleanup runs/.cache 设计问题:问用户选 A/B/C/D
Step 6: 报告改了什么 + 为什么(对应 retro 每条 ID)
Step 7:(可选)用户决定要不要重跑 L1 验证 fix
```

**每步完成后用 TodoWrite 标 done,不批量打勾**。

---

## §8. 新 session 第一句直接 paste

```
我在 ai-auto-harness 项目继续 phase 5 收尾工作。上一 session 太长换了新会话。

请按 docs/superpowers/handoffs/2026-05-25-session-handoff.md 接续。
具体:
1. 先读那份 handoff 的 §1-§7
2. 然后按 §7 的工作流,从 P3-5/P4-1/S-1 开始修(P4-5 是测试任务,先跳)
3. 全部高/中/低修完后,告诉我:每条改了什么 + 为什么
4. cleanup runs/.cache 问题(handoff §5 末尾)给我 A/B/C/D 选择

硬约束:
- 不许动用户训练 / runs 下实际权重文件(13G+9G)
- 不许重写已实现的 SKILL.md 整文件,只 patch
- 不许重开 brainstorming,设计已 OK
- 不许跑 L1 长 worker(只准写 prompt,我自己跑)
```

---

## §9. 上一 session 已写未提交的修改(若有)

本 session 还没改任何 phase 5 相关文件(只读了 retro + 验了 skill 存在 + 写了本 handoff)。
git status 干净(本 handoff 是新增文件,不影响)。

新 session 可直接开干,无需 rollback。
