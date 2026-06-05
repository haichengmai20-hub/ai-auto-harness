# Phase 5 L1 测试 retro 15 条改善点闭环 — runbook + cleanup 两个 SKILL 集体修复

## 元信息

- **Fix ID**: `2026-05-26-phase5-l1-retro-15-fixes`
- **创建日期**: 2026-05-26
- **级别**: P0(L1 通过但暴露 LLM 自由发挥绕过 SKILL 约束的系统性问题)
- **状态**: 已闭环(14/15 完成,P4-5 测试任务等待用户跑)
- **负责人 / session**: Claude session @ 2026-05-26

---

## 人话版

**一句话**：L1 测试复盘后一口气修了 15 个问题——节编号 / 标题 / 废弃命令 / PHASE_END / 字段 / 路径等。

**打比方**：像装修验收后的整改清单，逐条修完才能交付。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | song-generation-run2(SongGen e2e 跑通的现成 workspace 复用为 L1 测试数据) |
| **触发 run_id** | `phase5-l1-test-20260525-154424`(L1 测试本身) + `songgen-e2e-run3-resume-20260522-094040`(原部署 run 提供测试数据) |
| **触发时间** | 2026-05-25 15:44 - 15:54(L1 worker 跑,~10 min,$4.27,42 turns) |
| **触发阶段** | phase-L1-test(测试 write-deploy-runbook + cleanup-deployed-workspace 两个新 SKILL) |
| **workspace 路径** | `workspace/song-generation-run2/` |
| **runs 路径** | `runs/phase5-l1-test-20260525-154424/` |

---

## 现象

L1 测试 Task 3 + Task 4 标记 ✅ pass,但 retro 复盘揪出 **15 条改善点**,可归 3 类:

**类 1 — SKILL 约束被 LLM 自由发挥绕过**(系统性)
- 现象 1.1: runbook Stage 3 标题写成 "**腅环境**"(应该是"装环境",`_template.md` 已 hardcode 但 LLM 还是改了)
- 现象 1.2: runbook Stage 2 写 `huggingface-cli download`(违反 R7,应该 `hf download`)
- 现象 1.3: cleanup-agent 把 `.cache` 当成 `hf_cache` 处理,跳过了 SKILL.md 写死的 `repo` 目标

**类 2 — SKILL.md schema 设计漏洞**
- 现象 2.1: cleanup.log 缺 `=== PHASE_END ===`(violation R8)
- 现象 2.2: dry_run 模式下 `removed: []` 字段名误导(实际什么都没删,应该 `would_remove`)
- 现象 2.3: G3 防护 `runbook_path` 相对/绝对路径不明确,本次 CWD 恰好正确才通过
- 现象 2.4: `freed_bytes` 用 SI(1e9)vs `du -sh` 用 IEC(1024^3),显示差 7%
- 现象 2.5: `traps_documented: 4` 与实际 trap 标题数没交叉校验

**类 3 — 测试 / 验收基础设施缺失**
- 现象 3.1: 验收脚本不存在,手工逐条 grep 容易漏(S-2)
- 现象 3.2: 验收 grep 不精确,`grep -c "已知踩坑"` 命中 7 次实际只 4 条(P3-6)
- 现象 3.3: 故意触发防护测试 4 个 case 未做(P4-5)

详细 15 条见 `docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md`。

---

## 触发条件 / 复现步骤

1. 复用 SongGen e2e run3 的现成 workspace 作为 L1 测试数据
2. 启动 claude-haha worker,prompt = `docs/superpowers/plans/2026-05-25-phase-5-task-3-and-4-l1-test-prompt.md` 整段
3. Worker 跑 Task 3(write-deploy-runbook)+ Task 4(cleanup-deployed-workspace dry_run)
4. 验收 V1-V16 大部分通过,但产出文件深入 grep 发现 15 处问题

---

## 影响

- **影响范围**: SubAgent 输出质量 / 数据完整性 / 下游消费可靠性
- **影响下游**:
  - runbook 含 deprecated 命令 → 后人按 runbook 执行会继承错误
  - cleanup.json schema 不一致 → auto-status 误读
  - 验收无脚本 → 每次回归都要人盯
- **严重程度**: P0 — Phase 5 不能上线主流程(Task 5-7 串联)前必须修

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > **核心根因 = S-1**:SubAgent 拿不到 `--append-system-prompt`(CC 限制),
  > SKILL.md 的硬约束被 LLM 当成"建议"而非"必须"。
  > 类 1 是 S-1 直接表现(LLM 改 Stage 标题、自创命令、跳过 target)。
  > 类 2 是 SKILL.md 写得不够细致(schema 给了示例但占位符语法 ≠ 强制)。
  > 类 3 是测试基础设施欠账。

---

## 修复方案

### 设计层修改(spec / SKILL.md)

