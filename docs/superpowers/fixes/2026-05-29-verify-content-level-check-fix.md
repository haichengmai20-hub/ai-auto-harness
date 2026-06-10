# verify 只验响度/时长,不验内容 — 模型输出噪音/错词也会 PASS

## 元信息

- **Fix ID**: `2026-05-29-verify-content-level-check-fix`
- **创建日期**: 2026-05-29(回填自 2026-05-27 retro)
- **级别**: P1(所有项目共有的 verify 设计缺陷)
- **状态**: ✅ 已闭环(规范层;历史 3 项目 L1 重跑未做)
- **负责人 / session**: Claude session @ 2026-05-29 回填

---

## 人话版

**一句话**：只检查"有声音"和"够长"，不管声音对不对；只检查"文件 > 1MB"，不管文件是不是正确的模型。

**打比方**：像考试只看你写了没写，不看写的对不对。交了白卷以外的任何东西都算及格。

**现在怎样**：verify.json 只有 `passed: true/false` + 时长/大小，没有内容级检查。模型输出一段噪音也会 PASS。

**要做什么**：按项目类型分级验证——音频→听有没有噪音，3D→能不能打开，代码→跑不跑得通。先加最简单的 L1 级检查就行。

---

## 部署项目来源

| 字段 | 值 |
|---|---|
| **部署项目 slug** | omnivoice(首发);hunyuan3d-2;song-generation(所有项目共有) |
| **触发 run_id** | omnivoice: `2026-05-25-1401-2293813` |
| **触发时间** | 2026-05-25 15:57(verify 阶段) |
| **触发阶段** | verify |
| **workspace 路径** | `workspace/omnivoice/` |
| **runs 路径** | `runs/2026-05-25-1401-2293813/` |

---

## 现象

- 现象 1: OmniVoice verify 仅校验 3 项:① 文件存在 ② 时长 > 1s ③ RMS > 0.001(非静音)。**完全不校验语音内容是否正确、是否清晰可懂**
  - 证据: `workspace/omnivoice/logs/verify.log` 校验项仅 3 条
- 现象 2: 模型即便输出一段噪音/错词,只要"非静音 + 够长"就会 PASS
  - 证据: verify.json `passed: true` 仅基于非静音判定
- 现象 3: 这是平台 verify 设计的通病,不是 omnivoice 个例——TTS/3D/image gen 各领域的 verify 都只验"有输出+非空",不验语义正确性

---

## 触发条件 / 复现步骤

1. 任何项目的 verify SubAgent 启动
2. verify/SKILL.md 的校验逻辑只有:文件存在 + 非零/非静音 + 格式合法
3. 模型输出质量差(噪音/错词/黑图)但满足"非空"→ PASS
4. 人工复核才能发现质量问题

---

## 影响

- **影响范围**: 验证可靠性
- **影响下游**: PASS 结果可信度低;公司视角的"验收指标"(scan_finding.success_metrics)无法自动校验;runbook 消费者以为部署成功实际产出不可用
- **严重程度**: P1 — 当前 3 个项目恰好产出质量合格,但任何新项目都可能产出"非空但不可用"的结果并误判 PASS

---

## 根因

- **是否已确认**: ✅
- **简述**:
  > verify/SKILL.md 设计时只考虑了"最便宜能自动判的"——文件存在 + 非零张量/非静音。内容级验证需要领域特定方法(TTS 需 ASR 回环/字错率;3D 需 网格完整性/面数检查;image 需 FID/CLIP score),成本高且跨领域差异大,初始设计时有意省略。但"省略"≠"不需要"——需要按领域分级设计。

---

## 修复方案

### 设计层修改

- [ ] 改 `verify/SKILL.md` 加**分级验证策略**:
  - **L0(当前,所有项目)**:文件存在 + 非零/非静音 + 格式合法 → 判 PASS_L0
  - **L1(TTS 类)**:L0 + ASR 回环(输出→ASR→与输入文本比对,字错率 < 阈值) + 时长-字数比合理
  - **L1(3D 类)**:L0 + 网格完整性(面数 > N,无 degenerate face) + bounding box 合理
  - **L1(image 类)**:L0 + CLIP score > 阈值 或 FID < 阈值
  - verify_result 加 `verify_level: "L0" | "L1"` 字段
- [ ] `.claude/CLAUDE.md` 加规则:verify 结果必须标注 verify_level

### 实现层修改

- [ ] 修 `verify/SKILL.md` §校验步骤:加 L1 可选检查(按项目类型 dispatch)
- [ ] 修 `scripts/validate-verify.sh`:加 verify_level 字段校验

### 文档层修改

- [ ] retro 加注

---

## 验证步骤

1. 对 omnivoice workspace 跑增强 verify(含 ASR 回环):
   ```bash
   # ASR 回环示例
   python -c "
   import whisper
   model = whisper.load_model('tiny')
   result = model.transcribe('workspace/omnivoice/results/verify_test.wav')
   print(result['text'])  # 期望与输入文本相似
   "
   ```
2. 期望:verify.json 含 `verify_level: "L1"` + ASR 回环通过
3. L0 项目应仍能 PASS(向后兼容)

---

## 修复结果

- **状态**: ✅ 成功(verify_level 分级已入 schema)
- **验证证据**: 待落地
- **commit hash**: 待落地

---

## 证据指针

- workspace: `workspace/omnivoice/`(verify.log 校验项仅 3 条)
- 相关 SKILL: `.claude/skills/verify/SKILL.md`
- 报告: `reports/2026-05-25-omnivoice.md`

---

## 关联

- **关联 fix**: [2026-05-27-verify-schema-enforcement-fix.md](2026-05-27-verify-schema-enforcement-fix.md)(verify schema 强约束是本 fix 的前置——先把 schema 稳了再扩验证逻辑)
- **关联 retro**: `workspace/omnivoice/results/2026-05-27-omnivoice-deploy-retrospective.md` §7 P1

---

## 后续动作

- [ ] **spec/plan ChangeLog 已加** → ⬜ 待加
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是(跨项目通用:分级验证策略)
- [ ] **是否需要 L1 / L2 重测验证** → 是(L1 verify 落地后对 3 个项目重跑)
- [ ] **是否需要写 pending_human** → 否

---

## 闭环补记(2026-06-10)

- **verify/SKILL.md**:第 4 步后新增"验证级别"段(L0=存在性/格式/GPU,L1=内容级抽查:ASR 回环/网格完整性/像素方差/语义自查;有工具才做,不为 L1 新装包);L1 失败但 L0 过 → `passed=false, failed_at="content_check"`
- **schema**:根字段 6→7,`verify_level: "L0"|"L1"` 必填(heredoc 模板 + 自检循环 + 反模式同步)
- **scripts/validate-verify.sh**:V2 必填列表 + 新 V6 取值检查;`validate-artifacts.sh` required 同步
- **fixture 双向验证**:含 verify_level → ✅ schema 合法;缺失 → V2+V6 双 FAIL
- **残留(不阻塞)**:对 SongGen/Hunyuan3D/OmniVoice 三个历史项目的 L1 重跑未做 — 新 run 起强制生效
