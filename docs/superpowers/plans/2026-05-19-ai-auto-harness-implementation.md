# AI Auto Harness 实施 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **执行入口更新:** 这份文件现在作为完整参考 runbook 保留,不要一口气执行。实际执行请从 [2026-05-19-ai-auto-harness-master.md](2026-05-19-ai-auto-harness-master.md) 进入,按 Phase -1 到 Phase 4 的分阶段 plan 逐个开发和测试。

**Goal:** 实施 ai-auto-harness 平台 — 基于 Claude Code 源码 + 自定义 skill,把 AI 项目信号发现 → 自动 GitHub clone → HF 权重拉取 → 装环境 → 跑 → 验证 → 公司视角建议这一长链路做成 cron-driven、可观测、可接续的 daemon

**Architecture:** ai-daily-scan(Python)通过 MCP 接入 → Claude Code 主 agent(`/auto-daily`)→ 7 阶段 SubAgent 流水线(intake / fetch-weights / install-env / run-and-repair / verify / runbook / cleanup)→ 生成报告 + MCP 回填 outcomes。Runtime data 落盘 `workspace/` + `runs/` + `memory/` + `pending_human/`,跨 cron 周期靠 `state.json` 接续

**Tech Stack:** TypeScript/Bun (CC harness, 不动 src/), Python (ai-daily-scan + MCP server), bash (hooks / cron / 实验), MCP protocol via stdio, Claude Code agent loop (`async function* while(true)`)

**Spec:** [2026-05-19-ai-auto-harness-design.md](../specs/2026-05-19-ai-auto-harness-design.md)

**预期总工时**:Phase -1 半天 / Phase 0 一天 / Phase 1 一天 / Phase 2 两天 / Phase 3 一天 / Phase 4 半天 = **约 6 个工作日**

---


---

## 人话版

**一句话**：项目最原始的完整实施计划——从零到一的每一步怎么干，现在只当参考看，实际执行走 Master Plan 的分阶段 plan。

**打比方**：像造楼的总施工图，一整张大纸画完所有工序。后来发现太大了拆成 7 张小图（Phase -1 到 Phase 5），这张总图留着当参考。

**注意**：不要一口气执行这个文件，按 Master Plan 里列的分阶段 plan 逐个跑。

## 文件清单(整体)

### ai-daily-scan(已有 repo,改动)
| 文件 | 操作 |
|---|---|
| `pyproject.toml` | modify — add `mcp` 依赖 |
| `src/schemas.py` | modify — AnalystReport 加 4 字段 |
| `src/tools.py` | modify — analyst deep prompt 加 4 字段输出要求 |
| `src/findings_writer.py` | **create** |
| `src/outcomes_reader.py` | **create** |
| `src/run_daily.py` | modify — 末尾调 findings_writer.write |
| `mcp_server.py` | **create**(repo 根目录) |
| `tests/test_findings_writer.py` | **create** |
| `tests/test_outcomes_reader.py` | **create** |
| `tests/test_mcp_server.py` | **create** |

### ai-auto-harness(新 repo)
| 文件 | 操作 |
|---|---|
| `.gitignore` | append CC base 自带的 |
| `.claude/CLAUDE.md` | **create** — 项目根上下文 |
| `.claude/settings.json` | **create** — 权限 + MCP + hooks |
| `.claude/skills/ai-auto/daily-auto.md` | **create** |
| `.claude/skills/ai-auto/intake.md` | **create** |
| `.claude/skills/ai-auto/fetch-weights.md` | **create** |
| `.claude/skills/ai-auto/install-env.md` | **create** |
| `.claude/skills/ai-auto/run-and-repair.md` | **create** |
| `.claude/skills/ai-auto/verify.md` | **create** |
| `.claude/skills/ai-auto/api-skeleton.md` | **create** |
| `.claude/skills/ai-auto/request-human-intervention.md` | **create** |
| `.claude/skills/ai-auto/preflight-gpu-disk.md` | **create** |
| `.claude/skills/ai-auto/write-recommendation.md` | **create** |
| `.claude/skills/ai-auto/verifier-corrector.md` | **create**(Phase 4) |
| `.claude/skills/ai-auto/coverage-gaps.md` | **create**(Phase 4) |
| `.claude/skills/ai-auto/cost-analysis.md` | **create**(Phase 4) |
| `.claude/commands/auto-daily.md` | **create** |
| `.claude/commands/auto-deploy.md` | **create** |
| `.claude/commands/auto-status.md` | **create** |
| `.claude/commands/auto-recover.md` | **create** |
| `.claude/agents/intake-agent.md` | **create** |
| `.claude/agents/fetch-agent.md` | **create** |
| `.claude/agents/install-agent.md` | **create** |
| `.claude/agents/runner-agent.md` | **create** |
| `.claude/agents/verify-agent.md` | **create** |
| `.claude/hooks/session-start.sh` | **create** |
| `.claude/hooks/post-tool-use.sh` | **create** |
| `.claude/hooks/session-end.sh` | **create** |
| `cron/daily.sh` | **create** |
| `cron/crontab.example` | **create** |
| `memory/lessons/torch-sm12.md` | **create** — seed |
| `memory/lessons/hf-gated.md` | **create** — seed |
| `memory/lessons/flash-attn-build.md` | **create** — seed |
| `experiments/R2-bg-shell-persistence.sh` | **create** |
| `experiments/R3-long-running-session.sh` | **create** |
| `experiments/README.md` | **create** |
| `README.md` | overwrite CC base 的(Phase 4) |

### auto-deploy-agent(已有 repo,冻结)
| 文件 | 操作 |
|---|---|
| `README.md` | modify — 加 deprecated 提示 |

---

## Phase -1: Preflight Blockers + 风险验证

**Milestone**:磁盘 > 500GB free,R2/R3 风险点有实验结论可参考

---

### Task -1.1: 磁盘清理(R4 blocker)

**Files:**
- 读取(检查):`/root/core.*`、`/root/auto-deploy-agent/workspace/`

- [ ] **Step 1: 列出大文件占用**

```bash
df -h /root
echo "---"
ls -lah /root/core.* 2>/dev/null | sort -k5 -hr | head -20
echo "---"
du -sh /root/auto-deploy-agent/workspace/* 2>/dev/null | sort -hr | head -20
echo "---"
du -sh /tmp/* 2>/dev/null | sort -hr | head -10
```

Expected:`/root/core.*` 大概有 9 个文件,总 ~180GB;auto-deploy-agent/workspace 可能数十 GB

- [ ] **Step 2: 删 core dumps(用户确认后执行)**

```bash
rm -f /root/core.12005 /root/core.12748 /root/core.12861 /root/core.12978 \
      /root/core.13094 /root/core.13210 /root/core.13349 /root/core.18666 \
      /root/core.95332 /root/core.109920
df -h /root
```

Expected:free 应该增加 ~180GB(应该到 ~640GB free)

- [ ] **Step 3: 清理 auto-deploy-agent 老 workspace(若有)**

```bash
# 只清 7 天以上未访问的
find /root/auto-deploy-agent/workspace -maxdepth 1 -type d -mtime +7 -exec du -sh {} \;
# 用户确认后:
# find /root/auto-deploy-agent/workspace -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;
```

- [ ] **Step 4: 最终验证**

```bash
df -h /root
```

Expected:Avail > 500GB(到 Phase 1 启动 ai-auto-harness 时安全)

- [ ] **Step 5: 不需要 commit(纯运维操作)**

---

### Task -1.2: R2 实验 — bg_shell 跨进程持久性

**Files:**
- Create:`/root/ai-auto-harness/experiments/R2-bg-shell-persistence.sh`
- Create:`/root/ai-auto-harness/experiments/R2-findings.md`

**目的**:验证 `Bash(run_in_background=true)` 启动的 bash + `nohup` 是否能在 CC 主进程退出后继续运行(spec § 15 R2)

- [ ] **Step 1: 写实验脚本**

```bash
mkdir -p /root/ai-auto-harness/experiments
cat > /root/ai-auto-harness/experiments/R2-bg-shell-persistence.sh <<'EOF'
#!/bin/bash
# R2 实验:启动一个长 bash,用 nohup 包裹,落 PID 到文件
# 然后用户手动 kill 父 claude-haha 进程
# 30 秒后回来查 PID 是否还活着

set -e
EXPDIR="/tmp/r2-experiment"
mkdir -p $EXPDIR
rm -f $EXPDIR/{pid,output.log,done}

# 启动一个 5 分钟 sleep 任务,nohup + setsid 双重保险
setsid nohup bash -c '
  echo "BG PID=$$ start at $(date)" >> /tmp/r2-experiment/output.log
  for i in 1 2 3 4 5; do
    sleep 60
    echo "alive iter=$i at $(date)" >> /tmp/r2-experiment/output.log
  done
  echo "done at $(date)" >> /tmp/r2-experiment/output.log
  touch /tmp/r2-experiment/done
' </dev/null >>$EXPDIR/output.log 2>&1 &

BG_PID=$!
echo $BG_PID > $EXPDIR/pid
echo "started bg pid=$BG_PID, expected to live 5 minutes"
echo "now: kill the parent claude-haha process and run check-r2.sh after 60s"
EOF
chmod +x /root/ai-auto-harness/experiments/R2-bg-shell-persistence.sh
```

- [ ] **Step 2: 写 check 脚本**

```bash
cat > /root/ai-auto-harness/experiments/R2-check.sh <<'EOF'
#!/bin/bash
PID=$(cat /tmp/r2-experiment/pid)
if kill -0 $PID 2>/dev/null; then
  echo "PID $PID alive ✅"
  echo "--- tail output.log ---"
  tail /tmp/r2-experiment/output.log
else
  echo "PID $PID DEAD ❌"
  tail /tmp/r2-experiment/output.log
fi
EOF
chmod +x /root/ai-auto-harness/experiments/R2-check.sh
```

- [ ] **Step 3: 跑实验(在 CC 会话里启动 bg,然后 user 手动测)**

```bash
# 在 claude-haha 会话里:
bash /root/ai-auto-harness/experiments/R2-bg-shell-persistence.sh
# 退出 CC(Ctrl+D 或 /exit)
# 等 90s
# 再开 CC 跑:
bash /root/ai-auto-harness/experiments/R2-check.sh
```

- [ ] **Step 4: 记录结论**

```bash
cat > /root/ai-auto-harness/experiments/R2-findings.md <<'EOF'
# R2 实验结论:bg_shell 跨 CC 进程持久性

**实验日期**:<填日期>

## 设置
- `setsid nohup bash -c "..." &`
- 输入流重定向 `</dev/null`,输出重定向 `>>output.log`

## 结论
- [ ] 持久(✅):CC 主进程退出后 bash 继续跑,output.log 持续追加
- [ ] 不持久(❌):CC 退出后 bash 也死

## 影响
- 若持久 → fetch-weights skill 跨 cron 接续可行,state.json 写 PID 就够
- 若不持久 → 需要换方案:
  - 选项 A:用 systemd-run --user 包裹长任务
  - 选项 B:启 systemd 服务 ai-auto-bgtask.service 接管长任务
  - 选项 C:把 fetch-weights 切成"每次 cron 拉一小段"(分钟级 chunk)

## 决定
<填决定>
EOF
```

- [ ] **Step 5: Commit**(此时 git 还没 init,先放着,Phase 1 第一次 commit 时一起加)

```bash
echo "R2 实验文件准备完,先不 commit(Phase 1 git init 后一起加)"
```

---

### Task -1.3: R3 实验 — claude-haha --print long-running session

**Files:**
- Create:`/root/ai-auto-harness/experiments/R3-long-running-session.sh`
- Create:`/root/ai-auto-harness/experiments/R3-findings.md`

**目的**:验证 `claude-haha --print "<prompt>"` 模式能否承载几十分钟的会话(spec § 15 R3)

- [ ] **Step 1: 写实验脚本**

```bash
cat > /root/ai-auto-harness/experiments/R3-long-running-session.sh <<'EOF'
#!/bin/bash
# R3 实验:--print 模式跑一个让 agent sleep 多个 5min 段的 task,
# 看会话是否中断、是否能正常完成 + 返回

cd /root/claudecode_sourcecode1
START=$(date +%s)
echo "start: $(date)" > /tmp/r3-experiment.log

./bin/claude-haha --print "
你是一个测试 agent。请按顺序做这 6 件事:
1. echo \"phase 1 start at \$(date)\"
2. sleep 300 (5 分钟)
3. echo \"phase 2 alive at \$(date)\"
4. sleep 300
5. echo \"phase 3 alive at \$(date)\"
6. echo done

每一步用 Bash 工具。把每步输出收集到最后用一句话总结。
" 2>&1 | tee -a /tmp/r3-experiment.log

END=$(date +%s)
ELAPSED=$((END - START))
echo "" >> /tmp/r3-experiment.log
echo "elapsed: $ELAPSED seconds" >> /tmp/r3-experiment.log
echo "done: $(date)" >> /tmp/r3-experiment.log
EOF
chmod +x /root/ai-auto-harness/experiments/R3-long-running-session.sh
```

- [ ] **Step 2: 跑实验(后台跑约 17 分钟)**

```bash
nohup bash /root/ai-auto-harness/experiments/R3-long-running-session.sh </dev/null >/dev/null 2>&1 &
echo "started, will take ~17 minutes. tail /tmp/r3-experiment.log to monitor"
```

- [ ] **Step 3: 等 20 分钟后查看结果**

```bash
tail -50 /tmp/r3-experiment.log
echo "---"
# 检查:elapsed 是否 ~1000s + 6 个 phase 都打了
grep -c "phase " /tmp/r3-experiment.log  # 期望 ≥ 6
grep "elapsed:" /tmp/r3-experiment.log
```

- [ ] **Step 4: 记录结论**

```bash
cat > /root/ai-auto-harness/experiments/R3-findings.md <<'EOF'
# R3 实验结论:claude-haha --print long-running

**实验日期**:<填日期>

## 设置
- claude-haha --print "..." 让 agent 跑 ~17 分钟(3 个 5min sleep + Bash)
- 重定向 stdin/stdout 后台跑

## 结论
- [ ] 完整通过(✅):所有 phase 都跑完,exit code 0
- [ ] 中途中断(❌):某 phase 后 session 死,elapsed < 期望

## 影响
- 若 ✅ → 主 agent skill 可以跑几十分钟 deploy 流水线
- 若 ❌ → 需要换方案:
  - 选项 A:把 daily-auto 拆成多个独立 --print 调用,各调用之间靠 state.json 传 context
  - 选项 B:用 Anthropic Python SDK 自己实现 agent loop(放弃 CC 的 Ink TUI)

## 决定
<填决定>
EOF
```

- [ ] **Step 5: 不需要 commit**(同 Task -1.2,Phase 1 时一起 add)

---

## Phase -1 Milestone 验收

- [ ] `df -h /root` 显示 Avail > 500GB
- [ ] `cat /root/ai-auto-harness/experiments/R2-findings.md` 结论已填
- [ ] `cat /root/ai-auto-harness/experiments/R3-findings.md` 结论已填
- [ ] 若 R2 或 R3 结论是 ❌,**暂停 Phase 0+,先按 findings.md 里"决定"段调整 spec**

---

## Phase 0: ai-daily-scan MCP 接入

**Milestone**:scan@9:00 跑完产 `state/findings.jsonl`(含 4 个新字段);MCP server 4 个工具均可被 CC 端 stdio 调用并 round-trip

---

### Task 0.1: Branch + 依赖

**Files:**
- Modify:`/root/ai-daily-scan/pyproject.toml`

- [ ] **Step 1: 开 feature 分支**

```bash
cd /root/ai-daily-scan
git status                          # 确认干净
git checkout -b feature/mcp-integration
```

- [ ] **Step 2: 加 mcp 依赖**

读 `/root/ai-daily-scan/pyproject.toml` 看 dependencies block 位置,加一行:

```toml
# 在 [project] dependencies 数组里
"mcp>=0.9.0",
```

- [ ] **Step 3: 装依赖**

```bash
cd /root/ai-daily-scan
pip install -e ".[dev]" 2>&1 | tail -10
# 或 pip install mcp anthropic httpx selectolax python-dotenv pytest
```

Expected:`mcp` 包成功安装

- [ ] **Step 4: 验证 import**

```bash
cd /root/ai-daily-scan
python -c "from mcp.server.fastmcp import FastMCP; print('ok')"
```

Expected:输出 `ok`

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml
git commit -m "feat: add mcp dependency for ai-auto-harness integration"
```

---

### Task 0.2: AnalystReport Schema 扩展(4 个新字段)

**Files:**
- Modify:`/root/ai-daily-scan/src/schemas.py`
- Create:`/root/ai-daily-scan/tests/test_schemas_extended.py`

- [ ] **Step 1: 写失败测试**

```bash
mkdir -p /root/ai-daily-scan/tests
cat > /root/ai-daily-scan/tests/test_schemas_extended.py <<'EOF'
"""测试 AnalystReport 扩展的 4 个字段"""
from src.schemas import ANALYST_SCHEMA


