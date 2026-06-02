# fetch-weights 对齐 huggingface_hub 1.x:去 `--resume-download` + `HF_HUB_ENABLE_HF_TRANSFER`→Xet

## 元信息

- **Fix ID**: `2026-06-02-fetch-weights-hf1.x-modernization-fix`
- **创建日期**: 2026-06-02
- **级别**: P1(每次 fetch 都可能撞)
- **状态**: 已闭环
- **负责人 / session**: Claude session @ 2026-06-02

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | controlfoley |
| **触发 run_id** | `e2e-controlfoley-20260602-103052` |
| **触发时间** | 2026-06-02 10:30(+08:00) |
| **触发阶段** | fetch-weights |
| **workspace 路径** | `workspace/controlfoley/` |
| **runs 路径** | `runs/e2e-controlfoley-20260602-103052/` |

---

## 现象

- 现象 1(P2-4): `hf download ... --resume-download` 报错 —— huggingface_hub 1.x 已移除该 flag,agent 撞错后开始试错。
- 现象 2(P2-9): 日志出现 `HF_HUB_ENABLE_HF_TRANSFER` 的 FutureWarning —— hf_transfer 已被 Xet 协议取代。

**环境事实**(本机已验证):`huggingface_hub 1.17.0` + `hf_xet 1.5.0`,`HF_XET_HIGH_PERFORMANCE=False`。

---

## 触发条件 / 复现步骤

1. 新环境装了 huggingface_hub 1.x(`hf_xet` 随包捆绑)。
2. fetch-weights SKILL 模板里仍写 `--resume-download` + `export HF_HUB_ENABLE_HF_TRANSFER=1`。
3. 跑 `hf download <repo> ... --resume-download` → 报 "unknown option";设 `HF_HUB_ENABLE_HF_TRANSFER=1` → FutureWarning。

---

## 影响

- **影响范围**: fetch-weights 阶段命令可用性 + 下载加速路径。
- **影响下游**: agent 撞 flag 报错后试错,浪费 turn;FutureWarning 噪音掩盖真问题。
- **严重程度**: P1 —— 每次 fetch 必经,deprecated 命令等于继承错误。

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > fetch-weights SKILL / fetch-agent.md / auto-deploy SKILL / README 的命令模板停留在 huggingface_hub 0.x 时代:`--resume-download`(1.x 移除,默认续传)+ `HF_HUB_ENABLE_HF_TRANSFER`(被 Xet 取代)。

---

## 修复方案

### 设计层修改(SKILL / agent / doc）

- [x] `fetch-weights/SKILL.md`:删全部 `--resume-download`(命令 + 接续/重启文字);`HF_HUB_ENABLE_HF_TRANSFER=1`→`HF_XET_HIGH_PERFORMANCE=1`(硬规则 4 / 第 0 步 export / 第 2 步 setsid 块);`pip install -U "huggingface_hub[hf_transfer]"`→`pip install -U huggingface_hub`;反模式段加 2 条。
- [x] `.claude/agents/fetch-agent.md`:"你绝不做"段更新(去 `huggingface-cli --resume-download`,改 Xet)。
- [x] `.claude/skills/auto-deploy/SKILL.md`:fetch dispatch prompt env 名改 Xet + 注明默认续传。
- [x] `README.md`:R7 行 + cache 隔离段 + fetch 速查行(3 处 prescriptive 引用;历史事故记录行保留不动)。
- [x] `.claude/CLAUDE.md` R7 段:加 `--resume-download` / Xet / 并发三条 + ChangeLog。

### 实现层修改

- 无(纯命令模板 + 文档)。

---

## 验证步骤

1. `python3 -c "import huggingface_hub as h;print(h.__version__)"` → 1.x。
2. `grep -rn "resume-download\|HF_HUB_ENABLE_HF_TRANSFER" .claude/skills/fetch-weights/SKILL.md` → 仅出现在 ❌-禁用上下文。
3. 实跑小 repo `HF_XET_HIGH_PERFORMANCE=1 hf download <repo> --local-dir ... --token $HF_TOKEN` → 无 unknown-option 报错、无 FutureWarning。

---

## 修复结果

- **状态**: ✅ 成功(SKILL/agent/doc 全部对齐 1.x)
- **commit hash**: <填 WS2 commit>
- **commit message**: `ai-auto: P2 fetch — hf 1.x 现代化（去 --resume-download / Xet）+ 并发下载/僵尸防护`

---

## 证据指针

- runs: `runs/e2e-controlfoley-20260602-103052/`
- SKILL: `.claude/skills/fetch-weights/SKILL.md` / `.claude/agents/fetch-agent.md`
- R 规则: `.claude/CLAUDE.md` R7

---

## 关联

- **关联 fix**: [2026-06-02-concurrent-download-zombie-guard-fix](2026-06-02-concurrent-download-zombie-guard-fix.md)(同 fetch 簇,并发/僵尸)
- **关联 retro**: ControlFoley e2e 2026-06-02(问题 3/4/6)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ✅(fetch-weights SKILL + CLAUDE.md R7)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ WS3
- [x] **是否提升到 memory/lessons** → 否(`memory/lessons/torch-sm12.md` / hf-gated 已覆盖 hf 经验,命令变更走 SKILL)
