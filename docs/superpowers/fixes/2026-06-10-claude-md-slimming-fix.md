# CLAUDE.md 瘦身:23KB → 结论版,详解/历史外迁 reference

## 元信息

- **Fix ID**: `2026-06-10-claude-md-slimming-fix`
- **创建日期**: 2026-06-10
- **级别**: P2(维护成本/遵守率)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-10(外部 review #8,用户拍板执行)

---

## 人话版

**一句话**：规章制度从 23 页小册子压成 1 页墙贴,细则挂参考手册。

**打比方**：员工手册写了 23 页,每条规定都带 3 个案例 + 立法历史。结果没人看完。改成:墙上贴 1 页"十条铁律"(每条一两句话),案例和历史装订成参考手册放档案室,墙贴注明"详见手册"。规矩一条没少,但天天能被看见。

**现在怎样**：`.claude/CLAUDE.md` 23KB(≈6K token),每个 session 注入主 agent context。规则正文混着示例、bash 模板、ASCII 目录树、10 条历史 ChangeLog。context 越长单条规则的注意力权重越低。

**要做什么**：CLAUDE.md 只留**结论**(每条 R/D 规则 1-3 行硬禁令);详解/示例/模板/目录树/历史 ChangeLog 原文外迁 `docs/superpowers/specs/2026-06-10-r-rules-reference.md`;各阶段操作细节本就在各 SKILL.md(SubAgent 收不到 CLAUDE.md,skill 内复述是故意设计,见 #31 S-1 / review #13 拒绝理由)。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | N/A 仅平台改善(外部 review #8 + 用户拍板) |
| **触发 run_id** | N/A(动机数据:全部 5 项目 run 的 R9 违反率 100%,task_called=0) |
| **触发时间** | 2026-06-10 |
| **触发阶段** | ops |
| **workspace 路径** | N/A |
| **runs 路径** | N/A |

---

## 现象

- `.claude/CLAUDE.md` 22958 字节;其中 落盘目录树 ~2.3KB、R 规则详解+示例 ~6KB、D1-D7(治理 spec 的提炼复制品)~3.5KB、ChangeLog 历史 10 条 ~4.5KB
- 实测遵守率:R9 在 hook 警告 + CLAUDE.md 详述双管齐下仍 5/5 项目违反(#31);R4 连续 sleep 仍复发 — 说明"更长的解释"没有换来"更高的遵守"
- 主 agent 每 session 全文注入,≈6K token 固定开销

---

## 根因

- **是否已确认**: ✅
- **简述**: 规则文档把"结论"与"教学材料"(示例/模板/历史)混在一个 prompt 文件里。LLM 对长 context 中部内容注意力衰减;规则的可执行内核(禁令+阈值)被 3 倍体积的解释稀释。教学材料的正确归宿是 reference(按需查)和 SKILL(SubAgent 实际读的地方),不是每 session 必注入的 CLAUDE.md。

---

## 修复方案

### 设计层

- [x] 新建 `docs/superpowers/specs/2026-06-10-r-rules-reference.md`:承接 CLAUDE.md 外迁的全部详解 — 落盘目录树、R1-R10 完整版(示例/bash 模板/教训语录)、历史 ChangeLog 归档。**内容原文搬运,不改语义**
- [x] 重写 `.claude/CLAUDE.md` 为结论版:资源硬约束表 + 工作流 + 落盘核心 4 行 + R1-R10 每条 1-3 行(只留禁令/阈值/正确姿势一句)+ D1-D7 每条 1 行 + ChangeLog(新条目 + 归档指针)
- [x] 修正顺带发现的过时路径(`skills/ai-auto/daily-auto.md` → 实际 `skills/auto-daily/` 等)
- [x] 规则零删减自查:R1-R10 / D1-D7 的每条硬禁令、阈值、超时动作在新版中均有对应行

### 验证

- [x] 体积:22958B → 目标 ≤ 8KB
- [x] 无程序化消费者:grep 确认 hooks/cron/scripts 只在 prose 里提到 CLAUDE.md,无解析
- [x] 规则覆盖自查表(fix 文档内)

---

## 规则覆盖自查(瘦身前后逐条对照)

| 规则 | 瘦身后保留的硬内核 |
|---|---|
| 资源约束表 | 原表全保留 |
| R1 | 只动自己 workspace;禁 kill 非 .cache/*.pid 的 PID;禁窥探他人 workspace |
| R2 | 每 phase 开始/结束双写 state.json(字段列举);模板→REF/SKILL |
| R3 | 5 阶段上限分钟数 + 超时动作全保留;代码兜底 enforce-wallclock.sh |
| R4 | ≤60s/禁连续/poll≤8 每 phase/setsid 正确姿势/退出比 sleep 划算 |
| R5 | fetch done 才 install,不并行 |
| R6 | 禁 --no-cache-dir / 禁并行 pip 同 venv |
| R7 | hf 非 huggingface-cli/无 --resume-download/禁 Xet+降并发/禁 unset proxy 与 no_proxy 加外网域名/pgrep 防并发/--token 显式 |
| R8 | PHASE_START/END 两行格式 |
| R9 | 只 Task() dispatch,Bash 仅路由 |
| R10 | sentinel 路径+必填字段+生产者写终态+PID 死(含 Z)即补写;兜底 reconcile-sentinels.sh |
| verify 独立判定 | 保留 |
| D1-D7 | 每条 1 行内核 + 指针两份治理 spec |

---

## 修复结果

- **状态**: ✅ 成功
- **验证证据**: 22958B → 7179B(69% 减);规则覆盖自查表全勾;`grep` 确认 hooks/cron/scripts 无程序化解析
- **commit hash**: `8159339`
- **commit message**: `ai-auto: P2 fix #38 — CLAUDE.md 瘦身 23KB→结论版,详解外迁 r-rules-reference`

---

## 关联

- **关联 fix**:`2026-06-10-external-review-sentinel-wallclock-runs-fix`(#37,本项为其裁决表 #8"缓"项,用户拍板转执行)、`2026-05-26-v1.1-hardening-fix`(R 规则当初整合进 CLAUDE.md 的来源)
- **关联 spec/plan ChangeLog 条目**:`.claude/CLAUDE.md` 2026-06-10 条目

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅
- [x] **Master Plan Fix 索引区已更新** → ✅
- [ ] **是否提升到 memory/lessons** → 否
- [ ] **是否需要 L1 / L2 重测验证** → 是(后续 run 观察 R 规则遵守率变化,尤其 R9/R4)
- [ ] **是否需要写 pending_human** → 否