def test_analyst_schema_has_next_action():
    props = ANALYST_SCHEMA["properties"]
    assert "next_action" in props
    assert props["next_action"]["type"] == "string"
    assert set(props["next_action"]["enum"]) == {
        "try_deploy_self_host",
        "try_api_pilot",
        "monitor_only",
        "skip",
    }


def test_analyst_schema_has_gated_repos():
    props = ANALYST_SCHEMA["properties"]
    assert "gated_repos" in props
    assert props["gated_repos"]["type"] == "array"
    assert props["gated_repos"]["items"]["type"] == "string"


def test_analyst_schema_has_estimated_weight_size_gb():
    props = ANALYST_SCHEMA["properties"]
    assert "estimated_weight_size_gb" in props
    assert props["estimated_weight_size_gb"]["type"] == "integer"


def test_analyst_schema_has_estimated_params_b():
    props = ANALYST_SCHEMA["properties"]
    assert "estimated_params_b" in props
    assert props["estimated_params_b"]["type"] == "integer"
EOF
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
cd /root/ai-daily-scan
pytest tests/test_schemas_extended.py -v 2>&1 | tail -20
```

Expected:4 个测试都 FAIL(字段还不存在)

- [ ] **Step 3: 实现 — 在 `ANALYST_SCHEMA` 加 4 字段**

读 `/root/ai-daily-scan/src/schemas.py`,找到 `ANALYST_SCHEMA` 定义(常量名可能略不同,例如 `_analyst_schema()` 函数返回),在 `"properties"` dict 里追加:

```python
"next_action": {
    "type": "string",
    "enum": ["try_deploy_self_host", "try_api_pilot", "monitor_only", "skip"],
    "description": "下游 ai-auto-harness 主 agent 直接读取的 signal",
},
"gated_repos": {
    "type": "array",
    "items": {"type": "string"},
    "description": "hf_repos 中需要 HF token + license 同意的 repo 子集",
    "default": [],
},
"estimated_weight_size_gb": {
    "type": "integer",
    "description": "所有 hf_repos 权重总大小估算(GB),给磁盘 preflight 用",
    "minimum": 0,
},
"estimated_params_b": {
    "type": "integer",
    "description": "模型激活参数量(B),用于 30B self-host 阈值过滤",
    "minimum": 0,
},
```

不修改 `"required"` 数组(这 4 字段可选,旧报告不会有)。

- [ ] **Step 4: 跑测试,确认通过**

```bash
cd /root/ai-daily-scan
pytest tests/test_schemas_extended.py -v 2>&1 | tail -10
```

Expected:4 PASSED

- [ ] **Step 5: Commit**

```bash
git add src/schemas.py tests/test_schemas_extended.py
git commit -m "feat(schemas): extend AnalystReport with next_action/gated_repos/size/params fields"
```

---

### Task 0.3: Analyst Deep Prompt 更新

**Files:**
- Modify:`/root/ai-daily-scan/src/tools.py`

- [ ] **Step 1: 阅读现有 deep prompt**

读 `/root/ai-daily-scan/src/tools.py`,定位 `analyze_project` 的 deep prompt 字符串(可能在 `_DEEP_PROMPT` 常量 OR 内嵌 `analyze_project()` function body)。

- [ ] **Step 2: 在 prompt 末尾加 4 个字段填写要求**

在 deep prompt 的"输出字段说明"区追加(注意保持现有 prompt 的中文风格):

```
此外必须填写以下 4 个机器读取字段(供下游 ai-auto-harness 平台使用):

**next_action**(枚举,必填):基于本项目的关联度/成本/资源/可行性综合判断,选一项:
- "try_deploy_self_host":值得 5090 自部署验证(参数 ≤ 30B 且非 gated 或有 HF token)
- "try_api_pilot":只走 API 路线评估(参数 > 30B 或 self-host ROI 不划算)
- "monitor_only":暂时只观察,本次不触发 deploy(信号弱 OR 已重复推荐过)
- "skip":明确不要 deploy(无效信号 OR 信息不完整)

**gated_repos**(数组,可空):列出 hf_repos 中需要在 huggingface.co 同意 license + HF token 才能下载的 repo,精确到 "org/name" 格式。例:["black-forest-labs/FLUX.1-schnell"]。若不确定,留空数组 — 下游会现场探测。

**estimated_weight_size_gb**(整数,GB):所有 hf_repos 加起来的权重磁盘占用估算。例:Flux schnell ~23GB + T5-XXL ~13GB = 36。无法估算填 0。

**estimated_params_b**(整数,B):模型激活参数量(MoE 模型用 active params,不是 total)。例:V4-Flash 13B,SongGeneration v2-large 4B。无法估算填 0。
```

- [ ] **Step 3: 手动跑一次 analyze_project,验证新字段在输出**

```bash
cd /root/ai-daily-scan
# 测试用一个已知项目
python -c "
from src.tools import analyze_project
report = analyze_project('https://github.com/tencent-ailab/SongGeneration')
import json
print(json.dumps(report, indent=2, ensure_ascii=False)[:2000])
print('---new fields---')
for k in ['next_action', 'gated_repos', 'estimated_weight_size_gb', 'estimated_params_b']:
    print(f'  {k}: {report.get(k)!r}')
"
```

Expected:新 4 字段都有值,`next_action` 是合法枚举

- [ ] **Step 4: Commit**

```bash
git add src/tools.py
git commit -m "feat(tools): analyst deep prompt now produces 4 fields for downstream auto-harness"
```

---

### Task 0.4: findings_writer.py + 测试

**Files:**
- Create:`/root/ai-daily-scan/src/findings_writer.py`
- Create:`/root/ai-daily-scan/tests/test_findings_writer.py`

**职责**:把 `run_daily` 内存里的 analyst reports 列表序列化成 `state/findings.jsonl`(每行一个 Finding)

- [ ] **Step 1: 写失败测试**

```bash
cat > /root/ai-daily-scan/tests/test_findings_writer.py <<'EOF'
"""测试 findings_writer 序列化到 JSONL"""
import json
import tempfile
import pathlib
from src.findings_writer import write_findings, build_finding


def test_build_finding_minimal():
    """从 minimal analyst report 生成 Finding"""
    analyst_report = {
        "slug": "test-project",
        "title": "Test",
        "github_url": "https://github.com/x/y",
        "hf_repos": [],
        "scenario_hits": ["scenario_001"],
        "recommended_route": "self_host_5090",
        "next_action": "try_deploy_self_host",
        "estimated_params_b": 7,
        "estimated_weight_size_gb": 15,
        "gated_repos": [],
        "source_urls": ["https://x.com"],
        "confidence": "high",
    }
    f = build_finding(analyst_report, scan_ts="2026-05-19T09:00:00",
                       scan_report_path="reports/x.md")
    assert f["slug"] == "test-project"
    assert f["next_action"] == "try_deploy_self_host"
    assert f["estimated_params_b"] == 7
    assert f["scan_ts"] == "2026-05-19T09:00:00"


def test_write_findings_creates_jsonl():
    """write_findings 覆写产 JSONL,每行可独立 parse"""
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "findings.jsonl"
        findings = [
            {"slug": "a", "title": "A"},
            {"slug": "b", "title": "B"},
        ]
        write_findings(findings, out)
        lines = out.read_text().strip().split("\n")
        assert len(lines) == 2
        assert json.loads(lines[0])["slug"] == "a"
        assert json.loads(lines[1])["slug"] == "b"


def test_write_findings_overwrites():
    """重跑 scan 时覆写,不 append"""
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "findings.jsonl"
        write_findings([{"slug": "a"}], out)
        write_findings([{"slug": "b"}], out)
        lines = out.read_text().strip().split("\n")
        assert len(lines) == 1
        assert json.loads(lines[0])["slug"] == "b"
EOF
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
cd /root/ai-daily-scan
pytest tests/test_findings_writer.py -v 2>&1 | tail -10
```

Expected:ImportError(模块还没建)

- [ ] **Step 3: 实现 findings_writer.py**

```bash
cat > /root/ai-daily-scan/src/findings_writer.py <<'EOF'
"""findings_writer.py — 把 analyst reports 序列化成 state/findings.jsonl

ai-auto-harness 主 agent 通过 MCP scan_today() 读这个文件
"""
import json
import pathlib


_FINDING_KEYS = [
    "slug", "title", "github_url",
    "hf_repos", "estimated_params_b", "estimated_weight_size_gb", "gated_repos",
    "scenario_hits", "recommended_route", "next_action",
    "source_urls", "confidence",
    "scan_ts", "scan_report_path",
]


def build_finding(analyst_report: dict, *, scan_ts: str, scan_report_path: str) -> dict:
    """从 AnalystReport 抽出 ai-auto-harness 需要的字段"""
    f = {k: analyst_report.get(k) for k in _FINDING_KEYS if k != "scan_ts" and k != "scan_report_path"}
    f["scan_ts"] = scan_ts
    f["scan_report_path"] = scan_report_path
    # 设置默认值
    f.setdefault("hf_repos", [])
    f.setdefault("gated_repos", [])
    f.setdefault("estimated_params_b", 0)
    f.setdefault("estimated_weight_size_gb", 0)
    f.setdefault("scenario_hits", [])
    f.setdefault("source_urls", [])
    f.setdefault("confidence", "medium")
    f.setdefault("next_action", "monitor_only")
    return f


def write_findings(findings: list[dict], path: pathlib.Path) -> None:
    """覆写 JSONL — 每次 scan 覆盖整个文件,不 append"""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for f in findings:
            fh.write(json.dumps(f, ensure_ascii=False) + "\n")
EOF
```

- [ ] **Step 4: 跑测试,确认通过**

```bash
cd /root/ai-daily-scan
pytest tests/test_findings_writer.py -v 2>&1 | tail -10
```

Expected:3 PASSED

- [ ] **Step 5: Commit**

```bash
git add src/findings_writer.py tests/test_findings_writer.py
git commit -m "feat(findings_writer): serialize analyst reports to state/findings.jsonl"
```

---

### Task 0.5: outcomes_reader.py + 测试

**Files:**
- Create:`/root/ai-daily-scan/src/outcomes_reader.py`
- Create:`/root/ai-daily-scan/tests/test_outcomes_reader.py`

**职责**:读 `state/outcomes.jsonl`(ai-auto-harness CC 端 append-only 回填),让 scan 内部下次跑时知道哪些项目已 done/failed/paused

- [ ] **Step 1: 写失败测试**

```bash
cat > /root/ai-daily-scan/tests/test_outcomes_reader.py <<'EOF'
import json
import tempfile
import pathlib
from datetime import datetime, timedelta, timezone
from src.outcomes_reader import load_recent_outcomes, append_outcome


def test_append_outcome_creates_file():
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td) / "outcomes.jsonl"
        append_outcome(p, slug="x", status="passed", run_id="r1")
        assert p.exists()
        line = p.read_text().strip()
        rec = json.loads(line)
        assert rec["slug"] == "x"
        assert rec["status"] == "passed"
        assert "ts" in rec


def test_append_outcome_is_appendonly():
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td) / "outcomes.jsonl"
        append_outcome(p, slug="x", status="passed", run_id="r1")
        append_outcome(p, slug="y", status="failed", run_id="r2",
                       error_class="CUDA_OOM")
        lines = p.read_text().strip().split("\n")
        assert len(lines) == 2
        assert json.loads(lines[1])["error_class"] == "CUDA_OOM"


def test_load_recent_filters_by_days():
    """30 天前的 outcome 不返回"""
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td) / "outcomes.jsonl"
        old_ts = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()
        new_ts = datetime.now(timezone.utc).isoformat()
        p.write_text(
            json.dumps({"slug": "old", "status": "passed", "ts": old_ts}) + "\n" +
            json.dumps({"slug": "new", "status": "passed", "ts": new_ts}) + "\n"
        )
        recent = load_recent_outcomes(p, days=30)
        assert len(recent) == 1
        assert recent[0]["slug"] == "new"
EOF
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
cd /root/ai-daily-scan
pytest tests/test_outcomes_reader.py -v 2>&1 | tail -10
```

Expected:ImportError

- [ ] **Step 3: 实现**

```bash
cat > /root/ai-daily-scan/src/outcomes_reader.py <<'EOF'
"""outcomes_reader.py — 读 ai-auto-harness 通过 MCP 回填的 outcomes.jsonl

ai-daily-scan 的 Scanner / Analyst 可以读这个判断"哪些已 done 不要重推"
"""
import json
import pathlib
from datetime import datetime, timezone, timedelta


def append_outcome(
    path: pathlib.Path,
    *,
    slug: str,
    status: str,
    run_id: str,
    error_class: str | None = None,
    phase_failed_at: str | None = None,
    notes: str | None = None,
    repair_count: int = 0,
) -> None:
    """Append 一行 outcome 到 JSONL"""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rec = {
        "slug": slug,
        "status": status,
        "run_id": run_id,
        "error_class": error_class,
        "phase_failed_at": phase_failed_at,
        "notes": notes,
        "repair_count": repair_count,
        "ts": datetime.now(timezone.utc).isoformat(),
    }
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def load_recent_outcomes(path: pathlib.Path, *, days: int = 30) -> list[dict]:
    """返回近 N 天的 outcomes"""
    path = pathlib.Path(path)
    if not path.exists():
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        ts = datetime.fromisoformat(rec["ts"])
        if ts >= cutoff:
            out.append(rec)
    return out
EOF
```

- [ ] **Step 4: 跑测试**

```bash
cd /root/ai-daily-scan
pytest tests/test_outcomes_reader.py -v 2>&1 | tail -10
```

Expected:3 PASSED

- [ ] **Step 5: Commit**

```bash
git add src/outcomes_reader.py tests/test_outcomes_reader.py
git commit -m "feat(outcomes_reader): read auto-harness deploy outcomes for scan deduplication"
```

---

### Task 0.6: run_daily.py 集成 findings_writer

**Files:**
- Modify:`/root/ai-daily-scan/src/run_daily.py`

- [ ] **Step 1: 阅读现有 run_daily.py main flow**

读 `/root/ai-daily-scan/src/run_daily.py`,找到最后写 markdown 报告的地方(应该在 `orchestrator.run()` 返回后)。

- [ ] **Step 2: 加 findings_writer 调用**

在写 markdown 报告之后,加:

```python
# === ai-auto-harness 集成:产 findings.jsonl ===
from src.findings_writer import write_findings, build_finding

scan_ts = datetime.now(timezone.utc).isoformat()
findings = [
    build_finding(report, scan_ts=scan_ts, scan_report_path=str(report_path))
    for report in analyst_reports  # 或 orchestrator 返回的 reports 名字
]
findings_path = pathlib.Path("state/findings.jsonl")
write_findings(findings, findings_path)
log.info(f"findings.jsonl written: {len(findings)} entries → {findings_path}")
```

(精确变量名按现有代码风格调整。注意 import 提到顶部。)

- [ ] **Step 3: 手动跑一次完整 scan,看 findings.jsonl 产出**

```bash
cd /root/ai-daily-scan
python -m src.run_daily 2>&1 | tail -20
ls -la state/findings.jsonl
echo "---"
head -1 state/findings.jsonl | python -m json.tool
```

Expected:文件存在,第一行是合法 JSON 含 13+ 字段

- [ ] **Step 4: Commit**

```bash
git add src/run_daily.py
git commit -m "feat(run_daily): emit state/findings.jsonl after scan completes"
```

---

### Task 0.7: MCP Server 骨架 + scan_today 工具

**Files:**
- Create:`/root/ai-daily-scan/mcp_server.py`

- [ ] **Step 1: 创建 MCP server**

```bash
cat > /root/ai-daily-scan/mcp_server.py <<'EOF'
"""MCP server — 给 ai-auto-harness 的 CC 主 agent 调用 ai-daily-scan 能力

启动:python mcp_server.py(由 CC settings.json 的 mcpServers 配置 stdio spawn)
"""
import json
import pathlib
import subprocess
import logging
from datetime import datetime, timezone, timedelta
from mcp.server.fastmcp import FastMCP

log = logging.getLogger("ai_daily_scan_mcp")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

REPO_ROOT = pathlib.Path(__file__).parent
STATE_DIR = REPO_ROOT / "state"
FINDINGS_PATH = STATE_DIR / "findings.jsonl"
OUTCOMES_PATH = STATE_DIR / "outcomes.jsonl"
SCAN_FRESHNESS_HOURS = 2

mcp = FastMCP("ai_daily_scan")


