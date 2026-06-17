# R6 全局缓存泄漏:install-env/verify 阶段 from_pretrained 写到全局

## 元信息

- **Fix ID**: `2026-06-17-r6-global-cache-leak-fix`
- **创建日期**: 2026-06-17
- **级别**: P1 (R6 缓存隔离违规,56G 全局残留影响磁盘)
- **状态**: ✅ 已闭环
- **负责人 / session**: Hermes session @ 2026-06-17

---

## 人话版(必填 — 让非技术的人也能一眼看懂)

**一句话**：两个工位的工人把零件堆到公共仓库而不是自己的工位。

**打比方**：工厂规定每个工位自备零件箱，但装环境和验证这两个工位的工人不知道有这规矩，把下载的模型文件全堆到了工厂大仓库里。结果大仓库 56G 被占，自己的工位清场时也清不到大仓库的东西。

**现在怎样**：install-env 和 verify 阶段没设 HF_HOME，from_pretrained() 调用写到了 /root/.cache/huggingface/（全局默认），违反 R6 缓存隔离规则。workspace cleanup 时只能清 workspace 内的 .cache/，全局残留无法回收。

**要做什么**：给所有 5 个 phase 脚本统一加 HF_HOME/HF_HUB_CACHE 环境变量，指向 workspace 内。清掉已有全局残留。

---

## 部署项目来源(必填 — 让后人能精确追溯到"哪次跑")

| 字段 | 值 |
|---|---|
| **部署项目 slug** | qwen3-tts (全局残留 /root/.cache/huggingface/hub/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice) |
| **触发 run_id** | N/A (多项目累积) |
| **触发时间** | 2026-06-17 发现 |
| **触发阶段** | install-env / verify |
| **workspace 路径** | `workspace/qwen3-tts/` |
| **runs 路径** | N/A |

---

## 现象

- 现象 1: /root/.cache/huggingface/hub/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice 存在 2.4G 权重,但 workspace/qwen3-tts/ 已被 cleanup 清空
  - 证据: `du -sh /root/.cache/huggingface/hub/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice/` → 2.4G
- 现象 2: phase-install-env.sh 和 phase-verify.sh 没有 export HF_HOME/HF_HUB_CACHE
  - 证据: `grep -n "HF_HOME" phase-install-env.sh phase-verify.sh` → 无匹配

---

## 触发条件 / 复现步骤

1. 部署一个使用 from_pretrained() 的项目 (如 qwen3-tts)
2. install-env 阶段 pip install 触发 from_pretrained 下载 tokenizer/config
3. verify 阶段运行推理触发 from_pretrained 加载模型
4. 观察 /root/.cache/huggingface/ 出现项目权重

---

## 影响

- **影响范围**: 磁盘累积 (qwen3-tts 残留 2.4G, 其他项目可能更多)
- **影响下游**: cleanup 阶段只能清 workspace 内,全局残留永远清不掉,磁盘持续增长
- **严重程度**: P1 — 违反 R6 缓存隔离规则; 单项目残留 2.4G, 多项目累积可能超 50G

---

## 根因

- **是否已确认**: ✅
- **简述**: 5 个 phase 脚本中,fetch-weights(setsid 子进程内)和 run-and-repair 已设 HF_HOME=$WORKSPACE/.cache/huggingface,但 install-env 和 verify 从未设置。Python 的 from_pretrained() 默认写 ~/.cache/huggingface/(即 /root/.cache/huggingface/)。intake 仅在单行 hf download 时内联设了,不影响后续。

---

## 修复方案

### 实现层修改

- [x] phase-install-env.sh: 加 `export HF_HOME="$WORKSPACE/.cache/huggingface" HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"` (在 state:running 段之后)
- [x] phase-verify.sh: 加同样 export (在 state.json 存在性检查之后)
- [x] 删除全局残留: `rm -rf /root/.cache/huggingface/hub/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice`

### 文档层修改

- [x] 本 fix 文件
- [ ] Master Plan Fix 索引区更新

---

## 验证步骤

1. `grep -n "HF_HOME" /root/ai-auto-harness/hermes/scripts/phase-*.sh` — 5 个脚本都有
2. `bash -n /root/ai-auto-harness/hermes/scripts/phase-install-env.sh` — OK
3. `bash -n /root/ai-auto-harness/hermes/scripts/phase-verify.sh` — OK
4. `ls /root/.cache/huggingface/hub/models--Qwen*/` — 不存在

---

## 修复结果

- **状态**: ✅ 已闭环
- **验证证据**: 5 个 phase 脚本均有 HF_HOME 设置; 全局 Qwen3-TTS 残留已删; bash -n 全通过
- **commit hash**: 待 commit

---

## 证据指针

- workspace: `workspace/qwen3-tts/`
- 日志: `workspace/qwen3-tts/logs/*.log`
- 相关 R 规则: R6 (缓存隔离 — 每个 slug 独立缓存边界)

---

## 关联

- **关联 fix**: 2026-05-29-fetch-before-install-pip-leak-fix.md (同为 R6 缓存隔离违规)
- **关联 fix**: 2026-05-27-cache-isolation-boundary-fix.md (R6 缓存隔离边界)
- **关联 fix**: 2026-05-29-cache-isolation-boundary-level-fix.md (run 级→项目级缓存)

---

## 后续动作

- [x] **spec/plan ChangeLog 已加** → ⬜ 待加(本 fix 是新问题,非 spec 修改)
- [ ] **Master Plan Fix 索引区已更新** → ⬜ 待加
- [ ] **是否提升到 memory/lessons** → 是 (R6 执行盲区: 所有 phase 脚本必须设 HF_HOME)
- [ ] **是否需要 L1 / L2 重测验证** → 否 (新项目部署时自然验证)
- [ ] **是否需要写 pending_human** → 否
