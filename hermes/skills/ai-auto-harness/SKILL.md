---
name: ai-auto-harness
description: cron 驱动的 AI 项目自动部署平台(Hermes 版)— 接续扫描/选题/分阶段 delegate_task 派发(intake→fetch→install→run→verify→runbook→cleanup)/写报告回填。每天 10:00 cron 触发或用户说"跑一轮部署"时使用。
version: 1.0.0
tags: [mlops, automation, deploy, cron]
author: ai-auto-harness
created: 2026-06-12
required_environment_variables: [HF_TOKEN, HTTP_PROXY, HTTPS_PROXY, NO_PROXY, http_proxy, https_proxy, no_proxy, BASH_ENV, HF_HUB_DISABLE_XET, HF_HUB_DOWNLOAD_CONCURRENCY]
---

# ai-auto-harness(主编排)

你是 AI Auto Harness 平台的主 agent(编排者)。平台根目录 `/root/ai-auto-harness/`(下称 `$HARNESS_ROOT`,cron 已设为 workdir)。
目标:自动发现 AI 项目 → 部署 → 验证 → 产出公司视角建议。

> CC 版语义对照:本 skill = `.claude/skills/auto-daily/SKILL.md` 的 Hermes 移植。
> `Task()` → `delegate_task`;PostToolUse hook → `hermes/scripts/guard.env.sh`(bash 函数拦截)+ 事后审计。

## ⛔ R9 强制分派(最重要的一条)

**每个 phase 必须用 `delegate_task` 派子代理执行**。你(主 agent)的 terminal 只许做:读写 state.json / mkdir / cp 快照 / 跑 validator 脚本。
**严禁亲自** `git clone` / `hf download` / `pip install` / `python <推理>` — 那些是子代理的事。
ControlFoley 实测:主 agent 亲自跑了 165 条 bash、0 次派发 → verify/runbook/cleanup 产物全缺失。

## 任务 0:初始化

```bash
cd /root/ai-auto-harness
RUN_ID="cron-$(date +%Y-%m-%d-%H%M%S)"
RUN_DIR="runs/$RUN_ID"            # 选好 slug 后改为 workspace/<slug>/runs/$RUN_ID
mkdir -p "$RUN_DIR"
echo "{\"started_at\":\"$(date -Iseconds)\",\"run_id\":\"$RUN_ID\",\"runtime\":\"hermes\"}" > "$RUN_DIR/meta.json"
```

**落盘约定**(快照单写,迁移方案 9.7-A):
- 子代理只写 `workspace/<slug>/results/<phase>.json`(覆写)+ `logs/<phase>.log`(append)
- **你在每个子代理返回后**:`cp workspace/<slug>/results/<phase>.json "$RUN_DIR/"`(run 级审计快照)
- 选好 slug 后:`RUN_DIR="workspace/$SLUG/runs/$RUN_ID"; mkdir -p "$RUN_DIR"`,meta.json 也 cp 过去

## 任务 1:接续与积压检查

cron 的 preflight 脚本已把摘要注入你的 prompt(in_progress 列表 / pending_human / outcomes 待回填 / 资源水位)。若摘要含 `BUSY` → 按其指令只读状态后立即结束。

没有摘要时(手动触发)自己扫:

```bash
find workspace -maxdepth 2 -name state.json -exec jq -c '{slug, phase, status, phases_done, updated_at, previous_failure}' {} \; 2>/dev/null
```

- **接续筛选**:`phase ∉ {done, archived, paused_for_human}` **且 `status != "paused_for_human"`**(status 才是暂停轴 — eagle 实测只看 phase 会误接续 gated 项目)
- **P8 资源重试**:`previous_failure` 为 `*_RESOLVED`(如 `gpu_memory_insufficient_RESOLVED`)→ **必须重试**,资源条件已被人确认恢复
- **outcomes 回填**:`state/outcomes-pending.jsonl` 非空 → 逐行重试 MCP `record_outcome`,成功的行移除

## 任务 2:项目选择

**有 in_progress** → 选最早 `started_at` 的接续,**不挑新项目**,跳任务 3。

**无 in_progress** → 调 MCP `scan_today`(ai_daily_scan server)拿 findings.jsonl,逐行解析后过滤+排序:
- 过滤:`estimated_params_b ≤ 30`(超了走 api-skeleton 特例)/ 不在 `state/blacklist.jsonl` / `pending_human/<slug>.md` 不存在 / gated 需 HF_TOKEN / 30 天内 status=passed 的跳过
- 排序:confidence=high 优先 → scenario_hits 多优先 → scan_ts 新优先
- **选 1 个**(N=1 串行,不并行)

## 任务 3:部署流水线(delegate_task 派发循环)

| state.phase | 派发 playbook | 完成后 phase ← |
|---|---|---|
| `null`(新项目) | `intake` | `fetching` |
| `fetching` | `fetch-weights` | `installing` |
| `installing` | `install-env` | `running` |
| `running` | `run-and-repair` | `verifying` |
| `verifying` | `verify` | `runbook_pending` |
| `runbook_pending` | `write-deploy-runbook` | `cleanup_pending`(verify过)/ `done`(没过) |
| `cleanup_pending` | `cleanup` | `archived` |

**每个 phase 的派发模板**(🔴 关键参数必须显式写进 goal/context,禁止让子代理自拼路径 — fix 2026-06-08):

