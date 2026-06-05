# Spec Addendum：部署 runbook 沉淀 + 工作区清理（runbook-agent + cleanup-agent）

**Status**：Addendum (增量补丁)
**Base spec**：[`2026-05-19-ai-auto-harness-design.md`](./2026-05-19-ai-auto-harness-design.md)（不动原 spec，本文件显式 reference）
**Phase**：Phase 5（接 phase 1-4 编号）
**Plan**：[`../plans/2026-05-25-phase-5-runbook-and-cleanup.md`](../plans/2026-05-25-phase-5-runbook-and-cleanup.md)
**Date**：2026-05-25

---

## 一句话目标

在现有 5 阶段流水线（intake / fetch-weights / install-env / run-and-repair / verify）末尾追加 **2 个 SubAgent**：

1. **runbook-agent**：从本次部署的 trace 抽出一份 **AI 友好** 的 markdown 部署 runbook，方便人或其他 AI 复现
2. **cleanup-agent**：在 runbook 写好后清理工作区的"可重建产物"（venv / .cache / repo），保留"不可重建产物"（state / results / logs / output），单次部署最终落盘从 ~30GB 降到 ~50MB

这两件事让平台从"跑通一次就完"升级到"跑通一次就沉淀一次知识 + 释放一次磁盘"，是 cron 化生产部署的最低门槛。

---

## 为什么现在加这两个 SubAgent

### 痛点 1：跑通一次不够，要让"下一个人 / 下一个 AI"也能跑通

SongGen 实测 269 min 跑通，过程里：
- 7 个 fix（sm_120 / flash_attn / hydra-core / torchcodec / symlink / pkg_resources / model.pt resume）
- 4 个 cu132 错路径
- 19 次 sleep 浪费

这些经验全在 `fixes.log` 和 ndjson 里，**人读不友好** + **新 AI 启动时不知道去 grep**。**runbook-agent 把它压缩成 5 stage 的可执行手册** —— 下次别人（或别的 AI）拿这份手册能 30-60 min 跑通，而不是 269 min。

### 痛点 2：30GB workspace 不清理，磁盘 5 个项目就满了

每个项目部署产 ~30GB（venv 9GB + .cache 6GB + weights 28GB + repo 200MB）。**跑 5 个项目 = 150GB**，机器磁盘容易撑爆。但 weights / venv 都是可重建的（runbook 已经写了怎么重建）。

需要一个 cleanup-agent **白名单原则** 清掉可重建部分，保留 trace 和输出样本。

### 痛点 3：现在的"跑完即归档"概念缺失，state.json 没终态

现有 state.json 的 `phase` 终态是 `done`，但 `done` ≠ "已归档可清理"。需要新增 `archived` 终态：`done → cleanup-agent 跑完 → archived`。`auto-status / auto-recover / auto-deploy` 等周边 skill 都要识别这个新终态。

---

## 架构总览

```
现状（5 个 SubAgent dispatch）：
  intake → fetch-weights → install-env → run-and-repair → verify
                                                          ↓ 全过(verify passed=true)
                                                          ↓
  write-recommendation (主 agent 在 task 5 调，已有)
                                                          ↓
  verifier-corrector (可选，已有)

新增（链尾 +2）：
                                                          ↓
            ★ write-deploy-runbook (Task subagent_type=runbook-agent)
                                                          ↓
            ★ cleanup-deployed-workspace (Task subagent_type=cleanup-agent)
                                                          ↓
                                       update state.json phase=archived
```

### 人话版

**一句话**：补充了两个阶段的设计——出报告（runbook）和打扫卫生（cleanup），之前的设计文档没覆盖。

**打比方**：像装修完加了两步——验收出报告（哪里好哪里不好）和保洁清理（搬走废料），之前只设计了装修本身。

**核心内容**：
- Runbook：标准化项目报告模板（slug / status / cost / verify / repair_log）
- Cleanup：跑完清理磁盘（pip 缓存 / hf 缓存 / venv / repo），白名单机制防止误删

---

## 触发条件（主 agent 在 auto-deploy / auto-daily 流水线末尾判断）