@mcp.tool()
def scan_today(force: bool = False) -> dict:
    """检查今日 scan 是否已跑过.

    若 findings.jsonl 存在且 < SCAN_FRESHNESS_HOURS 小时,直接返回路径.
    否则触发 run_daily(耗时 17-21 分钟).

    Returns: {report_path, findings_jsonl_path, project_count, scan_ts}
    """
    if not force and FINDINGS_PATH.exists():
        age_seconds = (
            datetime.now().timestamp() - FINDINGS_PATH.stat().st_mtime
        )
        if age_seconds < SCAN_FRESHNESS_HOURS * 3600:
            return _build_scan_response(reason="cached")
    log.info("triggering full scan via src.run_daily ...")
    proc = subprocess.run(
        ["python", "-m", "src.run_daily"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {"error": "scan_failed", "stderr": proc.stderr[-2000:]}
    return _build_scan_response(reason="fresh")


def _build_scan_response(reason: str) -> dict:
    findings = _read_findings()
    # 找最新 markdown 报告
    reports_dir = REPO_ROOT
    report_md = sorted(reports_dir.glob("*_report.md"))[-1] if list(reports_dir.glob("*_report.md")) else None
    return {
        "reason": reason,
        "report_path": str(report_md) if report_md else None,
        "findings_jsonl_path": str(FINDINGS_PATH),
        "project_count": len(findings),
        "scan_ts": findings[0]["scan_ts"] if findings else None,
    }


def _read_findings() -> list[dict]:
    if not FINDINGS_PATH.exists():
        return []
    out = []
    for line in FINDINGS_PATH.read_text(encoding="utf-8").splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out


if __name__ == "__main__":
    mcp.run()
EOF
```

- [ ] **Step 2: 验证 server 能起来(不进 mcp loop,只 import 测试)**

```bash
cd /root/ai-daily-scan
python -c "import mcp_server; print('module loads ok, tools:', [t.name for t in mcp_server.mcp._tools.values()])"
```

Expected:输出 `module loads ok, tools: ['scan_today']`

- [ ] **Step 3: 写 scan_today smoke test**

```bash
cat > /root/ai-daily-scan/tests/test_mcp_server.py <<'EOF'
"""MCP server 工具的单元测试 — 不走 stdio,直接调函数"""
import pathlib
import tempfile
import json
from unittest.mock import patch
import mcp_server


def test_scan_today_uses_cache_when_fresh(tmp_path, monkeypatch):
    findings = tmp_path / "findings.jsonl"
    findings.write_text(
        json.dumps({"slug": "x", "scan_ts": "2026-05-19T09:00:00"}) + "\n"
    )
    monkeypatch.setattr(mcp_server, "FINDINGS_PATH", findings)
    monkeypatch.setattr(mcp_server, "REPO_ROOT", tmp_path)
    resp = mcp_server.scan_today(force=False)
    assert resp["project_count"] == 1
    assert resp["reason"] == "cached"
EOF

cd /root/ai-daily-scan
pytest tests/test_mcp_server.py -v 2>&1 | tail -10
```

Expected:1 PASSED

- [ ] **Step 4: Commit**

```bash
git add mcp_server.py tests/test_mcp_server.py
git commit -m "feat(mcp): add MCP server with scan_today tool"
```

---

### Task 0.8: MCP — get_recent_findings 工具

**Files:**
- Modify:`/root/ai-daily-scan/mcp_server.py`
- Modify:`/root/ai-daily-scan/tests/test_mcp_server.py`

- [ ] **Step 1: 加测试**

```python
# 追加到 tests/test_mcp_server.py
def test_get_recent_findings_returns_list(tmp_path, monkeypatch):
    findings = tmp_path / "findings.jsonl"
    findings.write_text(
        json.dumps({"slug": "a"}) + "\n" +
        json.dumps({"slug": "b"}) + "\n"
    )
    monkeypatch.setattr(mcp_server, "FINDINGS_PATH", findings)
    result = mcp_server.get_recent_findings(days=7)
    assert len(result) == 2
    assert result[0]["slug"] == "a"
```

- [ ] **Step 2: 跑确认 fail**

```bash
cd /root/ai-daily-scan
pytest tests/test_mcp_server.py::test_get_recent_findings_returns_list -v
```

Expected:AttributeError(`get_recent_findings` 还没定义)

- [ ] **Step 3: 实现工具**

在 `mcp_server.py` 中加:

```python
@mcp.tool()
def get_recent_findings(days: int = 7) -> list[dict]:
    """返回最近 N 天 scan 的 findings(若 scan 频率高于 daily,可能多次 overwrite,只看最新一次).

    Returns: list of Finding dicts
    """
    return _read_findings()
```

(MVP 简化:findings.jsonl 是 scan 每次覆写的,所以"最近 N 天"对一次 scan 等价于全部读;若未来 scan 改成 append 历史,这里再过滤)

- [ ] **Step 4: 跑测试**

```bash
pytest tests/test_mcp_server.py -v 2>&1 | tail -10
```

Expected:2 PASSED

- [ ] **Step 5: Commit**

```bash
git add mcp_server.py tests/test_mcp_server.py
git commit -m "feat(mcp): add get_recent_findings tool"
```

---

### Task 0.9: MCP — record_outcome 工具

**Files:**
- Modify:`/root/ai-daily-scan/mcp_server.py`
- Modify:`/root/ai-daily-scan/tests/test_mcp_server.py`

- [ ] **Step 1: 加测试**

```python
def test_record_outcome_appends_to_jsonl(tmp_path, monkeypatch):
    out = tmp_path / "outcomes.jsonl"
    monkeypatch.setattr(mcp_server, "OUTCOMES_PATH", out)
    resp = mcp_server.record_outcome(
        slug="flux-schnell",
        status="failed",
        error_class="gated_repo_no_token",
        run_id="r123",
    )
    assert resp["ok"] is True
    lines = out.read_text().strip().split("\n")
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["slug"] == "flux-schnell"
    assert rec["status"] == "failed"
```

- [ ] **Step 2: 跑 fail**

```bash
pytest tests/test_mcp_server.py::test_record_outcome_appends_to_jsonl -v
```

Expected:AttributeError

- [ ] **Step 3: 实现**

```python
from src.outcomes_reader import append_outcome  # 顶部加

@mcp.tool()
def record_outcome(
    slug: str,
    status: str,
    run_id: str,
    error_class: str | None = None,
    phase_failed_at: str | None = None,
    notes: str | None = None,
    repair_count: int = 0,
) -> dict:
    """CC 端把 deploy/verify 结果回填给 scan.

    status 取值: passed | failed | paused_for_human | skipped_too_large | api_route
    Append 一条到 state/outcomes.jsonl
    """
    append_outcome(
        OUTCOMES_PATH,
        slug=slug,
        status=status,
        run_id=run_id,
        error_class=error_class,
        phase_failed_at=phase_failed_at,
        notes=notes,
        repair_count=repair_count,
    )
    return {"ok": True, "appended_to": str(OUTCOMES_PATH)}
```

- [ ] **Step 4: 跑测试 + Commit**

```bash
pytest tests/test_mcp_server.py -v 2>&1 | tail -10
git add mcp_server.py tests/test_mcp_server.py
git commit -m "feat(mcp): add record_outcome tool — CC回填 deploy 结果"
```

---

### Task 0.10: MCP — analyze_project 工具

**Files:**
- Modify:`/root/ai-daily-scan/mcp_server.py`

- [ ] **Step 1: 实现**

```python
from src.tools import analyze_project as _analyze_project_impl

@mcp.tool()
def analyze_project(url: str) -> dict:
    """ad-hoc 分析单个项目 URL — 给 /auto-deploy <url> 命令用.

    内部跑一次 Analyst,返回 AnalystReport(含 4 个新字段)
    """
    return _analyze_project_impl(url)
```

- [ ] **Step 2: 手动 smoke**

```bash
cd /root/ai-daily-scan
python -c "
import mcp_server
r = mcp_server.analyze_project('https://github.com/tencent-ailab/SongGeneration')
print('next_action:', r.get('next_action'))
print('size_gb:', r.get('estimated_weight_size_gb'))
print('params_b:', r.get('estimated_params_b'))
"
```

Expected:next_action 是合法 enum

- [ ] **Step 3: Commit**

```bash
git add mcp_server.py
git commit -m "feat(mcp): add analyze_project tool for ad-hoc URL analysis"
```

---

### Task 0.11: 端到端集成测试 + merge

**Files:**
- 无新文件,只 merge

- [ ] **Step 1: 全部测试通过**

```bash
cd /root/ai-daily-scan
pytest tests/ -v 2>&1 | tail -15
```

Expected:所有 test 都 PASSED

- [ ] **Step 2: stdio 端到端 smoke**

```bash
# 启 MCP server,模拟 stdio 客户端调一个工具
cd /root/ai-daily-scan
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | timeout 5 python mcp_server.py
```

Expected:输出 JSON 列出 4 个工具(scan_today / get_recent_findings / record_outcome / analyze_project)。注意 FastMCP 用 JSON-RPC over stdio,实际 framing 可能需要 `\n`-delimited;若 simple echo 不行,跳过这一步,Phase 1 用 CC 通过 settings.json 真正连。

- [ ] **Step 3: 合并到 main**

```bash
cd /root/ai-daily-scan
git checkout main
git merge feature/mcp-integration --no-ff -m "merge: add MCP integration for ai-auto-harness platform"
git push origin main
```

- [ ] **Step 4: 删 feature 分支**

```bash
git branch -d feature/mcp-integration
git push origin --delete feature/mcp-integration  # 若已 push 过的话
```

---

## Phase 0 Milestone 验收

- [ ] `pytest /root/ai-daily-scan/tests/ -v` 全 PASS
- [ ] `python -m src.run_daily` 产 `state/findings.jsonl`,head -1 含 4 个新字段
- [ ] `python -c "import mcp_server; print(mcp_server.mcp._tools.keys())"` 输出 4 个工具
- [ ] main 分支已 push

---

## Phase 1: ai-auto-harness 骨架 + intake skill

**Milestone**:`./bin/claude-haha --print "/auto-daily"` 能跑通 → 读 findings.jsonl → pick 1 项目 → SubAgent 1 intake 完成 clone + 读 README + preflight,返回 blocked=[] 或合理的 blocked 列表

---

### Task 1.1: Gitea repo 创建 + 本地 git setup

**Files:**
- 用户 web 操作:在 `http://192.168.1.227/maihaicheng/` 上确认 `ai-auto-harness` repo 已建(已经建过,带 README)
- 本地:fork CC + remote setup

- [ ] **Step 1: 把刚生成的 spec/plan 文档暂存**

```bash
mv /root/ai-auto-harness /tmp/ai-auto-spec-bak
ls /tmp/ai-auto-spec-bak/docs/
```

Expected:看到 `superpowers/` 子目录

- [ ] **Step 2: fork claudecode_sourcecode1 当 base**

```bash
git clone /root/claudecode_sourcecode1 /root/ai-auto-harness
cd /root/ai-auto-harness
git log --oneline | head -5  # 应该看到 CC 历史
```

- [ ] **Step 3: rename remote**

```bash
cd /root/ai-auto-harness
git remote rename origin upstream
git remote add origin http://192.168.1.227/maihaicheng/ai-auto-harness.git
git remote -v
```

Expected:origin 指向 Gitea,upstream 指向 /root/claudecode_sourcecode1

- [ ] **Step 4: 移回 spec/plan**

```bash
cp -r /tmp/ai-auto-spec-bak/docs /root/ai-auto-harness/
# 把 Phase -1 写的 experiments 也移回
cp -r /tmp/ai-auto-spec-bak/experiments /root/ai-auto-harness/ 2>/dev/null || true
ls /root/ai-auto-harness/docs/superpowers/
ls /root/ai-auto-harness/experiments/ 2>/dev/null
```

- [ ] **Step 5: 加平台运行时 .gitignore(append)**

```bash
cd /root/ai-auto-harness
cat >> .gitignore <<'EOF'

# AI Auto Harness 平台运行时数据(不进 git)
workspace/
runs/
memory/projects/
pending_human/
state/blacklist.jsonl
state/deployment_history.jsonl
reports/
EOF
```

注意:`memory/lessons/` 是 seed 文件(我们写的)要 commit,所以 .gitignore 里只忽略 `memory/projects/`。

- [ ] **Step 6: 第一次 commit + force push 覆盖 Gitea README**

```bash
cd /root/ai-auto-harness
git add docs/ experiments/ .gitignore
git commit -m "ai-auto: initial design doc + plan + preflight experiments + gitignore"
git branch -M main
git push -u origin main --force
```

- [ ] **Step 7: 验证 Gitea 上看得到**

```bash
# Web 界面打开 http://192.168.1.227/maihaicheng/ai-auto-harness/
# 应该看到 src/, docs/, experiments/, .gitignore 等
echo "manual check via web"
```

- [ ] **Step 8: 清理 tmp**

```bash
rm -rf /tmp/ai-auto-spec-bak
```

---

### Task 1.2: .claude/CLAUDE.md 项目根上下文

**Files:**
- Create:`/root/ai-auto-harness/.claude/CLAUDE.md`

注意:`/root/ai-auto-harness/.claude/` 这个目录在 CC base 里**可能已经存在**(CC 自带 bundle skills),我们只是在里面加文件。

- [ ] **Step 1: 检查现有 .claude/**

```bash
ls -la /root/ai-auto-harness/.claude/
ls /root/ai-auto-harness/.claude/skills/ 2>/dev/null
```

记录看到了什么(可能有 ai-legacy-bridge 之类的 CC 自带 skill)。

- [ ] **Step 2: 写项目根 CLAUDE.md**

```bash
mkdir -p /root/ai-auto-harness/.claude
cat > /root/ai-auto-harness/.claude/CLAUDE.md <<'EOF'
# AI Auto Harness — Project Context

你正在 `/root/ai-auto-harness/` 这个工作目录中运行。这是一个**基于 Claude Code 源码的自定义 harness**,目标是 cron-driven 地自动发现 AI 项目信号、自动部署、自动验证、产出公司视角建议。

## 硬约束(必须遵守)

| 维度 | 阈值 |
|---|---|
| GPU 单卡占用 | 已用 ≥ 25GB(31.8GB total)拒动 |
| GPU 叠加预估 | 叠加后剩余必须 ≥ 2GB |
| 磁盘 free | 拉权重前 free ≥ (估算总大小 + 50GB safety) |
| 模型规模 | self-host 目标 ≤ 30B 参数;超过走 api-skeleton |
| torch sm 兼容 | wheel 必须含 sm_12.0(5090) |
| 并发项目数 | 单次 cron run N=1 |
| 修复循环上限 | 同阶段 max 3 轮 LLM 决策后 raise pending_human |

## 工作流(主 agent / `/auto-daily`)

1. 接续扫:`workspace/*/state.json` phase ∉ {done, paused_for_human}
2. 项目选择:接续优先 OR scan_today → 按 30B/blacklist/gated 过滤
3. 部署流水线:按 state.phase 串行 dispatch 5 SubAgent
4. 写报告 + MCP `record_outcome` 回填

## 关键路径

- 设计文档:`docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md`
- 实施计划:`docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`
- 主 skill:`.claude/skills/ai-auto/daily-auto.md`
- 5 SubAgent skills:`.claude/skills/ai-auto/{intake,fetch-weights,install-env,run-and-repair,verify}.md`
- 项目工作目录:`workspace/<slug>/`
- 经验积累:`memory/lessons/*.md`

## SubAgent 隔离

每个项目部署用 5 个 SubAgent 串行,每个 SubAgent 独立 context.
SubAgent 5(verify)**禁止读** state.json 的 run_result 字段 — 独立判定原则。

## 不要做

- 不要在主 agent 直接跑 `git clone` / `pip install` / `python script.py` — 那是 SubAgent 的事
- 不要 max_turns > 3 在 run-and-repair 阶段(写 pending_human 比硬试好)
- 不要污染全局 HF cache — 每个项目用 `HF_HOME=workspace/<slug>/.cache/huggingface`
- 不要在 verify 阶段修问题 — 只判定
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/CLAUDE.md
git commit -m "ai-auto: add project CLAUDE.md with hard constraints and workflow"
```

---

### Task 1.3: .claude/settings.json

**Files:**
- Create:`/root/ai-auto-harness/.claude/settings.json`

- [ ] **Step 1: 写 settings.json**

```bash
cat > /root/ai-auto-harness/.claude/settings.json <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git clone *)",
      "Bash(git pull *)",
      "Bash(git status*)",
      "Bash(git log *)",
      "Bash(huggingface-cli *)",
      "Bash(hf *)",
      "Bash(pip *)",
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(nvidia-smi*)",
      "Bash(df *)",
      "Bash(du *)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(tail *)",
      "Bash(head *)",
      "Bash(grep *)",
      "Bash(find *)",
      "Bash(jq *)",
      "Bash(mkdir *)",
      "Bash(rm -rf workspace/*)",
      "Bash(rm -rf /tmp/*)",
      "Bash(curl -s https://huggingface.co/api/*)",
      "Bash(curl -sI https://huggingface.co/*)",
      "Bash(nohup *)",
      "Bash(setsid *)",
      "Bash(kill *)",
      "Bash(pgrep *)",
      "Bash(source *)",
      "Bash(echo *)",
      "Bash(test *)",
      "Bash(true)",
      "Bash(false)",
      "Read(*)",
      "Write(workspace/**)",
      "Write(runs/**)",
      "Write(reports/**)",
      "Write(memory/**)",
      "Write(pending_human/**)",
      "Write(state/**)",
      "Edit(workspace/**)",
      "Grep(*)",
      "Task(*)",
      "BashOutput(*)",
      "KillBash(*)",
      "mcp__ai_daily_scan__*"
    ],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~/*)",
      "Bash(rm -rf /root/*)",
      "Bash(sudo *)",
      "Write(/etc/**)",
      "Write(/root/.ssh/**)",
      "Write(/root/.claude/**)"
    ]
  },
  "mcpServers": {
    "ai_daily_scan": {
      "command": "python",
      "args": ["/root/ai-daily-scan/mcp_server.py"],
      "env": {
        "PYTHONPATH": "/root/ai-daily-scan"
      }
    }
  },
  "hooks": {
    "SessionStart": [{
      "matcher": ".*",
      "hooks": [{"type": "command", "command": "/root/ai-auto-harness/.claude/hooks/session-start.sh"}]
    }],
    "PostToolUse": [{
      "matcher": ".*",
      "hooks": [{"type": "command", "command": "/root/ai-auto-harness/.claude/hooks/post-tool-use.sh"}]
    }],
    "SessionEnd": [{
      "matcher": ".*",
      "hooks": [{"type": "command", "command": "/root/ai-auto-harness/.claude/hooks/session-end.sh"}]
    }]
  }
}
EOF
```

注意:`mcpServers` 格式 + `hooks` 格式参考 CC 文档,这是 MVP 版本,实施时按 CC 真正 settings 协议微调。

- [ ] **Step 2: 验证 JSON 合法**

```bash
python -m json.tool /root/ai-auto-harness/.claude/settings.json > /dev/null && echo "valid JSON"
```

Expected:`valid JSON`

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/settings.json
git commit -m "ai-auto: add settings.json (permissions + MCP + hooks)"
```

---

### Task 1.4: SessionStart hook

**Files:**
- Create:`/root/ai-auto-harness/.claude/hooks/session-start.sh`

- [ ] **Step 1: 写 hook**

```bash
mkdir -p /root/ai-auto-harness/.claude/hooks
cat > /root/ai-auto-harness/.claude/hooks/session-start.sh <<'EOF'
#!/bin/bash
# 生成 run-id 并落盘(post-tool-use 会读),同时把今日上下文摘要输出到 system prompt addendum
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

RUN_ID="$(date +%Y-%m-%d-%H%M)-$$"
mkdir -p "runs/$RUN_ID"
echo "$RUN_ID" > "runs/.current_run_id"

echo "## Today's context (loaded by SessionStart hook)"
echo "Run ID: $RUN_ID"
echo ""
echo "### Findings (latest scan, top 5)"
if [ -f "/root/ai-daily-scan/state/findings.jsonl" ]; then
    head -5 /root/ai-daily-scan/state/findings.jsonl | jq -c '{slug, estimated_params_b, next_action, scenario_hits}' 2>/dev/null || echo "(jq 解析失败,raw 前 200 字符)"
    head -1 /root/ai-daily-scan/state/findings.jsonl | head -c 200
else
    echo "(scan 还没产 findings.jsonl)"
fi
echo ""

echo "### In-progress projects (workspace state)"
if [ -d "workspace" ]; then
    find workspace -maxdepth 2 -name state.json -exec jq -c '{slug, phase, updated_at}' {} \; 2>/dev/null | head -10 || echo "(无)"
else
    echo "(无 workspace 目录)"
fi
echo ""

echo "### Pending human"
if [ -d "pending_human" ]; then
    ls pending_human/ 2>/dev/null | grep -v "^_" || echo "(无积压)"
else
    echo "(无)"
fi
echo ""

echo "### Resources"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader 2>/dev/null | head -10
df -h /root 2>/dev/null | tail -1
EOF
chmod +x /root/ai-auto-harness/.claude/hooks/session-start.sh
```

- [ ] **Step 2: 手动跑一次验证**

```bash
bash /root/ai-auto-harness/.claude/hooks/session-start.sh
ls /root/ai-auto-harness/runs/
```

Expected:看到 `## Today's context ...` 输出 + 在 runs/ 下创建了一个目录

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/hooks/session-start.sh
git commit -m "ai-auto: add SessionStart hook for run-id + context loading"
```

---

### Task 1.5: PostToolUse hook

**Files:**
- Create:`/root/ai-auto-harness/.claude/hooks/post-tool-use.sh`

- [ ] **Step 1: 写 hook**

```bash
cat > /root/ai-auto-harness/.claude/hooks/post-tool-use.sh <<'EOF'
#!/bin/bash
# 每次 tool_use + tool_result 追到 runs/<run-id>/transcript.jsonl
# CC 通过 stdin 传 JSON event 给 hook(参考 CC hook 协议)
set -e
HARNESS_ROOT="/root/ai-auto-harness"
RUN_ID=$(cat "$HARNESS_ROOT/runs/.current_run_id" 2>/dev/null || echo "unknown")
TRANSCRIPT="$HARNESS_ROOT/runs/$RUN_ID/transcript.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"

# stdin 应该是 CC 注入的 JSON,我们 wrap 加 ts
TS=$(date -Iseconds)
EVENT=$(cat)
echo "{\"ts\":\"$TS\",\"event\":$EVENT}" >> "$TRANSCRIPT"
EOF
chmod +x /root/ai-auto-harness/.claude/hooks/post-tool-use.sh
```

注意:CC hook 协议具体输入格式可能与本简化版不同,实施时按 CC `src/hooks/` 真实协议调整。

- [ ] **Step 2: 模拟 stdin 跑测试**

```bash
echo '{"tool":"Bash","input":"ls"}' | bash /root/ai-auto-harness/.claude/hooks/post-tool-use.sh
ls /root/ai-auto-harness/runs/*/transcript.jsonl 2>/dev/null | head -1 | xargs -I {} tail {}
```

Expected:transcript.jsonl 末尾有一行 JSON

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/hooks/post-tool-use.sh
git commit -m "ai-auto: add PostToolUse hook for transcript.jsonl append"
```

---

### Task 1.6: SessionEnd hook

**Files:**
- Create:`/root/ai-auto-harness/.claude/hooks/session-end.sh`

- [ ] **Step 1: 写 hook**

```bash
cat > /root/ai-auto-harness/.claude/hooks/session-end.sh <<'EOF'
#!/bin/bash
# 落盘归档:git commit 报告(若有变化),清理 7 天以上 runs
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 只 commit 报告 + memory(workspace 是 gitignored)
git add reports/ memory/ pending_human/ 2>/dev/null || true
if ! git diff --cached --quiet; then
    git commit -m "auto-run $(date +%Y-%m-%d-%H%M): update reports/memory" || true
fi

# 清 7 天以上 runs
find runs/ -maxdepth 1 -mtime +7 -type d -exec rm -rf {} \; 2>/dev/null || true
EOF
chmod +x /root/ai-auto-harness/.claude/hooks/session-end.sh
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/hooks/session-end.sh
git commit -m "ai-auto: add SessionEnd hook for git commit + cleanup"
```

---

### Task 1.7: daily-auto skill 骨架(到 pick 1 项目)

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/daily-auto.md`

- [ ] **Step 1: 写 skill 文件**

```bash
mkdir -p /root/ai-auto-harness/.claude/skills/ai-auto
cat > /root/ai-auto-harness/.claude/skills/ai-auto/daily-auto.md <<'EOF'
---
name: daily-auto
description: AI Auto Harness 顶层工作流 — 接续 / pick / dispatch 5 阶段 SubAgent / 写报告
allowed-tools: [Read, Write, Bash, Task, mcp__ai_daily_scan__*]
---

# daily-auto

你是 AI Auto Harness 平台的主 agent。每天 10:30 由 cron 启动你。

## 工作流(顺序执行)

### 任务 1:接续与积压检查

```bash
find workspace -maxdepth 2 -name state.json -exec jq -c '.' {} \; 2>/dev/null
```

筛选 `state.phase ∉ {done, paused_for_human}` 的项目(in_progress)。

也扫 `pending_human/*.md`(不重跑,但报告里要标)。

### 任务 2:项目选择

**有 in_progress** → 选最早 `started_at` 的接续(直接跳到任务 3,从 state.phase 对应阶段开始)

**无 in_progress** → 调 `mcp__ai_daily_scan__scan_today()` 拿 findings.jsonl 路径,读它,按规则:

**过滤**:
- `estimated_params_b ≤ 30`(否则改 next_action=try_api_pilot,见末尾"特例")
- 不在 `state/blacklist.jsonl`(未过期)
- 不在 `pending_human/`
- `gated_repos` 为空 OR `$HF_TOKEN` 已配置
- 不在 outcomes.jsonl status=passed 且 30 天内

**排序**:`confidence=high` 优先 → `len(scenario_hits)` 多 → `scan_ts` 新

### 任务 3:部署流水线

读项目 `workspace/<slug>/state.json` 决定从哪个阶段开始:

| phase | dispatch SubAgent | 完成后 → |
|---|---|---|
| null(新项目) | intake | state.phase=fetching |
| fetching | fetch-weights | state.phase=installing |
| installing | install-env | state.phase=running |
| running | run-and-repair | state.phase=verifying |
| verifying | verify | state.phase=done |

任一 SubAgent 返回 `blocked=true` 或 `paused_for_human` → 跳到任务 4。

### 特例:模型 > 30B 或不能 self-host

- 任务 2 过滤时 `estimated_params_b > 30` 的项目改走 api_pilot
- 跳过 intake,直接 dispatch **api-skeleton skill**
- 产出 `workspace/<slug>/api_skeleton/{client.py, smoke_test.py, .env.example, 使用指导.md}`
- state.phase=done(api_route),outcomes status=api_route

### 任务 4:写报告 + 回填

- 调 **write-recommendation skill** 写 `reports/<date>.md`(覆写,因单天可能多次 cron 重跑)
- 调 **mcp__ai_daily_scan__record_outcome(slug, status, ...)**

## 硬约束

- N=1 单项目串行,**不并行** dispatch SubAgent
- 任一阶段 SubAgent 返回 `paused_for_human` → 立刻跳到任务 4
- 接续模式下**不挑新项目**
- 你不亲自跑 git/pip/python — 那些是 SubAgent 的事

## 反模式

- 不要主 agent 自己 git clone / pip install — 都交给 SubAgent
- 不要并行 dispatch 多个 SubAgent(初版 N=1)
- 不要 max_turns > 3 在 SubAgent 失败时硬试

EOF
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/daily-auto.md
git commit -m "ai-auto: add daily-auto skill (主 agent 顶层工作流骨架)"
```

---

### Task 1.8: intake-agent + preflight-gpu-disk skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/agents/intake-agent.md`
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/preflight-gpu-disk.md`

- [ ] **Step 1: 写 intake-agent 角色定义**

```bash
mkdir -p /root/ai-auto-harness/.claude/agents
cat > /root/ai-auto-harness/.claude/agents/intake-agent.md <<'EOF'
---
name: intake-agent
description: 项目部署第一阶段 SubAgent — clone + 读 README + preflight(GPU/磁盘/gated/30B)
allowed-tools: [Read, Write, Bash, Grep]
---

# intake-agent

你是 ai-auto-harness 项目部署的 intake SubAgent。

## 你的输入(由主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "github_url": "...",
  "hf_repos": ["..."],
  "estimated_weight_size_gb": 36,
  "estimated_params_b": 12,
  "gated_repos": ["..."],
  "scenario_hits": ["scenario_003"]
}
```

## 你的输出

执行 `intake.md` skill 的工作流后,返回:

```json
{
  "entry_script": "python -m flux t2i --output out.png",
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```

## 工具集

只能用:`Read`, `Write`, `Bash`, `Grep`。不要 Edit(intake 不改代码)。

## 行为准则

- 失败立刻 raise(写 pending_human),不要重试
- preflight 不通过 → blocked 数组列出原因
- 不要污染 workspace 之外的目录
EOF
```

- [ ] **Step 2: 写 preflight-gpu-disk 子能力**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/preflight-gpu-disk.md <<'EOF'
---
name: preflight-gpu-disk
description: GPU / 磁盘 / gated repo / 模型规模 资源 preflight 子能力 — intake skill 调
---

# preflight-gpu-disk

intake/install 阶段调本子能力做资源 preflight。

## GPU preflight

```bash
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader,nounits
```

输出每张卡 `index, used_MiB, free_MiB, total_MiB`(单位 MiB)。

判定规则:
- 单卡 `used >= 25000`(MiB,即 ~25GB)→ 该卡 **不参与分配**
- 其余卡按 `free` 降序排,取 Top N(N=项目需要的 GPU 数,可从 README 推断)
- 选中卡 `free >= 项目预估需求 + 2048`(2GB safety) → ok
- 否则 → blocked.append("gpu_insufficient")

## 磁盘 preflight

```bash
df -h /root | awk 'NR==2 {print $4}'  # Avail
```

转换为 GB(去掉 G/M 后缀)。

判定:
- `free_gb >= estimated_weight_size_gb + 50` → ok
- 否则 → blocked.append(f"disk_low: free={free_gb}GB, need={total_need}GB")
  + 提示用户清理 `/root/core.*` 或 `workspace/` 老项目

## Gated Repo preflight

对 `hf_repos[]` 中每个 repo:

```bash
curl -s "https://huggingface.co/api/models/<repo>" | jq -r '.gated // "false"'
```

- 输出 `"manual"` 或 `"auto"` → 是 gated
- 输出 `"false"` 或 null → 公开

对每个 gated repo,试探下载小文件:

```bash
huggingface-cli download <repo> README.md --quiet 2>&1
```

- 成功 → 已有 token 且权限 OK
- 失败含 "401" / "Unauthorized" → blocked.append(f"gated_no_token: {repo}")

## 模型规模 preflight

```python
# 已经从主 agent 拿到 estimated_params_b
if estimated_params_b > 30:
    blocked.append(f"model_too_large: {estimated_params_b}B > 30B threshold")
    # 主 agent 应该已过滤,这里 double check
```

## 返回

```json
{
  "gpu_picks": [3, 4],
  "blocked": [],
  "free_disk_gb": 580,
  "gated_check": {"<repo>": "ok|needs_token"}
}
```
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/agents/intake-agent.md .claude/skills/ai-auto/preflight-gpu-disk.md
git commit -m "ai-auto: add intake-agent role + preflight-gpu-disk skill"
```

---

### Task 1.9: intake skill 主体

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/intake.md`

- [ ] **Step 1: 写 skill**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/intake.md <<'EOF'
---
name: intake
description: 项目部署第一阶段 — clone + 读 README + preflight(GPU/磁盘/gated/30B)
allowed-tools: [Read, Write, Bash, Grep]
agent: intake-agent
---

# intake

## 工作流(按顺序)

### 1. workspace 初始化

```bash
SLUG="<from main agent>"
WORKSPACE="/root/ai-auto-harness/workspace/$SLUG"
mkdir -p "$WORKSPACE"/{.cache/huggingface,.cache/hf_hub,.cache/transformers,repo}
echo '{"slug":"'$SLUG'","phase":"intake","started_at":"'$(date -Iseconds)'"}' > "$WORKSPACE/state.json"
```

### 2. 克隆

```bash
git clone --depth=1 <github_url> "$WORKSPACE/repo"
```

失败 → `return {"blocked": ["git_clone_failed", "<error msg>"]}`

### 3. 读核心文件

用 Read 工具读(优先级):
- `$WORKSPACE/repo/README.md`(找 Quickstart / Inference / Demo 章节)
- `$WORKSPACE/repo/setup.py` 或 `pyproject.toml`
- `$WORKSPACE/repo/requirements*.txt`
- `$WORKSPACE/repo/*example*.py`、`inference*.py`、`demo*.py`、`app.py`
- `$WORKSPACE/repo/configs/*.yaml`(若有)

### 4. 推断 entry_script

优先级:
1. README quickstart / inference 章节里的 shell 命令
2. setup.py 的 `console_scripts` 入口
3. inference.py / demo.py / app.py(若是 self-contained CLI)
4. 都找不到 → `return {"blocked": ["entry_script_unknown"]}`

验证(必做):

```bash
cd "$WORKSPACE/repo"
# 暂时用 system python 试探 --help(还没装项目)
python -c "import sys; sys.path.insert(0, '.'); import <main_module>" 2>&1 | head -5
```

不强求 import 成功(可能缺 deps),但能 import 顶层 module 就好。

### 5. 校准 hf_deps

```bash
grep -rn "from_pretrained" "$WORKSPACE/repo/" --include="*.py" | head -20
grep -rn "hf_hub_download\|snapshot_download" "$WORKSPACE/repo/" --include="*.py" | head -20
```

提取实际引用的 repo 名,与主 agent 传入的 `hf_repos` 比对。补全缺少的 / 修正错误的。

### 6. Preflight(调 preflight-gpu-disk skill)

按 `.claude/skills/ai-auto/preflight-gpu-disk.md` 的 4 类检查:GPU / 磁盘 / Gated / Size。

汇总 blocked 数组。

### 7. 更新 state.json

```bash
# 写完整 state.json
cat > "$WORKSPACE/state.json" <<JSON
{
  "slug": "$SLUG",
  "github_url": "...",
  "hf_repos": [...],
  "estimated_params_b": ...,
  "estimated_weight_size_gb": ...,
  "gated_repos": [...],
  "phase": "fetching",
  "phases_done": ["intake"],
  "intake_result": {
    "entry_script": "...",
    "hf_deps": [...],
    "gpu_picks": [...],
    "blocked": []
  },
  "started_at": "...",
  "updated_at": "$(date -Iseconds)"
}
JSON
```

### 失败处理

- `blocked` 非空 → 调 **request-human-intervention skill** 写 `pending_human/<slug>.md`,state.phase=`paused_for_human`
- 不要自己重试(主 agent 决策)

## 返回 schema

```json
{
  "entry_script": "python -m flux t2i --output out.png",
  "hf_deps": ["..."],
  "gpu_picks": [3, 4],
  "blocked": [],
  "ready_to_fetch": true
}
```
EOF
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/intake.md
git commit -m "ai-auto: add intake skill (SubAgent 1) main body"
```

---

### Task 1.10: request-human-intervention skill(子能力)

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/request-human-intervention.md`

- [ ] **Step 1: 写 skill**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/request-human-intervention.md <<'EOF'
---
name: request-human-intervention
description: 任何 SubAgent 主动 raise 时调 — 写 pending_human/<slug>.md
allowed-tools: [Read, Write]
---

# request-human-intervention

## 你的输入

```json
{
  "slug": "<project-slug>",
  "reason_category": "auth_missing | stuck_repair_3x | resource_shortage | model_too_large | credential_needed | unknown_failure",
  "what_tried": ["..."],
  "what_blocked": "...",
  "next_steps_suggested": ["..."]
}
```

## 工作流

### 1. Write pending_human/<slug>.md

```markdown
# <slug> — 需要人手介入

**时间**:<ts>
**原因类别**:<reason_category>
**当前阶段**:<state.phase>

## 我尝试过什么
- <bullet>
- <bullet>

## 我被卡在哪
<具体描述>

## 建议人手做的事
- <bullet>
- <bullet>

## 上下文
- workspace: workspace/<slug>/
- trace: runs/<run-id>/
- state: <state.json 摘要>

---
处理完后**手动删除本文件** → 下次 cron 才会重新尝试
```

### 2. 更新 state.json

```bash
jq '.phase = "paused_for_human" | .pending_human = {reason: "<reason_category>", written_to: "pending_human/<slug>.md", ts: "'$(date -Iseconds)'"}' \
  "$WORKSPACE/state.json" > /tmp/state.json && mv /tmp/state.json "$WORKSPACE/state.json"
```

## 返回

```json
{
  "wrote_to": "pending_human/<slug>.md",
  "blocked": true
}
```
EOF
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/request-human-intervention.md
git commit -m "ai-auto: add request-human-intervention skill"
```

---

### Task 1.11: /auto-daily + /auto-status commands

**Files:**
- Create:`/root/ai-auto-harness/.claude/commands/auto-daily.md`
- Create:`/root/ai-auto-harness/.claude/commands/auto-status.md`

- [ ] **Step 1: /auto-daily**

```bash
mkdir -p /root/ai-auto-harness/.claude/commands
cat > /root/ai-auto-harness/.claude/commands/auto-daily.md <<'EOF'
---
description: AI Auto Harness 每日工作流入口 — cron 在 10:30 触发
---

调用 `daily-auto` skill。

按 `.claude/skills/ai-auto/daily-auto.md` 的 4 个任务执行:接续扫 → pick → dispatch 5 阶段 SubAgent → 写报告。
EOF
```

- [ ] **Step 2: /auto-status**

```bash
cat > /root/ai-auto-harness/.claude/commands/auto-status.md <<'EOF'
---
description: 看 workspace / pending_human / recent reports — 不跑 agent
---

显示当前平台状态:

1. `find workspace -maxdepth 2 -name state.json -exec jq -c '{slug, phase, updated_at}' {} \;`
2. `ls pending_human/*.md 2>/dev/null`
3. `ls -t reports/*.md 2>/dev/null | head -5`
4. `nvidia-smi --query-gpu=index,memory.used --format=csv,noheader`
5. `df -h /root`

总结一句给用户。
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/commands/auto-daily.md .claude/commands/auto-status.md
git commit -m "ai-auto: add /auto-daily and /auto-status slash commands"
```

---

### Task 1.12: cron daily.sh + crontab.example

**Files:**
- Create:`/root/ai-auto-harness/cron/daily.sh`
- Create:`/root/ai-auto-harness/cron/crontab.example`

- [ ] **Step 1: daily.sh**

```bash
mkdir -p /root/ai-auto-harness/cron
cat > /root/ai-auto-harness/cron/daily.sh <<'EOF'
#!/bin/bash
# AI Auto Harness — 每日 cron 入口(10:30 触发)
set -e
HARNESS_ROOT="/root/ai-auto-harness"
cd "$HARNESS_ROOT"

# 加载 .env 若有
[ -f .env ] && set -a && source .env && set +a

# 启动 claude-haha headless 跑 /auto-daily
LOG_DIR="$HARNESS_ROOT/runs/cron-$(date +%Y-%m-%d-%H%M)"
mkdir -p "$LOG_DIR"
./bin/claude-haha --print "/auto-daily" \
    > "$LOG_DIR/cron.out" 2> "$LOG_DIR/cron.err"
RET=$?

echo "exit=$RET" > "$LOG_DIR/cron.status"
exit $RET
EOF
chmod +x /root/ai-auto-harness/cron/daily.sh
```

- [ ] **Step 2: crontab.example**

```bash
cat > /root/ai-auto-harness/cron/crontab.example <<'EOF'
# 把这一行加到 root crontab(`crontab -e`):

30 10 * * * /root/ai-auto-harness/cron/daily.sh

# 验证:
#   crontab -l | grep ai-auto
#   tail -f /root/ai-auto-harness/runs/cron-*/cron.out
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add cron/daily.sh cron/crontab.example
git commit -m "ai-auto: add cron daily.sh entrypoint + crontab.example"
```

---

### Task 1.13: 端到端集成测试 — intake 跑通

**Files:**
- 无新文件,只是 manual run

- [ ] **Step 1: 准备一个测试 finding(模拟 scan 输出)**

```bash
mkdir -p /root/ai-daily-scan/state
cat > /root/ai-daily-scan/state/findings.jsonl <<'EOF'
{"slug":"song-generation","title":"SongGeneration","github_url":"https://github.com/tencent-ailab/SongGeneration","hf_repos":["tencent/SongGeneration"],"estimated_params_b":4,"estimated_weight_size_gb":15,"gated_repos":[],"scenario_hits":["scenario_005"],"recommended_route":"self_host_5090","next_action":"try_deploy_self_host","source_urls":["https://github.com/tencent-ailab/SongGeneration"],"confidence":"high","scan_ts":"2026-05-19T09:00:00","scan_report_path":"reports/2026-05-19_090001_report.md"}
EOF
```

- [ ] **Step 2: 跑 /auto-daily**

```bash
cd /root/ai-auto-harness
./bin/claude-haha --print "/auto-daily" 2>&1 | tee runs/manual-test.log
```

Expected:
- 看到 SessionStart hook 输出(findings、in-progress、resources)
- 主 agent 读 findings,pick `song-generation`
- dispatch intake SubAgent
- intake 跑通:`workspace/song-generation/repo/` 存在,`workspace/song-generation/state.json` 有 `phase: "fetching"` 和 `intake_result`

- [ ] **Step 3: 验证 workspace**

```bash
ls /root/ai-auto-harness/workspace/song-generation/
cat /root/ai-auto-harness/workspace/song-generation/state.json | jq
```

Expected:
- `repo/` 已 clone
- state.json `phase=fetching`,`intake_result.entry_script` 不为空,`intake_result.blocked=[]`

- [ ] **Step 4: 验证 trace 落盘**

```bash
RUN_ID=$(cat /root/ai-auto-harness/runs/.current_run_id)
ls /root/ai-auto-harness/runs/$RUN_ID/
wc -l /root/ai-auto-harness/runs/$RUN_ID/transcript.jsonl
```

Expected:transcript.jsonl 行数 > 0,intake.json 存在

- [ ] **Step 5: 清理这次测试**

```bash
rm -rf /root/ai-auto-harness/workspace/song-generation/
```

- [ ] **Step 6: Commit + Push**

```bash
cd /root/ai-auto-harness
# Phase 1 全部 push
git push origin main
echo "Phase 1 done. Milestone: intake works end-to-end."
```

---

## Phase 1 Milestone 验收

- [ ] `./bin/claude-haha --print "/auto-daily"` 能完整退出 0
- [ ] `workspace/<slug>/state.json` phase=fetching,intake_result 完整
- [ ] `runs/<run-id>/transcript.jsonl` 有内容
- [ ] git push 成功

---

## Phase 2: fetch + install + run-and-repair

**Milestone**:SongGeneration 项目能从 scan 候选 → SubAgent 2 拉权重(可能跨 cron 接续)→ SubAgent 3 装环境(含 sm_12 修复)→ SubAgent 4 跑通 entry_script 不超过 3 轮修复

---

### Task 2.1: state.json 接续模式 — daily-auto 完善

**Files:**
- Modify:`/root/ai-auto-harness/.claude/skills/ai-auto/daily-auto.md`

- [ ] **Step 1: 在 daily-auto skill 里完善 phase → SubAgent dispatch 逻辑**

读 daily-auto.md 现有"任务 3:部署流水线"部分,扩充为完整伪代码:

```markdown
### 任务 3:部署流水线(完整实现)

```bash
# 读 state
STATE="$WORKSPACE/state.json"
PHASE=$(jq -r .phase "$STATE")

case "$PHASE" in
  "intake"|"null"|null)
    # 没跑过 intake,先跑
    AGENT="intake"
    NEXT_PHASE="fetching"
    ;;
  "fetching")
    AGENT="fetch-weights"
    NEXT_PHASE="installing"
    ;;
  "installing")
    AGENT="install-env"
    NEXT_PHASE="running"
    ;;
  "running")
    AGENT="run-and-repair"
    NEXT_PHASE="verifying"
    ;;
  "verifying")
    AGENT="verify"
    NEXT_PHASE="done"
    ;;
  "done"|"paused_for_human")
    # 不应该 dispatch,直接进任务 4
    echo "phase=$PHASE, skipping to task 4"
    ;;
esac

# dispatch
RESULT=$(<dispatch SubAgent $AGENT 用 Task 工具>)
# 检查 RESULT.blocked 或 RESULT.paused_for_human
if [ "<blocked or paused>" ]; then
  # 跳到任务 4
  break
fi

# 更新 phase
jq '.phase = "'$NEXT_PHASE'" | .phases_done += ["'$AGENT'"] | .updated_at = "'$(date -Iseconds)'"' "$STATE" > /tmp/s && mv /tmp/s "$STATE"
# 回到 case,继续下一阶段
```
```

(实际上 CC agent 不会用 case bash,会用 LLM 推理 + Task tool dispatch — 但 skill 给出这个伪代码作为示意)

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/ai-auto/daily-auto.md
git commit -m "ai-auto: complete daily-auto phase dispatch logic"
```

---

### Task 2.2: fetch-agent + fetch-weights skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/agents/fetch-agent.md`
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/fetch-weights.md`

- [ ] **Step 1: fetch-agent.md**

```bash
cat > /root/ai-auto-harness/.claude/agents/fetch-agent.md <<'EOF'
---
name: fetch-agent
description: 拉 HF 权重 — background bash + BashOutput poll + 跨 cron 接续
allowed-tools: [Read, Write, Bash, BashOutput, KillBash]
---

# fetch-agent

你是 ai-auto-harness 的 fetch-weights SubAgent。

唯一会**长跑 + 跨 cron 周期**的 SubAgent。

## 你的约束

- 强制 HF_HOME 环境变量隔离(每个项目独立)
- 长任务必须 background bash(`run_in_background=true`)
- 周期 BashOutput poll,把进度摘录写 progress.md
- 卡死判定:`.incomplete` 30min 无增长 + stderr 30min 无新输出 → kill 重启 max 2 次
- 时间预算:超过 cron 周期 50 分钟还没全下完 → 不 kill,只更 state.json paused_in_progress=true 让下次 cron 接续
EOF
```

- [ ] **Step 2: fetch-weights skill** — 把 spec § 8 Skill 3 的完整工作流写进来

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/fetch-weights.md <<'EOF'
---
name: fetch-weights
description: 拉 HF 权重 — background bash + BashOutput poll + 跨 cron 接续
allowed-tools: [Read, Write, Bash, BashOutput, KillBash]
agent: fetch-agent
---

# fetch-weights

## 你的输入(主 agent 传入)

```json
{
  "slug": "<project-slug>",
  "hf_repos": ["..."],
  "gated_repos": ["..."],
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>"
}
```

## 硬约束:环境变量(任何 bash 命令都必须先 export)

```bash
export HF_HOME="$WORKSPACE/.cache/huggingface"
export HF_HUB_CACHE="$WORKSPACE/.cache/hf_hub"
export TRANSFORMERS_CACHE="$WORKSPACE/.cache/transformers"
```

## 工作流

### 1. 读 state.json,检查是否接续

```bash
DONE=$(jq -r '.fetch_state.weights_done // [] | .[]' "$WORKSPACE/state.json")
PENDING=$(jq -r '.fetch_state.weights_pending // [] | .[]' "$WORKSPACE/state.json")
BG_SHELLS=$(jq -r '.fetch_state.bg_shells // [] | .[]' "$WORKSPACE/state.json")
```

- 若 `bg_shells` 非空 → 用 BashOutput(shell_id) 看是否还活着
  - 活着 → 直接跳到 step 3(poll loop)
  - 死了 + 未完 → step 2 用 --resume-download 重启

### 2. 启动下载

对每个 PENDING repo:

```bash
setsid nohup huggingface-cli download \
    <repo> \
    --local-dir "$WORKSPACE/.cache/hf_models/<repo>" \
    --resume-download \
    > "$WORKSPACE/progress_<repo>.log" 2>&1 &
echo $! > "$WORKSPACE/.cache/<repo>.pid"
```

通过 CC 的 `Bash(run_in_background=true)`,记录 shell_id。

更新 state.json:

```bash
jq '.fetch_state.bg_shells += [{"id": "<shell_id>", "pid": <pid>, "repo": "<repo>", "started_at": "'$(date -Iseconds)'", "log_path": "progress_<repo>.log"}]' "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
```

### 3. Poll 循环(每 60-180s 一次)

```bash
# 用 BashOutput 工具(CC 原生)
# 或读 log 文件
tail -5 "$WORKSPACE/progress_<repo>.log"

# 检查磁盘
DISK_FREE=$(df -h "$WORKSPACE" | awk 'NR==2 {print $4}')
# 若 < 30GB → kill 全部 bg + report disk_low

# 检查 .incomplete 文件大小是否在增长
ls -la "$WORKSPACE/.cache/hf_models/<repo>"/*.incomplete 2>/dev/null
# 记录每次 size,30min 无变化 = 卡了
```

每次 poll 都写一行到 `$WORKSPACE/progress.md`:

```markdown
- 2026-05-19T10:42 — fetching FLUX.1-schnell: 12.3GB / 23GB (53%), incomplete file growing
```

### 4. 卡死判定

如果 `.incomplete` 30min 无增长 + log 30min 无新输出:
- KillBash + 删 `.incomplete` 文件
- 重启下载 max 2 次
- 仍卡 → blocked.append("download_stuck"),raise human

### 5. 时间预算

记录 SubAgent 开始时间(读 SessionStart 写的 run-id 反推)。

```bash
# 假设主 agent 跑了 50 分钟以上(估算)
ELAPSED=$(($(date +%s) - $(stat -c %Y "$WORKSPACE/state.json")))
PROGRESS=$(<估算>)  # 0-1
if [ $ELAPSED -gt 3000 ] && [ "$(echo "$PROGRESS < 0.8" | bc)" = "1" ]; then
    # 还没下完,但快超时了
    # 不 kill bg shell(让它继续在后台)
    # 更新 state.json paused_in_progress=true
    jq '.fetch_state.paused_in_progress = true' "$WORKSPACE/state.json" > /tmp/s && mv /tmp/s "$WORKSPACE/state.json"
    return {"weights_done": [...], "paused_in_progress": true}
fi
```

### 6. Gated 二次拦截

若运行时 401(intake 漏检了):
- KillBash
- 调 request-human-intervention skill
- return blocked

## 返回 schema

```json
{
  "weights_done": ["..."],
  "failed": [{"repo": "...", "error_class": "...", "msg": "..."}],
  "paused_in_progress": false,
  "bytes_total": 12345678901
}
```

## 反模式

- 不要用 `Bash(timeout=...)` — 长下载用 background,不用 timeout 兜底
- 不要 rm -rf .cache 重头来 — 会丢已下载部分
- 不要 wait 一个 bg shell — 用 BashOutput 周期 poll
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/agents/fetch-agent.md .claude/skills/ai-auto/fetch-weights.md
git commit -m "ai-auto: add fetch-agent + fetch-weights skill (背景下载 + 跨 cron 接续)"
```

---

### Task 2.3: memory/lessons 种子文件

**Files:**
- Create:`/root/ai-auto-harness/memory/lessons/torch-sm12.md`
- Create:`/root/ai-auto-harness/memory/lessons/hf-gated.md`
- Create:`/root/ai-auto-harness/memory/lessons/flash-attn-build.md`

- [ ] **Step 1: torch-sm12 lesson**

```bash
mkdir -p /root/ai-auto-harness/memory/lessons
cat > /root/ai-auto-harness/memory/lessons/torch-sm12.md <<'EOF'
# torch sm_12 兼容性(RTX 5090)

## 现象

- 装完 pip install torch 后跑模型,推理输出 NaN / inf / 全 0
- `python -c "import torch; print(torch.cuda.get_arch_list())"` 输出不含 `sm_120` 或 `compute_120`

## 根因

5090 是 sm_12.0(compute capability 12.0),许多 stable 版 torch wheel 没编译 sm_12 内核.
默认 stable channel(`pip install torch`)装 cu121 wheel,可能只到 sm_90 / sm_100.

## 修复(按优先级)

### 方案 A:nightly cu124 wheel
```bash
pip uninstall -y torch torchvision torchaudio
pip install --index-url https://download.pytorch.org/whl/nightly/cu124 \
    torch torchvision torchaudio
python -c "import torch; print(torch.cuda.get_arch_list())"
# 期望含 sm_120 或 compute_120
```

### 方案 B:cu126 stable wheel(2026-Q1 起)
```bash
pip uninstall -y torch
pip install --index-url https://download.pytorch.org/whl/cu126 torch
```

### 方案 C:源码编译(最后手段,慢)
```bash
TORCH_CUDA_ARCH_LIST="12.0" pip install torch --no-binary torch
```

## 验证

跑一个简单 GEMM:
```python
import torch
x = torch.randn(128, 128, device='cuda')
y = torch.randn(128, 128, device='cuda')
z = x @ y
print(z.mean().item())  # 应该是个合理数字,不是 NaN/0
```
EOF
```

- [ ] **Step 2: hf-gated lesson**

```bash
cat > /root/ai-auto-harness/memory/lessons/hf-gated.md <<'EOF'
# HuggingFace Gated Repo 处理

## 现象

- `huggingface-cli download <repo>` 返回 401 Unauthorized
- 或 web 上看 repo 顶部有 "You need to accept terms of use" 横幅

## 探测方法

```bash
curl -s "https://huggingface.co/api/models/<repo>" | jq -r '.gated'
# manual / auto = gated; false / null = 公开
```

## 已知 gated repo 列表(平台 cache)

- `black-forest-labs/FLUX.1-schnell` — manual,需要网页同意 + HF_TOKEN
- `meta-llama/*` — manual
- `mistralai/*`(部分)— manual
- `stabilityai/stable-diffusion-3-medium` — manual

## 处理

1. 检查 `$HF_TOKEN` 是否设置
2. 没 token → 写 pending_human:"需要去 https://huggingface.co/<repo> 网页同意 license,然后到 https://huggingface.co/settings/tokens 创建一个 read token,并 export HF_TOKEN=hf_xxx"
3. 有 token → 试 `huggingface-cli download <repo> README.md --quiet`(下个小文件 smoke test)
4. 仍 401 → 大概率是 license 未同意(token 有效但权限缺)→ 写 pending_human 说明需要同意 license
EOF
```

- [ ] **Step 3: flash-attn-build lesson**

```bash
cat > /root/ai-auto-harness/memory/lessons/flash-attn-build.md <<'EOF'
# flash-attn 编译失败

## 现象

- `pip install flash-attn` 编译几十分钟后失败
- 常见错误:nvcc not found / unsupported arch sm_120 / OOM during build

## 修复

### 方案 A:prebuilt wheel(推荐)

```bash
# 找匹配 torch / python / cuda 版本的 wheel
# https://github.com/Dao-AILab/flash-attention/releases
wget https://github.com/Dao-AILab/flash-attention/releases/download/v<ver>/flash_attn-<ver>+cu126torch<x>cxx11abiFALSE-cp310-cp310-linux_x86_64.whl
pip install flash_attn-<ver>+cu126torch<x>cxx11abiFALSE-cp310-cp310-linux_x86_64.whl
```

### 方案 B:容忍缺 flash-attn

部分项目支持 fallback 到 PyTorch native attention(慢但能跑)。
读项目 README / config 看有没有 `--no-flash-attn` 之类的 flag。

### 方案 C:容忍 sm_12 不支持

flash-attn v2.x 对 sm_12 支持还在迭代。可以:
- 退到 v2.5.x 不带 sm_12 优化(性能差但能跑)
- 等 flash-attn v3 完整支持

## 注意

不装 flash-attn 通常推理慢 2-5x,但**不是必须**.
若 entry_script 直接死在 `from flash_attn import ...` import error → 找代码改成 try/except fallback.
EOF
```

- [ ] **Step 4: Commit**

```bash
cd /root/ai-auto-harness
git add memory/lessons/
git commit -m "ai-auto: add seed lessons (torch-sm12 / hf-gated / flash-attn-build)"
```

---

### Task 2.4: install-agent + install-env skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/agents/install-agent.md`
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/install-env.md`

- [ ] **Step 1: install-agent.md**

```bash
cat > /root/ai-auto-harness/.claude/agents/install-agent.md <<'EOF'
---
name: install-agent
description: venv + pip + torch sm_12 + 常见 build issue 修复
allowed-tools: [Read, Write, Edit, Bash, Grep]
---

# install-agent

你是 ai-auto-harness 的 install-env SubAgent。

读 memory/lessons/*.md 获取经验(尤其 torch-sm12.md, flash-attn-build.md)。
EOF
```

- [ ] **Step 2: install-env skill(完整工作流参考 spec § 8 Skill 4)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/install-env.md <<'EOF'
---
name: install-env
description: venv + pip + torch sm_12 检测/修复 + 常见 build issue
allowed-tools: [Read, Write, Edit, Bash, Grep]
agent: install-agent
---

# install-env

## 你的输入

```json
{
  "slug": "...",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "entry_script": "...",
  "requirements_files": ["requirements.txt", "..."]
}
```

## 工作流

### 1. 创建 venv

```bash
python -m venv "$WORKSPACE/venv"
source "$WORKSPACE/venv/bin/activate"
```

### 2. 升级核心工具

```bash
pip install --upgrade pip setuptools wheel
```

### 3. 装项目依赖(优先级)

```bash
cd "$WORKSPACE/repo"
if [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    pip install -e .
elif [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    # 看 README quickstart 里有没有 pip install 命令
    grep -A 3 "pip install" README.md | head -20
    # 手动抄出来执行
fi
```

### 4. torch sm_12 检测(5090 必做)

```bash
python -c "import torch; archs = torch.cuda.get_arch_list(); print('archs:', archs); sm12 = any('120' in a or '12.0' in a for a in archs); print('sm_12_ok:', sm12); exit(0 if sm12 else 1)"
```

不通过 → 读 `memory/lessons/torch-sm12.md` 跑 nightly cu124 方案。

最多 3 次重装尝试,仍不行 → blocked.append("torch_sm12_unavailable")

### 5. 常见 build issue 修复

读 `memory/lessons/flash-attn-build.md`, `memory/lessons/...` 看是否有匹配的现象。

### 6. 验证 entry_script 至少能 import

```bash
cd "$WORKSPACE/repo"
python -c "<from entry_script 推断的 import>" 2>&1 | head -20
```

失败 → 看 stderr 缺什么 module → pip install 补

### 7. 写 memory/projects/<slug>.md(若做了非常规修复)

```markdown
# <slug> install 经验

- 装了 nightly cu124 torch(默认 stable 不支持 sm_12)
- flash-attn 装失败,跳过(项目支持 fallback)
- ...
```

## 返回 schema

```json
{
  "venv_path": "$WORKSPACE/venv",
  "deps_ok": true,
  "fixes_applied": ["torch_nightly_cu124", "skip_flash_attn"],
  "warnings": []
}
```
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/agents/install-agent.md .claude/skills/ai-auto/install-env.md
git commit -m "ai-auto: add install-agent + install-env skill (torch sm_12 修复 + build issue)"
```

---

### Task 2.5: runner-agent + run-and-repair skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/agents/runner-agent.md`
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/run-and-repair.md`

- [ ] **Step 1: runner-agent**

```bash
cat > /root/ai-auto-harness/.claude/agents/runner-agent.md <<'EOF'
---
name: runner-agent
description: 试跑 entry_script + 修复循环 — CC agent loop 替代 Python repair_loop
allowed-tools: [Read, Write, Edit, Bash, BashOutput, Grep]
---

# runner-agent

替代 auto-deploy-agent/modules/runner/repair_loop.py 的 5 轮循环.
你**就是** repair loop — CC agent loop 的每一轮 ToolUse 就是一轮"观察→决策→执行→验收".

## 上限

最多 3 轮决策(LLM 修复尝试),不收敛即调 request-human-intervention。
不要硬试第 4 轮。
EOF
```

- [ ] **Step 2: run-and-repair skill(参考 spec § 8 Skill 5)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/run-and-repair.md <<'EOF'
---
name: run-and-repair
description: 试跑 entry_script 并修复失败 — CC agent loop 替代 Python repair_loop
allowed-tools: [Read, Write, Edit, Bash, BashOutput, Grep]
agent: runner-agent
---

# run-and-repair

## 你的输入

```json
{
  "slug": "...",
  "workspace_path": "/root/ai-auto-harness/workspace/<slug>",
  "venv_path": "...",
  "entry_script": "...",
  "gpu_picks": [3, 4]
}
```

## 工作流

### 0. 设置环境

```bash
source "$VENV_PATH/bin/activate"
export CUDA_VISIBLE_DEVICES="$(echo ${GPU_PICKS[@]} | tr ' ' ',')"
export HF_HOME="$WORKSPACE/.cache/huggingface"  # 与 fetch 一致
```

### 1. 试跑(每轮先做)

短任务 → 同步 bash(timeout 600s)
长任务(模型推理可能慢)→ background bash + BashOutput poll

```bash
cd "$WORKSPACE/repo"
$ENTRY_SCRIPT > "$WORKSPACE/run.log" 2>&1
```

### 2. 观察(必须每轮做)

```bash
tail -50 "$WORKSPACE/run.log"
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader
ls -la "$WORKSPACE/repo/"  # 看预期输出文件
echo "exit_code=$?"
```

### 3. 决策(LLM 判断)

**退出码 = 0 且预期文件存在** → 成功,返回 RunResult passed=true.

**退出码 != 0** → 看 stderr root cause:

常见模式(读 memory/lessons/*.md 找类似):
- "CUDA out of memory" → 换更小 batch / quantization / 换 GPU
- "No module named X" → pip install X
- "RuntimeError: nan" + 5090 → sm_12 wheel 问题(应 install 阶段已修,这里 double check)
- "401" / "Unauthorized" → gated(应 intake preflight,double check)
- exit_code = -15 (SIGTERM) → 超时被杀(看是不是在下载而非真跑)
- exit_code = -9 (SIGKILL) → 内存不足或 OOMKiller
- exit_code = 137 → OOMKill (cgroup)

**卡死**(stdout/stderr 30min 无变化 + GPU 利用率 0%):
- 看 workspace `.incomplete` 是否还在(还在 = 还在下载 → fetch 漏拉,kill + 重 fetch)
- 看 `import torch` 是否在 stack(可能 import 慢)
- 真死 → kill 重启 OR 调环境变量

### 4. 修复

- 修代码:`Edit "$WORKSPACE/repo/<file>"`
- 修环境:`export NEW_VAR=...` + 同步写 state.env_overrides
- 修配置:`Edit "$WORKSPACE/repo/configs/<yaml>"`

每个修复都 Write 一条到 `runs/<run-id>/decisions.md`:
```markdown
- 2026-05-19T11:20 by runner-agent: 检测到 CUDA OOM,把 batch_size 从 4 改成 1,期望重跑通过
```

### 5. 验收

重跑 → 回到 step 1.

**最多 3 轮决策**.第 3 轮仍未收敛 → 调 **request-human-intervention** skill,reason_category="stuck_repair_3x",列出 3 轮 fixes_applied + 最终 error。

不要硬试第 4 轮.

## 强制要求

- 任何 Edit 修代码 → 必须先 Read 原内容 + 写 decisions.md
- 任何环境变量改动 → 写 state.json env_overrides
- 任何卸装新包 → 追加到 memory/projects/<slug>.md fixes_applied

## 返回 schema

```json
{
  "passed": true,
  "error_class": null,
  "repair_count": 1,
  "stdout_tail": "<last 50 lines>",
  "gpu_snapshot": {"memory_used_mb": 18432, "utilization_pct": 87, "processes": 1},
  "fixes_applied": ["batch_size_1"],
  "post_conditions_met": {"output_file_exists": true, "valid_format": true}
}
```
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/agents/runner-agent.md .claude/skills/ai-auto/run-and-repair.md
git commit -m "ai-auto: add runner-agent + run-and-repair skill (CC agent loop 替代 repair_loop)"
```

---

### Task 2.6: 集成测试 — SongGeneration 部署到 run 通过

**Files:**
- 无新文件

- [ ] **Step 1: 准备 finding**(同 Task 1.13 那个 SongGeneration)

```bash
# 若上次测试清了,重新写
cat > /root/ai-daily-scan/state/findings.jsonl <<'EOF'
{"slug":"song-generation","title":"SongGeneration","github_url":"https://github.com/tencent-ailab/SongGeneration","hf_repos":["tencent/SongGeneration"],"estimated_params_b":4,"estimated_weight_size_gb":15,"gated_repos":[],"scenario_hits":["scenario_005"],"recommended_route":"self_host_5090","next_action":"try_deploy_self_host","source_urls":["https://github.com/tencent-ailab/SongGeneration"],"confidence":"high","scan_ts":"2026-05-19T09:00:00","scan_report_path":"reports/2026-05-19_090001_report.md"}
EOF
```

- [ ] **Step 2: 跑完整流水线(只到 run)**

```bash
cd /root/ai-auto-harness
./bin/claude-haha --print "/auto-daily" 2>&1 | tee runs/song-gen-full.log
```

预期会执行:intake → fetch-weights → install-env → run-and-repair

预期时间:30-90 分钟(权重下载 ~15GB)

可能跨 cron 接续(若实验 R2 ✅):一次跑不完没关系,记录 state 即可,重跑 `/auto-daily` 应该接续。

- [ ] **Step 3: 验证最终状态**

```bash
cat /root/ai-auto-harness/workspace/song-generation/state.json | jq
```

Expected:
- `phase` 至少进到 `verifying` 或 `running`
- `run_result.passed=true` 若全跑通

- [ ] **Step 4: Commit + Push 此次进展**

```bash
cd /root/ai-auto-harness
git add memory/projects/ 2>/dev/null || true  # 若 runner 写了项目经验
git commit -m "Phase 2 milestone: SongGeneration deploy-to-run pipeline verified" --allow-empty
git push origin main
```

---

## Phase 2 Milestone 验收

- [ ] 跑通 `/auto-daily` 完整经过 fetch → install → run-and-repair 三阶段
- [ ] 至少一个项目 `state.phase` 进到 `running` 或 `verifying`,`run_result.passed=true`
- [ ] `runs/<run-id>/{intake,fetch,install,run}.json` 都有内容
- [ ] 若 R2 实验 ✅,验证过一次跨 cron 接续(手动 kill CC 中途,重新跑)

---

## Phase 3: verify + api-skeleton + human + 报告(MVP)

**Milestone**:完整 MVP — 5 阶段都跑通,SongGeneration verify=true,`reports/<date>.md` 生成,MCP `record_outcome` 回填 ai-daily-scan/state/outcomes.jsonl

---

### Task 3.1: verify-agent + verify skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/agents/verify-agent.md`
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/verify.md`

- [ ] **Step 1: verify-agent — 限工具集只读**

```bash
cat > /root/ai-auto-harness/.claude/agents/verify-agent.md <<'EOF'
---
name: verify-agent
description: 独立判定项目是否真能跑 — 不读 run-and-repair 修复历史
allowed-tools: [Read, Bash]
---

# verify-agent

你是 ai-auto-harness 的 verify SubAgent。**只判定不修复**.

工具集**只有** Read + Bash.没有 Edit / Write 工具,这是故意的 — 防止你下意识"顺手修一下"。

## 独立判定原则

你**不读** `workspace/<slug>/state.json` 的 `run_result` 字段。
你**不读** `runs/<run-id>/run.json`。
你**不读** `runs/<run-id>/decisions.md` 里 SubAgent 4 的修复历史。

你像一个"刚拿到这个 workspace 的新工程师",从零开始验证它能不能跑。
EOF
```

- [ ] **Step 2: verify skill(参考 spec § 8 Skill 6)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/verify.md <<'EOF'
---
name: verify
description: 独立判定项目是否真能跑 — 不读 SubAgent 4 历史
allowed-tools: [Read, Bash]
agent: verify-agent
---

# verify

## 你的输入

```json
{
  "slug": "...",
  "workspace_path": "...",
  "venv_path": "...",
  "entry_script": "..."
}
```

**注意:你不会拿到 RunResult,也不应该读 state.json 的 run_result 字段.**

## 工作流

### 1. 启动检查(冷启动一次)

```bash
source "$VENV_PATH/bin/activate"
$ENTRY_SCRIPT --help 2>&1 | head -20
# 或:python -c "<from entry_script 推断的顶层 import>"
```

退出码 = 0 → 启动 OK.

### 2. 功能检查(smoke test)

读 `$WORKSPACE/repo/README.md` 找最小 demo 命令.

```bash
cd "$WORKSPACE/repo"
<smoke_cmd> 2>&1 | tail -50
```

输出合理性:
- 文本模型:输出是连贯的(不是随机 token / 全 0 / 重复字符)
- 图像模型:输出文件大小合理(几百 KB 到几 MB)
- 视频模型:`ffmpeg -i out.mp4 2>&1 | grep "Stream"` 能读出 video stream
- 音频模型:文件有正确采样率/时长

### 3. GPU 利用率检查

推理跑时另一个 bash:

```bash
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader -l 2 | head -3
```

- GPU 占用必须 > 1GB(否则是 CPU fallback)
- 利用率必须 > 10%(否则没真在跑)

### 4. 判定

- 三步都通过 → `passed=true`
- 任一失败 → `passed=false, failed_at=<step>`

## 返回 schema

```json
{
  "passed": true,
  "failed_at": null,
  "evidence": {
    "stdout_snippet": "...",
    "gpu_stats": {"memory_used_mb": 18432, "utilization_pct": 87},
    "output_files": ["out.mp3"]
  },
  "notes": "smoke test 生成 5s 音频文件,GPU 87% 利用率正常"
}
```

## 反模式

- 不要修代码(没 Edit 工具,会失败)
- 不要怪 SubAgent 4
- 不要假设 entry_script 一定能跑
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/agents/verify-agent.md .claude/skills/ai-auto/verify.md
git commit -m "ai-auto: add verify-agent + verify skill (独立判定 Read+Bash only)"
```

---

### Task 3.2: api-skeleton skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/api-skeleton.md`

- [ ] **Step 1: 写 skill(参考 spec § 8 Skill 7)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/api-skeleton.md <<'EOF'
---
name: api-skeleton
description: 不能 self-host 时(>30B / gated 无 token / 资源不足)产 API 骨架
allowed-tools: [Read, Write]
---

# api-skeleton

## 触发条件

主 agent 在以下情况调你:
- `estimated_params_b > 30`(模型太大)
- intake 返回 `blocked=["gated_no_token"]`(短期不可解决)
- 资源短期不足

## 你的输入

```json
{
  "slug": "...",
  "github_url": "...",
  "hf_repos": ["..."],
  "scan_finding": {...}  // 含 cost_estimate 字段
}
```

## 产物(写到 workspace/<slug>/api_skeleton/)

### client.py

最小可调用 HTTP client.

```python
"""<slug> — API client"""
import os
import httpx

class <SlugCamelCase>Client:
    def __init__(self, api_key: str = None, base_url: str = None):
        self.api_key = api_key or os.environ["<SLUG_UPPER>_API_KEY"]
        self.base_url = base_url or "<API endpoint>"

    def generate(self, prompt: str, **kwargs) -> dict:
        response = httpx.post(
            f"{self.base_url}/v1/<endpoint>",
            headers={"Authorization": f"Bearer {self.api_key}"},
            json={"prompt": prompt, **kwargs},
            timeout=60.0,
        )
        response.raise_for_status()
        return response.json()
```

API endpoint 优先级:
1. 项目官方 API(scan_finding 里若提到)
2. HuggingFace Inference API
3. OpenRouter / Together / WaveSpeed 等第三方

### smoke_test.py

```python
"""smoke test — 最小调用验证"""
from client import <SlugCamelCase>Client

client = <SlugCamelCase>Client()
result = client.generate(prompt="<minimal test prompt>")
print(result)
```

### .env.example

```bash
<SLUG_UPPER>_API_KEY=  # 在 <provider> 控制台获取
```

### 使用指导.md(中文)

```markdown
# <项目名> API 路线使用指导

## 项目简介

<从 scan_finding 抄一段>

## 为什么走 API 而非自部署

<以下二选一>

### 模型规模 > 30B 阈值
项目模型参数量 X B,超过本平台 self-host 阈值 30B.
自部署需要 N 张 5090 分片,GPU 成本 ~$X/月.
API 路线成本 ~$Y/月(基于 scan 估算),性价比明显占优.

### Gated repo 需要人工授权
项目使用 gated repo <repo>,需要:
1. 在 https://huggingface.co/<repo> 网页同意 license
2. 在 https://huggingface.co/settings/tokens 创建 read token
3. export HF_TOKEN=hf_xxx

完成后可重新跑 /auto-deploy <github_url> 尝试 self-host;或继续 API 路线.

## 注册 + 拿 API key

<provider 具体步骤,含链接>

## 配置

```bash
cp .env.example .env
# 编辑 .env,填入 API_KEY
```

## 跑 smoke test

```bash
pip install httpx
python smoke_test.py
```

## 双路成本对比

| 路线 | 月度估算 | 优点 | 缺点 |
|---|---|---|---|
| API | ¥X | 即开即用,无运维 | 单次调用 ~$Y,QPS 受限 |
| Self-host | ¥Z | 单次成本低,无限并发 | 需 N 卡 + 运维 |

## 上线建议

- 灰度:接 1 个产品 / 1% 流量
- 监控:QPS / latency / error_rate
- 降级:同 vendor 平替(<list>)+ 切回 self-host 的预案
```

## 返回 schema

```json
{
  "skeleton_path": "/root/ai-auto-harness/workspace/<slug>/api_skeleton",
  "ready": true,
  "api_route_chosen": "official | hf_inference | openrouter | ..."
}
```
EOF
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/api-skeleton.md
git commit -m "ai-auto: add api-skeleton skill (失败转骨架 + 中文使用指导)"
```

---

### Task 3.3: write-recommendation skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/write-recommendation.md`

- [ ] **Step 1: 写 skill(参考 spec § 8 Skill 12 + report template)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/write-recommendation.md <<'EOF'
---
name: write-recommendation
description: 主 agent 写每日总报告 + 调 MCP record_outcome
allowed-tools: [Read, Write, Bash, mcp__ai_daily_scan__record_outcome]
---

# write-recommendation

## 你的输入

```json
{
  "run_results": [
    {"slug": "...", "status": "passed|failed|paused_for_human|api_route",
     "run_result": {...}, "verify_state": {...},
     "intake_result": {...}, "scan_finding": {...}}
  ],
  "pending_human_files": ["pending_human/x.md", ...],
  "resource_snapshot": {"gpu_status": "...", "disk_free_gb": 459}
}
```

## 渲染 reports/<YYYY-MM-DD>.md

覆写(单天可多次 cron 重跑).Template:

```markdown
# AI Auto 报告 — <date>

> 生成时间:<ts>
> Run IDs:<list>

## 总览

- 今日处理项目:<n_total>
- 成功 self-host:<n_pass> / API 路线:<n_api> / 失败:<n_fail> / 待人手处理:<n_human>
- GPU 状况:<8 卡中 N 卡可用>
- 磁盘 free:<gb> GB <若 < 100 标 ⚠️>

## 今日处理项目详情

### <slug> — <title>

- **路径**:self_host_5090 | api_pilot
- **结果**:✅ PASS / ❌ FAILED / ⏸️ PAUSED_FOR_HUMAN
- **阶段进展**:intake ✅ / fetch ✅ / install ✅ / run ⚠️ / verify ❌
- **公司视角**:命中 <scenario_hits>,推荐试点 <pilot_product>,验收指标 <metrics>
- **修复轨迹**:<fixes_applied 摘要>
- **GPU 利用**:<gpu_snapshot 摘要>(若已跑通)
- **报告**:[runs/<run-id>/](runs/<run-id>/)
- (若 FAILED)**失败原因**:<error_class>
- (若 PAUSED)**待人手**:[pending_human/<slug>.md](pending_human/<slug>.md)

## 待人手处理积压

| Slug | 类别 | 卡了几天 | 文件 |
|---|---|---|---|
| <slug> | <category> | <days> | [link](pending_human/<slug>.md) |

## 跨日盲区(coverage-gaps 输出,Phase 4 加)

(MVP 阶段先留空,Phase 4 调 coverage-gaps skill 填)

## 下一步建议

<LLM 主动写,基于以上结果>

## 资源 Alert

- 磁盘 free <X> GB<若 < 100>:建议清理:
  - `/root/core.*`(若仍有)
  - workspace 中 7 天前的项目

---
*生成依赖:claudecode_sourcecode1 + ai-daily-scan MCP*
```

## 回填

```python
for slug, result in run_results.items():
    mcp__ai_daily_scan__record_outcome(
        slug=slug,
        status=result["status"],
        error_class=result.get("error_class"),
        phase_failed_at=result.get("phase_failed_at"),
        notes=result.get("notes"),
        run_id=os.environ["RUN_ID"],
        repair_count=result.get("repair_count", 0),
    )
```

## 返回

```json
{
  "report_path": "reports/2026-05-19.md",
  "outcomes_recorded": <n>
}
```
EOF
```

- [ ] **Step 2: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/write-recommendation.md
git commit -m "ai-auto: add write-recommendation skill (报告渲染 + record_outcome 回填)"
```

---

### Task 3.4: 剩余 commands(/auto-deploy + /auto-recover)

**Files:**
- Create:`/root/ai-auto-harness/.claude/commands/auto-deploy.md`
- Create:`/root/ai-auto-harness/.claude/commands/auto-recover.md`

- [ ] **Step 1: /auto-deploy <github_url>**

```bash
cat > /root/ai-auto-harness/.claude/commands/auto-deploy.md <<'EOF'
---
description: 手动跑单项目部署 — 跳过 scan pick,直接对指定 URL 部署
---

参数:`$ARGUMENTS`(一个 github URL)

工作流:
1. 调 `mcp__ai_daily_scan__analyze_project(url=$ARGUMENTS)` 拿到 Finding
2. 检查 30B 阈值:
   - estimated_params_b > 30 → dispatch api-skeleton skill,跳过 deploy 流水线
   - 否则 → 写 workspace/<slug>/state.json,进入 5 阶段流水线(走 daily-auto 任务 3)
3. 完成后写报告
EOF
```

- [ ] **Step 2: /auto-recover**

```bash
cat > /root/ai-auto-harness/.claude/commands/auto-recover.md <<'EOF'
---
description: 强制扫接续 — 忽略 scan,只把 in_progress 项目跑完
---

工作流:
1. 扫 workspace/*/state.json,列出 phase ∉ {done, paused_for_human}
2. 选最早 started_at 的接续
3. 按 state.phase dispatch 对应 SubAgent
4. 完成或 raise → 写报告
5. 不调 scan_today,不挑新项目
EOF
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/commands/auto-deploy.md .claude/commands/auto-recover.md
git commit -m "ai-auto: add /auto-deploy and /auto-recover slash commands"
```

---

### Task 3.5: L2 集成测试 — MVP 端到端

**Files:** 无新文件

- [ ] **Step 1: 准备 finding**(SongGeneration 已经跑过,重新跑完整 5 阶段)

```bash
rm -rf /root/ai-auto-harness/workspace/song-generation
cat > /root/ai-daily-scan/state/findings.jsonl <<'EOF'
{"slug":"song-generation","title":"SongGeneration","github_url":"https://github.com/tencent-ailab/SongGeneration","hf_repos":["tencent/SongGeneration"],"estimated_params_b":4,"estimated_weight_size_gb":15,"gated_repos":[],"scenario_hits":["scenario_005"],"recommended_route":"self_host_5090","next_action":"try_deploy_self_host","source_urls":["https://github.com/tencent-ailab/SongGeneration"],"confidence":"high","scan_ts":"2026-05-19T09:00:00","scan_report_path":"reports/2026-05-19_090001_report.md"}
EOF
```

- [ ] **Step 2: 跑完整 /auto-daily**

```bash
cd /root/ai-auto-harness
./bin/claude-haha --print "/auto-daily" 2>&1 | tee runs/L2-test.log
```

可能跨多次 cron 才完成(取决于权重下载时间和 R3 实验结论).

- [ ] **Step 3: 完成后验证**

```bash
cat /root/ai-auto-harness/workspace/song-generation/state.json | jq '.phase, .phases_done'
# 期望: phase = "archived", phases_done = ["intake","fetch-weights","install-env","run-and-repair","verify","runbook","cleanup"]
# 注: 原 L2 期望 phase="done" 和 5 阶段,2026-06-05 toonflow-app e2e 已验证实际为 7 阶段 + archived 终态

ls /root/ai-auto-harness/reports/
# 应该看到 2026-05-19.md (或当天日期)

cat /root/ai-auto-harness/reports/$(ls -t reports/ | head -1) | head -30

cat /root/ai-daily-scan/state/outcomes.jsonl
# 应该看到 song-generation status=passed
```

- [ ] **Step 4: Commit MVP 完成**

```bash
cd /root/ai-auto-harness
git add memory/projects/ reports/ 2>/dev/null || true
git commit -m "MVP milestone: SongGeneration 5-stage pipeline + report + record_outcome" --allow-empty
git push origin main
```

---

### Task 3.6: L3 Chaos 测试

**Files:** 
- Create:`/root/ai-auto-harness/experiments/L3-chaos-scenarios.md`

- [ ] **Step 1: 写 chaos 实验剧本**

```bash
cat > /root/ai-auto-harness/experiments/L3-chaos-scenarios.md <<'EOF'
# L3 Chaos 测试

模拟 4 类异常场景,验证 agent 是否触发 `pending_human/`。

## Scenario 1: 磁盘满

```bash
# 占满磁盘到 < 20GB
sudo dd if=/dev/zero of=/root/fake_full bs=1M count=$(($(df -m /root | awk 'NR==2 {print $4}') - 20000)) 2>/dev/null
df -h /root
# 跑 /auto-deploy 一个 30GB 项目
cd /root/ai-auto-harness && ./bin/claude-haha --print "/auto-deploy https://github.com/black-forest-labs/flux"
# 期望:intake preflight 返回 blocked=["disk_low"],写 pending_human
ls pending_human/flux.md
# 清理
rm /root/fake_full
```

## Scenario 2: GPU 占满

```bash
# 起一个 dummy CUDA load 占满某张卡 30GB
python -c "
import torch
x = torch.zeros((30 * 1024**3 // 4,), device='cuda:0', dtype=torch.float32)
import time; time.sleep(99999)
" &
DUMMY_PID=$!

# 跑 /auto-deploy
cd /root/ai-auto-harness && ./bin/claude-haha --print "/auto-deploy https://github.com/x/y"
# 期望:intake gpu_picks 排除了 GPU 0,选其他卡

kill $DUMMY_PID
```

## Scenario 3: HF Gated 无 token

```bash
unset HF_TOKEN
cd /root/ai-auto-harness && ./bin/claude-haha --print "/auto-deploy https://github.com/black-forest-labs/flux"
# 期望:intake 探测到 gated_repo,blocked=["gated_no_token"]
# pending_human/flux.md 给出获取 token 步骤指引
```

## Scenario 4: torch sm_12 不兼容

```bash
# 故意先装 cu118 torch(不支持 sm_12)
python -m venv /tmp/sm12-test-venv
source /tmp/sm12-test-venv/bin/activate
pip install torch --index-url https://download.pytorch.org/whl/cu118
# 通过修改 scenario 强制走这个 venv …

# 实施时:
# 跑某项目,看 install-env 是否自动 fallback 到 nightly cu124
```

## 验收

- 每个 scenario 都能正确触发 pending_human 或 blocked
- agent 不会硬试导致 wedged 状态
- 报告里 "待人手处理" 段正确列出
EOF
```

- [ ] **Step 2: 跑 Scenario 1 + 3(2 和 4 较费时,选作)**

```bash
# 按上述步骤逐个跑
echo "manual chaos testing"
```

- [ ] **Step 3: Commit**

```bash
git add experiments/L3-chaos-scenarios.md
git commit -m "ai-auto: add L3 chaos test scenarios"
```

---

### Task 3.7: 部署 cron

**Files:**
- 用户操作:crontab

- [ ] **Step 1: 安装 crontab**

```bash
crontab -e
# 加入:
# 30 10 * * * /root/ai-auto-harness/cron/daily.sh
```

- [ ] **Step 2: 验证 crontab**

```bash
crontab -l | grep auto-harness
```

- [ ] **Step 3: 等一天看效果(或手动 trigger 一次)**

```bash
# 不等,手动 trigger:
bash /root/ai-auto-harness/cron/daily.sh
# 看 runs/cron-*/cron.out
tail -50 /root/ai-auto-harness/runs/cron-*/cron.out | head -50
```

- [ ] **Step 4: Commit**(不需要,crontab 是 system level)

---

## Phase 3 Milestone 验收

- [ ] L2 集成:SongGeneration 5 阶段全过,reports/<date>.md 生成,outcomes.jsonl 有 status=passed
- [ ] L3 chaos:至少 scenario 1 + 3 跑过,pending_human 触发正确
- [ ] crontab 已部署
- [ ] git push 完成

**MVP 完成 🎉**

---

## Phase 4: 借鉴 skill + memory 完善

**Milestone**:借鉴 ai-daily-scan 的 3 个 skill 集成进报告流程;auto-deploy-agent README 加 deprecated;memory/lessons 有 agent 自主写入机制

---

### Task 4.1: verifier-corrector skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/verifier-corrector.md`

- [ ] **Step 1: 写 skill(参考 ai-daily-scan 的 verifier+corrector 模式)**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/verifier-corrector.md <<'EOF'
---
name: verifier-corrector
description: 写完报告后做事实核验 + 把 ❌ 声明回写正文(借鉴 ai-daily-scan)
---

# verifier-corrector

## 触发

主 agent 调 write-recommendation 写完报告后,触发本 skill 做一次 sanity check.

## 工作流

### 1. 抽报告里的关键声明

- 数字(成本估算 / 显存占用 / 推理速度等)
- URL(github / huggingface 链接)
- API 定价(若 api-skeleton 提到)

### 2. 独立核验

对每个 URL,curl 验证存在性.对每个数字,看是否与 scan_finding / runs/<id>/verify.json 一致.

### 3. 回写

任何 ❌ 的声明 → Edit 报告改正,在末尾加一段:

```markdown
## 报告自检

| 状态 | 声明 | 修正 |
|---|---|---|
| ❌→✅ | "推理速度 50 tok/s" | 实测 27 tok/s(verify.json),已改 |
```
EOF
```

- [ ] **Step 2: 在 write-recommendation skill 末尾加触发段**

读 `/root/ai-auto-harness/.claude/skills/ai-auto/write-recommendation.md`,在 "## 回填" 之前加:

```markdown
## 报告自检(可选,Phase 4 加)

写完报告后,调用 **verifier-corrector** skill 做一次事实核验,把 ❌ 声明回写到报告.
```

- [ ] **Step 3: Commit**

```bash
cd /root/ai-auto-harness
git add .claude/skills/ai-auto/verifier-corrector.md .claude/skills/ai-auto/write-recommendation.md
git commit -m "ai-auto: add verifier-corrector skill (借鉴 ai-daily-scan)"
```

---

### Task 4.2: coverage-gaps skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/coverage-gaps.md`

- [ ] **Step 1: 写 skill**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/coverage-gaps.md <<'EOF'
---
name: coverage-gaps
description: 跨日盲区追踪 — 近 N 天哪些 scenario 0 次成功部署
allowed-tools: [Read, Bash, mcp__ai_daily_scan__*]
---

# coverage-gaps

## 触发

write-recommendation 调,产出报告 "## 跨日盲区" 段内容.

## 工作流

### 1. 读最近 N 天 outcomes

```python
outcomes = mcp__ai_daily_scan__get_recent_findings(days=7)  # findings, 用来看 scenario 分布
# + 读 outcomes.jsonl 看 deploy 结果
```

### 2. 统计 scenario 命中

```python
from collections import Counter
scenario_deploys = Counter()
for finding in outcomes:
    if finding.get("status") == "passed":
        for scenario in finding.get("scenario_hits", []):
            scenario_deploys[scenario] += 1
```

### 3. 找 0 命中的 scenario

公司 7 业务线:scenario_001 ... scenario_007.

```python
all_scenarios = {f"scenario_00{i}" for i in range(1, 8)}
missed = all_scenarios - set(scenario_deploys.keys())
```

### 4. 产输出

```markdown
**近 7 天 deploy 覆盖**:
- scenario_001 (AI 聊天/陪伴): 2 次成功
- scenario_003 (视频生成): 1 次成功
- ...
- scenario_005 (AI 音乐): **0 次**(盲区) — 是否加权重?
```
EOF
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/ai-auto/coverage-gaps.md
git commit -m "ai-auto: add coverage-gaps skill (跨日盲区追踪)"
```

---

### Task 4.3: cost-analysis skill

**Files:**
- Create:`/root/ai-auto-harness/.claude/skills/ai-auto/cost-analysis.md`

- [ ] **Step 1: 写 skill**

```bash
cat > /root/ai-auto-harness/.claude/skills/ai-auto/cost-analysis.md <<'EOF'
---
name: cost-analysis
description: 标准化双路成本表 — api-skeleton skill 内部调
---

# cost-analysis

## 触发

api-skeleton skill 渲染"双路成本对比"表时调.

## 你的输入

```json
{
  "slug": "...",
  "model_size_gb": 36,
  "params_b": 12,
  "estimated_qps": 10,
  "api_provider_pricing": {"input_per_million": 0.14, "output_per_million": 0.28}
}
```

## 工作流

### API 路线成本

```python
# 假设 QPS=10, 平均 input=2000 tokens, output=1000 tokens, 8 小时活跃/天
daily_input_tokens = 10 * 2000 * 8 * 3600  # 576M
daily_output_tokens = 10 * 1000 * 8 * 3600  # 288M
daily_cost_usd = (
    daily_input_tokens / 1e6 * api_pricing["input_per_million"] +
    daily_output_tokens / 1e6 * api_pricing["output_per_million"]
)
monthly_cost_usd = daily_cost_usd * 30
```

### Self-host 路线成本(5090)

```python
# N 卡 5090, 月成本 ¥2.5/卡/h * 24 * 30 = ¥1800/卡/月
# N 由 model_size_gb 决定:N = ceil(model_size_gb / 32) (每卡 32GB)
n_cards = (model_size_gb + 31) // 32
monthly_cost_cny = n_cards * 1800
```

### 输出表格(markdown)

```markdown
| 路线 | 可行 | 月度估算 | 关键参数 | 备注 |
|---|---|---|---|---|
| API | ✅ | ¥X | $0.14/M input, $0.28/M output | 第三方代理 |
| 5090 自部署 | ✅ | ¥Y | N 卡分片 | 单次成本低,需运维 |
```
EOF
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/ai-auto/cost-analysis.md
git commit -m "ai-auto: add cost-analysis skill (双路成本标准表)"
```

---

### Task 4.4: memory/lessons 写入机制

**Files:**
- Modify:`/root/ai-auto-harness/.claude/skills/ai-auto/run-and-repair.md`
- Modify:`/root/ai-auto-harness/.claude/skills/ai-auto/install-env.md`

- [ ] **Step 1: 在 run-and-repair 末尾加自主写 lesson 的指引**

读 run-and-repair.md,在 "强制要求" 段加:

```markdown
### 自主积累 lesson(非常规修复)

若你做的修复是"通用经验"(不只针对当前项目),应该写到 `memory/lessons/<topic>.md`:

```bash
# 示例:发现新的 sm_12 不兼容情形
Write memory/lessons/torch-sm12.md  # 追加段落,不覆盖
```

判断标准:
- 这个修复方法是否能用在其他项目 → 是 → 写 lesson
- 还是只针对当前项目特有 bug → 写 memory/projects/<slug>.md

不要为每个小调整都写 lesson(过度积累 = 噪声),只记真正可复用的经验.
```

- [ ] **Step 2: 同样修改 install-env skill**

加同样段落到 install-env.md 末尾。

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/ai-auto/run-and-repair.md .claude/skills/ai-auto/install-env.md
git commit -m "ai-auto: agent 自主积累 lessons/ 经验机制"
```

---

### Task 4.5: auto-deploy-agent 加 deprecated 提示

**Files:**
- Modify:`/root/auto-deploy-agent/README.md`

- [ ] **Step 1: 切到 main 看现有 README**

```bash
cd /root/auto-deploy-agent
git checkout main
head -10 README.md
```

- [ ] **Step 2: 在顶部加 deprecated 提示**

```bash
cd /root/auto-deploy-agent
# 在 README.md 顶部插入(用 Edit 工具或 sed):
# (注意:不要破坏现有内容)

# 用 Read + Write 直接 prepend:
cat > /tmp/deprecated-notice.md <<'EOF'
> ## ⚠️ DEPRECATED
>
> 本项目已被 [ai-auto-harness](http://192.168.1.227/maihaicheng/ai-auto-harness) 替代.
>
> 新平台基于 Claude Code 源码 + 自定义 skill 实现 repair_loop 替代,详见 ai-auto-harness 的 spec.
> 本项目代码保留作为 prompt 经验 / domain knowledge 来源,**不再演进**.
>
> ---

EOF
cat /tmp/deprecated-notice.md /root/auto-deploy-agent/README.md > /tmp/readme-new.md
mv /tmp/readme-new.md /root/auto-deploy-agent/README.md
rm /tmp/deprecated-notice.md
```

- [ ] **Step 3: Commit + Push**

```bash
cd /root/auto-deploy-agent
git checkout -b chore/deprecated-notice
git add README.md
git commit -m "chore: mark project as deprecated — replaced by ai-auto-harness"
git push origin chore/deprecated-notice
# 可选:web 界面 merge,或:
# git checkout main && git merge chore/deprecated-notice && git push origin main
```

---

### Task 4.6: 项目 README + 完整文档

**Files:**
- Modify:`/root/ai-auto-harness/README.md`(覆写 CC base 的)

- [ ] **Step 1: 写新 README**

```bash
cat > /root/ai-auto-harness/README.md <<'EOF'
# AI Auto Harness

> **基于 Claude Code 源码的自动 AI 项目发现 + 部署验证平台**

## 它做什么

每天 10:30 由 cron 触发,自动完成:
1. 通过 MCP 从 [ai-daily-scan](https://github.com/haichengmai20-hub/ai-daily-scan) 拿到当日 AI 项目候选
2. 按 30B 阈值 / 资源 / blacklist 过滤,挑 1 个项目
3. 5 阶段 SubAgent 流水线部署:
   - **intake**:git clone + 读 README + 资源 preflight
   - **fetch-weights**:HF 权重下载(background,可跨 cron 接续)
   - **install-env**:venv + pip + torch sm_12 修复 + 常见 build issue
   - **run-and-repair**:试跑 entry_script,失败 LLM 自主修复(max 3 轮)
   - **verify**:独立 SubAgent 判定能否跑(限工具)
4. 失败 / 模型 > 30B → 产 API 骨架 + 中文使用指导
5. 写每日报告 + 回填 outcomes 给 scan

## 快速开始

```bash
# 1. 装 bun(若没装)
curl -fsSL https://bun.sh/install | bash

# 2. 装 CC 依赖
cd /root/ai-auto-harness
bun install

# 3. 配置 .env(API key)
cp .env.example .env
# 编辑:ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY, HF_TOKEN(若用 gated repo)

# 4. 测试一次
./bin/claude-haha --print "/auto-status"

# 5. 部署 cron
crontab -e
# 加:30 10 * * * /root/ai-auto-harness/cron/daily.sh
```

## 文档

- [设计文档](docs/superpowers/specs/2026-05-19-ai-auto-harness-design.md)
- [实施 plan](docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md)

## 架构

- 基于 [claudecode_sourcecode1](https://github.com/haichengmai20-hub/claudecode_sourcecode1) fork(`upstream` remote)
- 自定义 `.claude/skills/ai-auto/*`(12 个 skill)
- Python MCP server in [ai-daily-scan](https://github.com/haichengmai20-hub/ai-daily-scan)
- Runtime state in `workspace/` / `runs/` / `memory/` / `pending_human/`(gitignored)

## 维护

- CC 升级:`git pull upstream main`
- 自己的改动:用 `ai-auto:` commit 前缀,`git log --grep=ai-auto`
EOF
```

- [ ] **Step 2: Commit + Push 完整 Phase 4**

```bash
cd /root/ai-auto-harness
git add README.md
git commit -m "ai-auto: project README (覆写 CC base)"
git push origin main
```

---

## Phase 4 Milestone 验收

- [ ] 3 个借鉴 skill 已写 + 集成到流程
- [ ] memory/lessons 写入指引在 run-and-repair / install-env 里
- [ ] auto-deploy-agent README 加 deprecated 提示
- [ ] ai-auto-harness README 完整

---

## 整体 Milestone 总结

| Phase | Milestone | 验证 |
|---|---|---|
| -1 | 磁盘 free > 500GB + R2/R3 实验结论 | `df -h /root` + `experiments/R{2,3}-findings.md` |
| 0 | ai-daily-scan MCP 4 工具,findings.jsonl 产出 | `pytest tests/` + `python -m src.run_daily` |
| 1 | intake 端到端跑通 | `/auto-daily` 跑通 + state.phase=fetching |
| 2 | fetch+install+run 跑通 | SongGeneration state.phase=verifying 或 done |
| 3 | MVP 完整 — 报告 + 回填 + chaos | reports/ + outcomes.jsonl + crontab |
| 4 | 借鉴 skill + memory + 文档 | 3 个 skill + README |

---

## Self-Review

**1. Spec coverage:** ✅
- §3 硬约束 → Phase -1 + Phase 1 settings.json + CLAUDE.md
- §4 整体架构 → Phase 0-3 实现
- §5 数据流(正常/接续/转骨架/人介入)→ Phase 1-3 各 skill
- §6 仓库结构 → Phase 1 setup
- §7 MCP + Finding schema → Phase 0 全部
- §8 12 个 skill → 每个有对应 task
- §9 state.json + 接续 → Phase 1.7 (daily-auto) + Phase 2.1
- §10 Flux 8 痛点 → 各 skill 内部对应解决
- §11 human-in-loop → Phase 1.10 + 各 SubAgent 触发条件
- §12 hooks/commands/settings → Phase 1.3-1.6 + 1.11
- §13 测试策略 L1/L2/L3 → L1 Phase 0 pytest / L2 Phase 3.5 / L3 Phase 3.6
- §14 迁移路径 → 整个 plan 按 Phase 0-4 拆分
- §15 风险 → R2/R3 Phase -1 实验,R4 Phase -1.1,其他在 skill 内对应
- §16 数据 schema → Phase 0(Finding/Outcome)+ Phase 1-3(RunResult/VerifyState 在 skill 内定义)

**2. Placeholder scan:** ✅
- 无 TBD / TODO
- 所有 bash / python 代码块都是可执行的
- Skill prompts 都有完整 body 或显式引用 spec § 8

**3. Type consistency:** ✅
- Finding schema(Phase 0 Task 0.2 + 0.4)与 daily-auto skill 任务 2(Phase 1 Task 1.7)读取的字段一致
- RunResult / VerifyState schema 在 run-and-repair skill / verify skill 内定义,与 write-recommendation 消费的字段一致
- next_action 枚举 4 值在 schema / prompt / daily-auto 过滤逻辑一致

---

## 执行方式选择

**Plan 完成并保存到 `/root/ai-auto-harness/docs/superpowers/plans/2026-05-19-ai-auto-harness-implementation.md`。**

两种执行方式:

### 1. Subagent-Driven(推荐 — 适合长 plan,context 隔离)

为每个 Task 派一个 fresh subagent 执行,主 session 在 Task 之间 review 进展。
快速迭代,主 context 压力小。

REQUIRED SUB-SKILL:`superpowers:subagent-driven-development`

### 2. Inline Execution

在当前 session 直接执行所有 Task,Phase 之间 checkpoint review。
更适合小 plan / 想保持完整上下文。

REQUIRED SUB-SKILL:`superpowers:executing-plans`

---

**Which approach?**

(若选 Subagent-Driven 但 Phase 跨多次 cron 或多日,建议每完成一个 Phase 重新 trigger 一次本 plan,不要一口气跑 -1 → 4)