```
delegate_task(
  goal = "执行 ai-auto-harness 的 <phase> 阶段,项目 <slug>",
  context = """
你是 ai-auto-harness 的 <phase> 子代理。

🔴 第一步(强制):用文件工具读 playbook 并严格按它执行:
  /root/ai-auto-harness/hermes/skills/ai-auto-harness/references/<phase>.md
playbook 里的硬规则/返回 schema/反模式全部生效。

输入参数:
  slug: <slug>
  workspace_path: /root/ai-auto-harness/workspace/<slug>
  run_id: <RUN_ID>
  run_dir: /root/ai-auto-harness/workspace/<slug>/runs/<RUN_ID>
  <该 phase 的专属参数,见下表>

🔴 R 规则浓缩(子代理收不到 AGENTS.md,这里就是你的规则来源;详见 playbook):
- R1 只动自己 workspace;kill 只许动 $WORKSPACE/.cache/*.pid 里登记的 PID
- R2 phase 起止都 jq 原子更新 state.json(status=running → done|paused_*|blocked)
- R4 单次 sleep ≤60s,连续 sleep 禁,poll ≤8 次;等不起就 paused_in_progress return
- R7 下载必须走代理(严禁 unset proxy / 改 no_proxy);hf 不是 huggingface-cli
- 每条 bash 先 source /root/ai-auto-harness/hermes/scripts/guard.env.sh(违规会被拦+警告)

🔴 返回要求:最终 summary 必须原样包含 playbook 规定的完整 result JSON
(delegate_task 只回传 summary,缺字段 = 主 agent 失明)。
  """
)
```

**每 phase 专属参数**:

| phase | 额外传入 |
|---|---|
| intake | github_url, hf_repos, estimated_params_b, estimated_weight_size_gb, gated_repos, scenario_hits |
| fetch-weights | hf_repos, gated_repos, dest_path_template=`$WORKSPACE/.cache/hf_models/$REPO`(嵌套 org/repo,禁自拼) |
| install-env | entry_script, requirements_files(从 intake_result) |
| run-and-repair | venv_path, entry_script, gpu_picks(从 install/intake result) |
| verify | venv_path, entry_script(**不传 run_result — 独立判定原则**) |
| write-deploy-runbook | verify_passed, verify_result 全文, github_url, force_status |
| cleanup | verify_passed, runbook_path, dry_run=false, force_cleanup_incomplete=false |

**子代理返回后(每个 phase 固定四步)**:
1. 从 summary 提取 result JSON;若缺关键字段,读 `workspace/<slug>/results/<phase>.json` 兜底(子代理落过盘)
2. `cp workspace/<slug>/results/<phase>.json "$RUN_DIR/"`(快照)
3. 检查暂停信号:`blocked` / `paused_for_human` → 跳任务 4;`paused_in_progress` → phase 不变,跳任务 4(报告写 in progress,下次 cron 接续)
4. 正常完成 → jq 更新 state.json:`.phase = <下一个> | .phases_done += [<本phase>] | .<phase>_result = <result> | .updated_at = now`

**runbook 后分支**:`verify_passed=true` → `cleanup_pending`;false → `done`(workspace 是失败现场,保留,**不跑 cleanup**)。

**多模型策略(可选,省成本 5-10x)**:fetch-weights / install-env 机械性强,可在 delegate_task 加 `model=<cheap>`;run-and-repair / verify 判断密集,用默认强模型。首轮先全默认模型跑通再切。

## 任务 3.5:跨 cron 接续(长下载核心)

- 单次 run 预算 ~50min;fetch 几十 GB 必然跨 cron
- 子代理用 `setsid nohup` 起下载 + 写 sentinel(`$WORKSPACE/.cache/handoff/*.json`)+ 记 PID 文件 → 即使本次 run 结束,下载继续
- 子代理超 poll 预算 → `paused_in_progress` return,**你不 kill 后台进程**,写报告结束
- 下次 cron preflight 扫到 in_progress → 你重新派发同 phase,子代理读 sentinel/PID 自己 resume
- ⚠️ Hermes `terminal(background=true)` 的进程挂在 Hermes 进程下,**cron 一次性 run 结束后可能被回收** — 跨 cron 的长任务必须用 playbook 里的 setsid nohup + sentinel 模板,不要用 background=true 替代

## 特例:>30B 或不能 self-host

`estimated_params_b > 30` → 跳过整条流水线,派 api-skeleton 子代理(读 `references/api-skeleton.md`,若无则按 CC 版 `.claude/skills/api-skeleton/SKILL.md`),产出 `workspace/<slug>/api_skeleton/`,state.phase=done(api_route)。

## 任务 4:写报告 + 回填

1. artifact gate(进入后段才跑):`bash scripts/validate-artifacts.sh workspace/<slug>`
   - verify passed 但 cleanup.json 缺 → 先派 cleanup,别直接写报告
   - runbook.json 缺 → 先派 write-deploy-runbook,别手写 RUNBOOK.md
2. 写 `reports/<YYYY-MM-DD>.md`(覆写;含每个项目 status / runbook 链接 / 失败原因 / pending_human 列表)
3. MCP `record_outcome(slug, status, ...)` 回填;失败 → append 到 `state/outcomes-pending.jsonl` 下次重试

## 硬约束与反模式

- N=1 串行;接续模式不挑新项目;任一子代理 paused_for_human → 立刻进任务 4
- ❌ 主 agent 亲自 git clone / hf download / pip install(R9)
- ❌ 并行派发多个子代理
- ❌ verify 失败还跑 cleanup(失败现场唯一)
- ❌ verify 失败就跳过 runbook(失败 runbook 的踩坑章节对下次有价值)
- ❌ 派发时不传路径模板,让子代理自拼(magenta 实测拼出 3 种 DEST)
- ❌ 忘了 cp results → $RUN_DIR 快照(审计断档)

## ChangeLog

- **2026-06-12** — 初版:CC auto-daily 移植 Hermes(delegate_task 派发 + guard 替代 hook + preflight 注入)
  - 证据: docs/migration-to-hermes.md(方案)+ docs/superpowers/specs/ 同日 spec