```python
if verify_result.passed:
    runbook_result = Task(subagent_type="runbook-agent", ...)
    if runbook_result.status == "success":
        cleanup_result = Task(subagent_type="cleanup-agent", ...)
    else:
        log("⚠️ cleanup 跳过：runbook 写失败，保留 workspace 等人手处理")
else:
    # verify 未过，runbook 仍然写（标 status=incomplete）
    runbook_result = Task(subagent_type="runbook-agent", ...)
    # cleanup 不跑（保留 workspace 给 run-and-repair 下次接续）
    log("verify 未过，workspace 保留")
```

### 反模式守护

| 反模式 | 守护 |
|---|---|
| 主 agent 自己 `rm -rf` | 必须通过 cleanup-agent dispatch（R9） |
| cleanup 在 verify 失败时清掉 workspace | cleanup-agent G4 防护：必须 `verify_passed=true` 或显式 `force_cleanup_incomplete: true` |
| runbook 失败但 cleanup 照清 | **runbook 必须先成功才允许 cleanup** —— 因为 runbook 抽信息源于 workspace，清了就抽不到 |

---

## Runbook 设计（AI 友好的关键）

### 文件路径
```
reports/runbooks/<slug>-<YYYY-MM-DD>.md
```
不带 run-id 后缀（避免重名混乱）。同一项目同一天再跑覆盖最新版（旧版在 git history 里）。

### 7 节固定结构

| 节 | 内容 | 抽取方式 |
|---|---|---|
| 1. YAML frontmatter | slug / github / hf_repos / status / total_cost / duration | 纯字段映射 |
| 2. **给 AI 的部署 prompt** | 整段复制给 Claude / ChatGPT 就能开跑的中文指令 | 模板 + LLM 填空 |
| 3. 前置要求 | GPU 显存 / 磁盘 / HF_TOKEN / 5090 sm_12 等硬约束 | 纯字段映射 |
| 4. 5 stage 逐步指令 | 每 stage 含命令 + 成功标志 + 已知踩坑 + 预计耗时 | LLM 从 logs/<phase>.log 提取 |
| 5. 已知错误 → 修复速查 | `error_message → fix_command` 二元结构 | LLM 从 fixes.log + decisions.md 抽 |
| 6. 成本/耗时摘要 | $X / Y min / Z turns | 纯字段映射(ndjson result event) |
| 7. 完整 trace 指针 | `runs/<run-id>/` 路径 | 纯字符串 |

### "给 AI 的 prompt" 模板示例

```markdown
你将按照下方 runbook 部署 SongGeneration。强制规则：
- 每 Stage 必须等"成功标志"出现才进下一 Stage，不许跳
- 遇到"已知踩坑"列表里的错误，**直接按修复方案改**，不要试错
- 整个流程需要 GPU(≥ 8GB free) 和磁盘(≥ 60GB free)
- 大约耗时 60-90 分钟

### Stage 1: clone
执行: git clone https://github.com/tencent-ailab/SongGeneration && cd ...
成功标志: ls -la 看到 sample.py / README.md / requirements.txt

### Stage 2: 拉权重 (28GB, ~4min @ 200MB/s)
执行: hf download lglg666/SongGeneration-Runtime ...
成功标志: du -sh ckpt 至少 15GB

### Stage 3: 装环境
**已知踩坑 1**: requirements.txt 第一行 pin torch==2.6.0+cu126，RTX 5090 sm_12 不兼容
修复: sed -i '/^torch/d' requirements.txt && pip install --pre torch ...
成功标志: python -c "import torch; assert 'sm_120' in str(torch.cuda.get_arch_list())"

[ Stage 4-5 同上 ]
```

### "已知踩坑"格式契约（强制）

每条踩坑必须是 `error_pattern → fix_command` 二元结构（不许散文）：

```markdown
### 已知踩坑 N: <一句话现象>

**触发条件**: <grep-able error message 或前置情况>
**根因**: <一句话>
**修复**:
\`\`\`bash
<复制可执行的命令>
\`\`\`
**验证修复成功**: <grep / python -c assert / ls 之一>
```

### 数据源映射