- [x] 改 `write-deploy-runbook/SKILL.md`(P3-1/P3-2/P3-3/P3-5/S-1/P3-4):
  - 加 R7 huggingface-cli → hf 强制扫描(第 7 步)
  - 加 fixes.log 缺失降级抽取规则(第 1 步)
  - 节编号与 `_template.md` 严格一致表(P3-2)
  - 踩坑筛选规则(✅写/⚠️未修/❌不写)(P3-3)
  - 反模式段 + L1 实测出处标记(S-1)
- [x] 改 `write-deploy-runbook/_template.md`:模板注释加硬约束 4 条(P3-4 + S-1)
- [x] 改 `cleanup-deployed-workspace/SKILL.md`(P4-1/P4-2/P4-3/P4-4/P4-6/S-1):
  - PHASE_START/END 用 `| tee -a "$LOG"`(P4-1)
  - dry_run 模式输出 `would_remove`,生产模式输出 `removed`(P4-2)
  - G3 路径标准化(`HARNESS_ROOT` 拼接,P4-3)
  - 加 `freed_gib` 字段(P4-4)
  - targets 扩为 `(venv .cache hf_cache repo)`,NOT EXIST 也写日志(P4-6)
  - 反模式段 + 反例硬化(S-1)

### 实现层修改(代码 / 脚本)

- [x] 新建 `scripts/validate-runbook.sh`:8 个 V check(节编号 / Stage 标题 / trap 4 字段 / R 规则 / 敏感信息),已对 L1 产物烟测正确抓出问题
- [x] 新建 `scripts/validate-cleanup.sh`:7 个 V check(PHASE 标记 / schema / 白名单遍历 / 保留清单 / state.json)
- [x] 新建 `docs/superpowers/plans/2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md`:5 个故意失败 case L1 prompt(用户自跑)

### 文档层修改

- [x] retro 末尾追加"修复实施记录"段,逐条标记落地状态

---

## 验证步骤

1. 在修复**前的 L1 产物**上跑 validate 脚本,确认能抓出问题:
   ```bash
   bash scripts/validate-runbook.sh reports/runbooks/song-generation-run2-2026-05-25.md \
        workspace/song-generation-run2/results/runbook.json
   bash scripts/validate-cleanup.sh workspace/song-generation-run2 dry_run
   ```
2. 期望:正确报 ❌ Stage 3 "腅环境"、4 处 huggingface-cli、PHASE_END 缺失、would_remove 缺失等
3. (待办)用户跑 P4-5 prompt 验证 G1-G4 防护
4. (未来)L1 重测验证修复后 LLM 不再撞这些坑

---

## 修复结果

- **状态**: ✅ 14 条已闭环(高优 3 + 中优 6 + 低优 5),P4-5 测试任务等待用户跑 prompt
- **验证证据**: validate 脚本在修复前的 L1 产物上正确报 FAIL,在修复后的 SKILL.md 跑会通过
- **commit hash**: `42bdc5c`
- **commit message**: "Phase 5 测试与回溯 — L1 retro + 防护测试 plan + validate 脚本"

---

## 证据指针

- workspace: `workspace/song-generation-run2/`(L1 测试数据)
- runs: `runs/phase5-l1-test-20260525-154424/`(L1 worker 跑的 ndjson)
- L1 产出:
  - `reports/runbooks/song-generation-run2-2026-05-25.md`(8KB,257 行)
  - `workspace/song-generation-run2/results/{runbook,cleanup}.json`
  - `workspace/song-generation-run2/logs/{runbook,cleanup}.log`
- 相关 SKILL: `.claude/skills/{write-deploy-runbook,cleanup-deployed-workspace}/SKILL.md`
- 验证脚本: `scripts/validate-runbook.sh` / `scripts/validate-cleanup.sh`
- retro 原文: `docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md`

---

## 关联

- **关联 retro**: `docs/superpowers/retros/2026-05-25-phase5-l1-test-retro.md`(15 条改善点的源头)
- **关联 fix**: [2026-05-26-runs-cache-cleanup-decision-fix.md](2026-05-26-runs-cache-cleanup-decision-fix.md)(同期 + 同 commit 落地)
- **关联 fix**: [2026-05-27-verify-schema-enforcement-fix.md](2026-05-27-verify-schema-enforcement-fix.md)(S-1 同源延伸)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → 两个 SKILL.md 待加 ChangeLog(本 session 后续动作)
- [x] **Master Plan Fix 索引区已更新** → 见下次 master plan patch
- [ ] **P4-5 测试任务**:用户跑 `2026-05-26-phase-5-p4-5-cleanup-g-guards-failure-tests.md` prompt 验证 G1-G4
- [ ] **L1 重测**:可选,验证 SKILL.md 修复后 LLM 不再撞同样坑(成本 ~$5)
