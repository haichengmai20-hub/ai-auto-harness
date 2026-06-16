# Fix: CC 版同步 Q4/Q5/F2/F9 安全集

**日期**: 2026-06-16
**严重度**: P1（生产 CC 版缺这些修复，新项目类型成功率上不去）
**触发**: 上一轮 `be54e47` 只改了 Hermes 侧 `phase-*.sh`，生产用的 CC 版 `.claude/skills/` 未同步
**关联**: [framework-issues-cc-complete.md §七](../../framework-issues-cc-complete.md)；[#41 F9 毁文件修正](2026-06-16-f9-error-class-destructive-autofix-fix.md)

---

## 人话版

平台有两套引擎：生产跑的 **CC 版**(读 `.claude/skills/*/SKILL.md` 的 LLM agent)和迁移的 **Hermes 版**(执行 `hermes/scripts/phase-*.sh`)。上一轮的 Q4/Q5/F2/F9 只改在 Hermes 侧，CC 版一行没动。这一轮把**已验证安全**的部分翻译进 CC 的 run-and-repair SKILL。F9 那三个会毁文件的 sed **绝不进 CC**——CC 版从一开始就只拿安全集 + 一条「别 sed 改 entry 源码」的红线。

## 问题

CC 与 Hermes 实现范式不同：
- Hermes：`phase-run-and-repair.sh` 是 bash if-elif 链，自己跑 run/repair。
- CC：SubAgent(LLM)读 SKILL.md，用 agent loop 做 run/repair —— 所以同步不是 copy 脚本，是把逻辑翻译成 LLM 指令 + bash 模板。

CC `run-and-repair/SKILL.md` 缺：Q4(HF id→本地路径)、Q5(超时分级)、F2(no_proxy localhost)、F9(错误分类)。

## 方案（patch 式，不重写整文件）

`/.claude/skills/run-and-repair/SKILL.md`：

| 项 | 落点 | 内容 |
|---|---|---|
| **F2** | 第 0 步 env | `export no_proxy/NO_PROXY=127.0.0.1,localhost`(只加 localhost,不碰外网域名,R7) |
| **Q4** | 新增第 0.7 步 | jq 读 `weight_target_paths`→grep repo 定位→Edit/sed 把模型加载处的 HF id 换本地绝对路径;**只替本地目录存在的 + 只替加载处** |
| **Q5** | 第 1 步 | 从 `estimated_params_b` 算 `INFER_TIMEOUT`(≤1B 900s…>30B 5400s,默认 1800s);短任务 `timeout $INFER_TIMEOUT` |
| **F9** | 第 3 步错误表 + 红线 | 7 类新错误模式→修复方向(table 行);**红线**:Megatron CLI flag/端口/分布式 = 环境变量或转人工,**严禁 sed 改 .py 源码**;TE/系统依赖不计轮,Megatron CLI 参数类直接转人工 |
| schema | run.json | `error_class` 扩 7 类 + 新增 `suggested_fix` 字段 |
| 反模式 | 反模式段 | +3 条(sed 改源码 / HF id 不替 / 超时写死 600s) |

**P3 不需 CC 同步**：`scripts/reconcile-state.sh` 在 `scripts/`(非 `hermes/`),CC 与 Hermes 共用,已生效。

**F2 未进 CLAUDE.md**：主 agent 只 dispatch 不做 localhost HTTP，F2 的执行点在 run-and-repair SubAgent(SubAgent 收不到 CLAUDE.md,S-1)→ 放 SKILL 才到达执行者。CLAUDE.md 那条留给后续 env-facts 整理。

## 影响范围

- `.claude/skills/run-and-repair/SKILL.md`（第 0/0.7/1/3 步 + schema + 反模式 + ChangeLog）

## 与 #41 的关系

#41 在 Hermes 侧把毁灭性 F9 sed 修成「不动文件」。本 fix 同步到 CC 时**只搬安全后的版本** + 显式红线 + 反模式，确保 CC 永远不会引入那三个 sed。

## 验证

- [x] SKILL 自查：全文无「sed 改 .py 塞 flag/替数字」指令；红线 + 3 条反模式齐全
- [x] Q4 只替本地存在目录(`-d "$LOCAL"` 过滤)+ 只替加载处(指令明确)
- [x] Q5 分级表与 Hermes 一致(≤1B 900 / ≤3B 1200 / ≤10B 1800 / ≤30B 3600 / >30B 5400)
- [ ] 实战：下一个含 HF id / Megatron / 系统依赖的 CC cron run 验证

## 状态

- [x] fix.md + SKILL 改动 + ChangeLog
- [x] framework-issues-cc-complete.md §七 / 优先级表标 CC 已同步
- [ ] commit + 回填 hash

## 修复结果

- **commit hash**: (待回填)