| Runbook 节 | 数据源 |
|---|---|
| 1. frontmatter | `state.json` + `runs/<run-id>/harness.stdout.ndjson` result event |
| 2. AI prompt | 5 stage 拼接 + `intake.json.entry_script` |
| 3. 前置要求 | `results/intake.json.gpu_picks` + `results/fetch.json.bytes_total` + `gated_repos` |
| 4. Stage 命令 | `results/{intake,fetch,install,run,verify}.json` + `logs/<phase>.log` 每阶段实际跑过的命令 |
| 4. 已知踩坑 | `logs/fixes.log` 每条一行直接转 |
| 5. 错误速查 | `logs/fixes.log` + `runs/<run-id>/decisions.md` |
| 6. 成本摘要 | `harness.stdout.ndjson` 最后 result event 的 `total_cost_usd / duration_ms / num_turns` |
| 7. trace pointer | `run_id` 已知 |

### 敏感信息处理（硬规则）

| 信息 | 处理 |
|---|---|
| HF_TOKEN 实际值 | **绝不写入**；runbook 只说 `export HF_TOKEN=hf_xxx`（占位符） |
| ANTHROPIC_API_KEY | 同上 |
| 绝对路径 `/root/ai-auto-harness/` | 替换为 `${HARNESS_ROOT}` 或相对路径，让别人在不同环境也能跑 |
| 私有 git URL（若有） | frontmatter 注明 `private: true, needs SSH` |
| pip 索引 URL 含 token | 抽出 token 替换为 `${PIP_TOKEN}` |

### 失败 case 也产 runbook

| 部署 outcome | runbook frontmatter status | runbook 内容差异 |
|---|---|---|
| verify passed=true | `status: success` | 完整 5 stage |
| verify passed=false 但 5 stage 都跑了 | `status: incomplete_verify_failed` | 完整 5 stage，Stage 5 标 ⚠️，带 pending_human 提示 |
| 卡在中间某 stage | `status: paused_at_<phase>` | 只到该 phase，后续标 "⚠️ 未到达" |
| blocked（资源不足等） | `status: blocked_<reason>` | 只到 intake，主要说"为什么没跑成" |

理由：就算这次没跑通，记下"踩到 stage 3 装环境就崩了"对后人也有 ROI。

---

## Cleanup 设计（防误删 + 可审计）

### 4 道防护

| 防护 | 检测 | 不通过的动作 |
|---|---|---|
| **G1 prefix 校验** | `workspace_path` 必须以 `/root/ai-auto-harness/workspace/` 开头且包含 slug | 立刻 raise，绝不动磁盘 |
| **G2 trace 完整** | `runs/<run_id>/` 存在且含 `harness.stdout.ndjson` + `meta.json` | raise + 写 pending_human |
| **G3 runbook 已写** | `runbook_path` 文件存在且 > 1KB（不是 empty / 半成品） | raise + 不清（runbook 是清理后唯一的"如何复现"依据） |
| **G4 verify_passed 或 explicit force** | 仅 `verify_passed=true` 时无条件清；`status=incomplete` 时**默认不清**，除非主 agent 显式传 `force_cleanup_incomplete: true` | raise + 跳过 |

任一 G1-G4 不过 → return `{skipped: true, reason: "<grade>"}`，**不清任何东西**。

### 白名单删（不用 `rm -rf $VAR/*` 模式）

```
# 删（白名单显式枚举）
$WORKSPACE/venv/                    # ~9 GB
$WORKSPACE/.cache/                  # ~6 GB（hf / pip / transformers cache）
$WORKSPACE/repo/                    # 200MB-2GB（git clone）

# 留（不可重建产物）
$WORKSPACE/state.json               # 阶段进度终态（archived）
$WORKSPACE/results/                 # 全部 phase result JSON
$WORKSPACE/logs/                    # 全部日志
$WORKSPACE/output/                  # 推理样本（audio / image / video）
$WORKSPACE/progress.md              # fetch 进度摘要（人读）
```

实现严格白名单：

```bash
WORKSPACE="$1"
# G1 prefix 防护（脚本入口必判）
case "$WORKSPACE" in
    /root/ai-auto-harness/workspace/*) : ;;
    *) echo "REFUSED: workspace path not in safe prefix"; exit 1 ;;
esac

# 显式删每个目标（不用 *）
for target in venv .cache repo; do
    if [ -d "$WORKSPACE/$target" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY] would rm -rf $WORKSPACE/$target ($(du -sh ... | awk '{print $1}'))"
        else
            rm -rf "$WORKSPACE/$target"
            echo "removed $WORKSPACE/$target" >> "$WORKSPACE/logs/cleanup.log"
        fi
    fi
done
```

**绝不用** `rm -rf $WORKSPACE/$VAR/*` 之类（`$VAR` 空就会清根）。

### 落盘（可审计）

cleanup-agent 写 3 件事：

```
workspace/<slug>/logs/cleanup.log              [新建] 每条 "removed X (size=Y MB)" + 总结
workspace/<slug>/results/cleanup.json          [新建] {removed: [...], kept: [...], freed_bytes: N, completed_at: ...}
workspace/<slug>/state.json                    [更新] phase: "done" → "archived", archived_at, freed_bytes
```

### dry_run 模式（debug 用）

主 agent 在 verify pass 后可选传 `dry_run: true` 给 cleanup-agent：
- 不真删
- log 输出 `would rm X (size Y)`
- 写 cleanup.json 时打 `dry_run: true` 标记

用途：首次开启 cleanup 时验证白名单 / CI 测试环境。production 用 `dry_run: false`（默认）。

---

## State Machine 变更（向后兼容）

```diff
{
  "slug": "song-generation",
  "phase": "intake|fetching|installing|running|verifying|done|archived",
+                                                              新增 ↑
  "phases_done": [...],
+ "runbook_path": "reports/runbooks/song-generation-2026-05-25.md",  // 新增,runbook-agent 写
+ "archived_at": "2026-05-25T14:35:00+08:00",                        // 新增,cleanup-agent 写
+ "freed_bytes": 34567890123,                                        // 新增,cleanup-agent 写
  "started_at": "...",
  "updated_at": "..."
}
```

旧 state.json（`phase` 没到 archived）被读到时按现状处理 —— 完全向后兼容。

### 周边 skill 适配

| skill | 改动 | 复杂度 |
|---|---|---|
| `auto-status` | 看到 `phase=archived` 归到"已归档"分组（默认折叠，与"已完成未归档"区分） | 小 |
| `auto-recover` | 看到 `phase=archived` 时**拒绝接续**，提示"已归档，需重跑请用 /auto-deploy 强制覆盖" | 小 |
| `auto-deploy` | workspace 已存在且 `phase=archived` 时，提示"上次已归档，重跑会重下 28GB 权重，确认?" | 小 |

---

## Settings.json 权限

cleanup-agent 需要 `Bash(rm -rf workspace/*)`（已在 allow 里），但要**加 deny 规则**防越权：

```diff
"deny": [
    ...
+   "Bash(rm -rf /*)",
+   "Bash(rm -rf ~/*)",
+   "Bash(rm -rf /root/*)",
+   "Bash(rm -rf workspace)",        // 防整个 workspace 父目录被删
+   "Bash(rm -rf workspace/)",
+   "Bash(rm -rf workspace/*)",      // 必须指定 slug 才允许
]
```

R1 hook 已会拦"跨 workspace"操作，但 deny 是 hard stop，做双层防御。

---

## 测试策略（3 层）

| 层 | 测什么 | 工具 |
|---|---|---|
| **L1 单元** | runbook 模板填空逻辑（给定固定 results/ → 期望 markdown）；cleanup 白名单规则（dry_run=true → 期望 log） | pytest + 固定 fixtures `tests/fixtures/<slug>/` |
| **L2 SubAgent 模拟** | 用历史 ndjson（SongGen run3 的 trace）跑 runbook-agent，看产出符合契约；cleanup-agent dry_run 跑 `song-generation-run2` workspace，看清单对 | bash + 抓 SubAgent return |
| **L3 e2e** | 用一个小项目（< 5GB 权重）跑完整流水线，验 runbook + cleanup 都跑，`reports/runbooks/` 有文件，workspace 只剩 state/results/logs/output | 手动 trigger + 看磁盘前后对比 |

L1 必做，L2 强烈推荐（song-generation-run2 workspace 现成可用），L3 可选。

---

## YAGNI 自审（不加什么）

| 候选 feature | 加吗 | 理由 |
|---|---|---|
| Archive 到 tar.gz 而非直接 rm | ❌ | 用户没要 archive，直接 rm 简单 |
| cleanup 后发邮件通知 | ❌ | MVP 不依赖外部服务 |
| runbook 多语言支持 | ❌ | 中文够用 |
| runbook 自动 PR 到 GitHub | ❌ | 远超范围 |
| `force_cleanup_incomplete` flag | ⚠️ 留参数 | G4 提到，但主 agent 不主动用 |
| `dry_run` 参数 | ✅ 加 | 上面已确认 |

---

## Rollout 顺序（防止"上了就不能下"）

```
Step 1: 写 spec + plan（本轮）✅
Step 2: 实现 runbook-agent + L1 单测 — 先 dry_run 在 song-generation-run2 trace 上验证产出
Step 3: 实现 cleanup-agent + dry_run 单测 — 在 song-generation-run2 workspace dry-run，看清单对
Step 4: 主 agent 串联（改 auto-deploy / auto-daily / write-recommendation）— cleanup 默认 dry_run=true
Step 5: 用一个小项目跑完整 e2e，验证 runbook 写得对、清单对
Step 6: 验证 OK 后切 cleanup-agent dry_run=false，正式 production
Step 7: 周边 skill 适配（auto-status / auto-recover / auto-deploy 加 archived 分支）
Step 8: 改 settings.json 加 deny 规则
```

每 step 完成后 commit，出问题 git revert 即可回滚。

---

## 与 5/19 原 spec 的关系

| 原 spec 概念 | 本 addendum 扩展 |
|---|---|
| 5 阶段流水线 | 不变；在末尾追加 2 个 SubAgent dispatch |
| state.json schema | 加 `phase=archived` 终态 + 3 个新字段；向后兼容 |
| SubAgent 隔离 | 复用同样模式（runbook-agent / cleanup-agent 各自独立 200K context） |
| R1-R9 硬规则 | 不动；R1 workspace 隔离对 cleanup-agent 是 hard stop |
| 主 agent 仅做 4 件事 | 不变；新增的 2 个 Task() dispatch 也是这 4 件事之一（"Task() dispatch SubAgent"） |
| memory/lessons | 不直接关联；runbook 是项目级产物（reports/runbooks/），lessons 是跨项目（memory/lessons/） |

**原 spec 不动**。本 addendum 是显式 reference + 增量补丁。

---

## 验收标准

- [ ] runbook-agent 在 song-generation-run2 trace 上 dry-run 产出 `reports/runbooks/song-generation-2026-05-25.md`，含 7 节完整结构
- [ ] cleanup-agent 在 song-generation-run2 workspace dry-run 输出 "would rm venv (9.2GB), .cache (6.1GB), repo (180MB)，保留 state.json/results/logs/output"
- [ ] 主 agent 在新一次 SongGen 跑完后自动 dispatch runbook + cleanup，state.json 终态 `phase=archived`
- [ ] auto-status 显示 archived 项目分组到"已归档（折叠）"
- [ ] auto-recover 看到 archived 时拒绝接续并提示
- [ ] settings.json deny 规则生效（手动 `rm -rf workspace` 被拦）
- [ ] 单项目 workspace 从 ~30GB 降到 ~50MB

---

## 参考

- 原 spec：[`2026-05-19-ai-auto-harness-design.md`](./2026-05-19-ai-auto-harness-design.md)
- Phase plan：[`../plans/2026-05-25-phase-5-runbook-and-cleanup.md`](../plans/2026-05-25-phase-5-runbook-and-cleanup.md)
- SongGen e2e 真实数据：`workspace/song-generation-run2/` + `runs/songgen-e2e-run3-resume-20260522-094040/`
- 设计 brainstorming 来源：会话 `/root/.claude/projects/-root/5b7edd4d-feed-4d2c-8df4-4762c4833862.jsonl` 中的 5 节设计
