# AI Auto Harness — Cron 续跑与自动恢复优化 Spec

**日期**: 2026-06-11
**状态**: 设计稿
**触发**: cron-2026-06-11-110631 实战复盘（SCAIL 全流程 2.6 小时 / $79.67）
**目标读者**: 下次迭代开发者

---

## 1. 问题全景

从 cron-2026-06-11-110631 跑 SCAIL 的完整时间线中提取所有效率损失：

```
11:06  cron 启动
11:06─11:23  [17min] agent 读 SKILL.md + 判断接续（无实质工作）
11:23─11:37  [14min] fetch-weights SubAgent 确认下载（文件已全部在磁盘）
11:37─12:06  [30min] install-env pip install（正常，无可优化）
12:07─13:23  [76min] run-and-repair 3 轮修复（2 轮是 OOM 不可避免，第 1 轮有优化空间）
13:23─13:48  [25min] verify + runbook + 收尾（正常）
─────────────────
总计 157 分钟，其中 ~31 分钟是空转/可避免的等待
```

### 1.1 核心问题分类

| # | 问题 | 影响 | 这次耗时 | 根因 |
|---|------|------|---------|------|
| P1 | **cron 只跑一次就退出，不自动续跑** | fetch-weights 卡 24 小时等到第二天 cron | 24h 延迟 | daily.sh 设计：跑完即退 |
| P2 | **SubAgent 启动慢，读 SKILL.md 重复理解** | 每次 dispatch 都重新加载规则 | 17min | CC 架构限制：SubAgent 独立上下文 |
| P3 | **state.json 与实际不一致** | agent 反复确认已完成的工作 | 14min | 我们手动改了 state 但 fetch-weights.json 还是旧的 |
| P4 | **GPU 被其他服务占满无 preflight 拦截** | 跑到 run 阶段才发现 OOM | ~30min 浪费 | intake preflight 只看总量不看空闲 |
| P5 | **无中间结果缓存/跳过机制** | verify 重复收集 run-and-repair 已知的 OOM 证据 | ~5min | verify 设计：独立判定，不读 state |
| P6 | **cron 失败后无自动重试** | 需要人工介入才能续跑 | 人等时间 | daily.sh 无重试逻辑 |
| P7 | **无工作区健康巡检 cron** | 僵尸进程 8915 个 / stale state / orphan venv | 不确定但危险 | 只有手动 monitor |

---

## 2. 设计方案

### 2.1 P1: Cron 自动续跑（你提的核心需求）

**现状**: cron 10:00 跑一次，遇到 `paused_in_progress` 就退出，等明天 10:00 再跑。

**目标**: cron 退出后，自动设置一个"巡检+续跑"机制，检测工作区状态，如果项目还没完成就自动续跑。

#### 方案 A: Hermes cron 双层调度（推荐）

```
10:00  主 cron (daily.sh) — 启动 claude-haha，跑 auto-daily
       ↓
       主 cron 退出后：
       - 如果 workspace 下有 in_progress 项目 → 创建 Hermes cron 续跑任务
       - 续跑任务: 30 分钟后触发，检查 state.json
         - 如果还是 in_progress → 再次启动 claude-haha
         - 如果 done / paused_for_human → 删除续跑任务，不启动
       - 续跑最多 3 次（防止无限循环）
```

**实现方式**:

在 `cron/daily.sh` 末尾加一段：

```bash
# After main claude-haha exits
# Check if any project is still in_progress
IN_PROGRESS=$(find workspace/ -name state.json -exec jq -r 'select(.status == "in_progress" or .status == "running" or .status == "paused_in_progress") | .slug' {} \; 2>/dev/null)

if [ -n "$IN_PROGRESS" ]; then
  echo "[续跑] 检测到未完成项目: $IN_PROGRESS，30 分钟后自动续跑"
  # 通过 Hermes cronjob 工具创建一次性续跑任务
  # 或者用简单的 at/timeout 命令：
  echo "cd /root/ai-auto-harness && bash cron/daily.sh" | at now + 30 minutes 2>/dev/null
fi
```

**优点**: 
- 不改 claude-haha 架构，只在 daily.sh 外面包一层
- 续跑时 agent 重新读 state.json，自然从断点接续
- 30 分钟间隔给 pip install / 下载留够时间

**风险**:
- 如果项目最终会 OOM（像 SCAIL），会浪费 3 次续跑才放弃
- 需要续跑次数上限（3 次）防止无限循环

#### 方案 B: Hermes cron 原生调度

用 Hermes 的 cronjob 工具：

```yaml
# 主任务 10:00
- schedule: "0 10 * * *"
  prompt: "运行 ai-auto-harness auto-daily 工作流"
  skills: [ai-auto-harness]

# 续跑检查任务 10:45 (主任务通常 45 分钟内完成或暂停)
- schedule: "45 10 * * *"
  script: "check_and_resume.sh"  # 无 agent，纯脚本
  no_agent: true
  # 脚本输出非空则触发 agent 续跑
```

**优点**: Hermes 原生 cron 管理，不需要 at 命令
**缺点**: 依赖 Hermes cron 基础设施

#### 方案 C: 长驻 daemon（远期）

```
ai-auto-harness-daemon
  ├── 主循环: 每 30 分钟扫描 workspace/*/state.json
  ├── 发现 in_progress → 启动 claude-haha 续跑
  ├── 发现 done → 写报告 + record_outcome
  └── 发现 paused_in_progress 超过 N 小时 → paused_for_human
```

**优点**: 最优雅，实时响应
**缺点**: 开发量大，需要进程管理、日志、crash recovery

**推荐**: 先做方案 A（1 天工作量），验证效果后再考虑 B 或 C。

---

### 2.2 P4: GPU Preflight 增强

**现状**: intake 阶段只检查 GPU 总量（8 卡 × 32GB），不检查空闲显存。

**改进**: 在 intake SubAgent 的 preflight 中加入实际空闲显存检查：

```python
# intake preflight 新增
import subprocess

def check_gpu_available(required_vram_gb: float, required_gpus: int) -> dict:
    """检查是否有足够的空闲 GPU"""
    result = subprocess.run(
        ["nvidia-smi", "--query-gpu=index,memory.free", "--format=csv,noheader"],
        capture_output=True, text=True
    )
    free_gpus = []
    for line in result.stdout.strip().split("\n"):
        idx, free_mb = line.split(", ")
        free_gb = int(free_mb.strip().split()[0]) / 1024
        if free_gb >= required_vram_gb:
            free_gpus.append((int(idx), free_gb))
    
    if len(free_gpus) < required_gpus:
        return {
            "blocked": True,
            "reason": f"需要 {required_gpus}×{required_vram_gb}GB GPU, 只有 {len(free_gpus)} 张空闲",
            "free_gpus": free_gpus,
            "recommendation": "等 vLLM 服务释放 或 改用 api-skeleton 路径"
        }
    return {"blocked": False, "gpu_picks": [g[0] for g in free_gpus[:required_gpus]]}
```

**这能避免 SCAIL 的情况**: intake 阶段就发现只有 2 张空闲卡，14B 模型需要 4 张，直接走 api-skeleton 路径，省下 2 小时 + $80。

---

### 2.3 P3: State 一致性自动修复

**现状**: 多个地方写 state（手动改、SubAgent 改、cron 改），容易出现不一致。

**改进**: 在 daily.sh 启动时加一个轻量 state 修复脚本：

```bash
# reconcile-state.sh — 每次 cron 启动时跑
for state_file in workspace/*/state.json; do
  slug=$(jq -r '.slug' "$state_file")
  phase=$(jq -r '.phase' "$state_file")
  status=$(jq -r '.status' "$state_file")
  
  # 规则 1: fetch-weights paused_in_progress 但文件已全在 → 修复为 done
  if [ "$phase" = "fetch-weights" ] && [ "$status" != "done" ]; then
    if verify_weights_complete "$slug"; then
      jq '.phase = "fetch-weights" | .status = "done" | .phases_done += ["fetch-weights"]' "$state_file" > tmp.json
      mv tmp.json "$state_file"
      echo "[修复] $slug: fetch-weights 已完成但 state 未标记，已修正"
    fi
  fi
  
  # 规则 2: installing 但 venv 存在且 pip 成功 → 修复为 done
  # 规则 3: running 但无活跃进程且超时 → 修复为 paused_in_progress
done
```

---

### 2.4 P6: 失败自动重试

**现状**: cron 跑完就完了，不管成功失败。

**改进**: 在 daily.sh 末尾加结果检查：

```bash
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "[重试] cron 异常退出 (code=$EXIT_CODE)，15 分钟后重试"
  echo "cd /root/ai-auto-harness && bash cron/daily.sh" | at now + 15 minutes
fi
```

---

### 2.5 P7: 工作区健康巡检 Cron

**新增一个独立巡检 cron**（不是 agent，纯脚本，0 token）：

```bash
# health-check.sh — 每 2 小时跑一次
# 1. 清理僵尸进程
find /proc -maxdepth 1 -name '[0-9]*' | while read p; do
  if [ "$(cat /proc/$p/stat 2>/dev/null | awk '{print $3}')" = "Z" ]; then
    # 记录但不杀（需要父进程收尸）
    echo "僵尸: PID $p" >> logs/zombie-report.log
  fi
done

# 2. 检测 stale state (updated_at > 4 小时前 且 status = running)
find workspace/ -name state.json | while read f; do
  updated=$(jq -r '.updated_at' "$f")
  # ... 比较时间 ...
done

# 3. 磁盘空间检查
FREE_GB=$(df -BG /root | tail -1 | awk '{print $4}' | tr -d 'G')
if [ "$FREE_GB" -lt 50 ]; then
  echo "⚠️ 磁盘空间不足: ${FREE_GB}GB" 
fi

# 4. GPU 占用异常检测（单进程占多卡 > 2 小时）
# ...
```

---

## 3. 优先级排序

| 优先级 | 改进项 | 预期收益 | 工作量 | 依赖 |
|--------|--------|---------|--------|------|
| **P0** | 2.1 Cron 自动续跑 | 消除 24h 等待，fetch-weights 完成后立即推进 | 0.5 天 | daily.sh 修改 |
| **P0** | 2.2 GPU Preflight 增强 | 避免 OOM 浪费（每次省 $50-80 + 2 小时） | 0.5 天 | intake skill 修改 |
| **P1** | 2.3 State 一致性修复 | 消除 14 分钟空转确认 | 0.5 天 | 新脚本 |
| **P1** | 2.4 失败自动重试 | 异常退出后自动恢复 | 0.5 小时 | daily.sh 修改 |
| **P2** | 2.5 工作区健康巡检 | 预防僵尸进程/磁盘满/stale state | 1 天 | 新 cron + 脚本 |

---

## 4. 续跑方案详细设计（方案 A 展开）

### 4.1 流程图

```
cron 10:00 启动 daily.sh
  │
  ▼
claude-haha 跑 auto-daily
  │
  ├─ 全部完成(done) → 退出，不设续跑
  │
  ├─ paused_for_human → 退出，不设续跑
  │
  ├─ paused_in_progress → 退出，设置续跑
  │   └─ at now + 30min: daily.sh
  │       └─ 续跑 1/3（最多 3 次）
  │
  └─ 异常退出(exit != 0) → 退出，设置重试
      └─ at now + 15min: daily.sh
```

### 4.2 续跑逻辑

```bash
# daily.sh 末尾追加

MAX_RESUME=3
RESUME_FILE="state/resume-count-$(date +%Y-%m-%d).txt"

count_resumes() {
  if [ -f "$RESUME_FILE" ]; then
    cat "$RESUME_FILE"
  else
    echo 0
  fi
}

increment_resumes() {
  echo $(( $(count_resumes) + 1 )) > "$RESUME_FILE"
}

# --- 续跑判断 ---
IN_PROGRESS=$(find workspace/ -maxdepth 2 -name state.json \
  -exec jq -r 'select(.status == "in_progress" or .status == "running" or .status == "paused_in_progress") | .slug' {} \; 2>/dev/null)

if [ -n "$IN_PROGRESS" ] && [ "$(count_resumes)" -lt "$MAX_RESUME" ]; then
  increment_resumes
  RESUME_N=$(count_resumes)
  echo "[续跑] 检测到未完成项目: $IN_PROGRESS (第 ${RESUME_N}/${MAX_RESUME} 次续跑)"
  echo "cd $(pwd) && bash cron/daily.sh" | at now + 30 minutes 2>/dev/null || \
  (sleep 1800 && cd $(pwd) && bash cron/daily.sh &)
elif [ -n "$IN_PROGRESS" ]; then
  echo "[放弃] 已续跑 ${MAX_RESUME} 次仍未完成，标记 paused_for_human"
  echo "$IN_PROGRESS" | while read slug; do
    jq '.status = "paused_for_human"' "workspace/${slug}/state.json" > tmp.json && mv tmp.json "workspace/${slug}/state.json"
  done
fi

# 每日重置（午夜清零）
if [ "$(date +%H)" -ge 23 ]; then
  rm -f "$RESUME_FILE"
fi
```

### 4.3 续跑场景模拟

**场景 1: fetch-weights 下载 47GB 权重**
```
10:00 cron 启动 → dispatch fetch-weights → 下载 40 分钟未完成 → paused_in_progress
10:45 cron 退出 → 检测 in_progress → at now + 30min
11:15 续跑 1 → fetch-weights resume → 下载完成 → install-env → running → OOM → paused_for_human
11:45 续跑检查 → paused_for_human → 不设续跑 ✅
```

**场景 2: SCAIL 这种 OOM 死循环**
```
10:00 cron 启动 → install-env 完成 → running → OOM → repair 1 → OOM → repair 2 → OOM → paused_for_human
10:45 cron 退出 → paused_for_human → 不设续跑 ✅
```
（GPU preflight 增强后，这种场景在 intake 阶段就会被拦截）

**场景 3: pip install 超时**
```
10:00 cron 启动 → install-env → pip install torch (很慢) → wallclock 超时 → paused_in_progress
10:45 cron 退出 → 检测 in_progress → at now + 30min
11:15 续跑 1 → install-env resume → pip 完成 → running → ... → done
```

---

## 5. 与现有 R 规则的交互

| 规则 | 续跑设计的影响 | 是否需要改 |
|------|---------------|-----------|
| R3 wall-clock | 续跑后每个阶段重新计时，不累计 | 不改 |
| R4 sleep 纪律 | 续跑是全新 session，无累积 sleep | 不改 |
| R9 主 agent 只 dispatch | 续跑时主 agent 重新走 任务1→任务3 | 不改 |
| R10 sentinel | 续跑时 SubAgent 重新读 sentinel 判断 | 不改 |

续跑设计的核心：**每次续跑等价于一次新的 cron run**，只是不重新 pick 项目，直接从 state.json 的 phase 接续。所有 R 规则自然适用，无需修改。

---

## 6. 第二轮实战复盘：SCAIL 续跑（14:28─15:55）

GPU 释放后重置 state.json 续跑，暴露了更多框架级问题。

### 6.1 时间线

```
14:28  cron 启动（第1次续跑）
14:28─14:32  [4min]  agent 读 SKILL.md，发现 scail in_progress，判断接续
14:32─14:55  [23min] attempt 1: SAT MP=4, device mismatch (T5/CLIP 在 cuda:0)
14:55─15:08  [13min] attempt 2: SAT MP=4 + device fix, tensor size mismatch (5120≠1280)
15:08─15:21  [13min] cron 退出（poll limit），paused_in_progress
15:21─15:23  [2min]   cron 续跑（第2次）
15:23─15:32  [9min]   attempt 3: 切 wan 分支, flash_attn 缺失
15:32─15:47  [15min]  agent 尝试修复 flash_attn，3 轮用完 → paused_for_human
─────────────────
总计 87 分钟，$25.67
```

### 6.2 新发现的问题

| # | 问题 | 根因 | 框架级改善方向 |
|---|------|------|---------------|
| P8 | **接续时 agent 看到 failed outcome 就跳过** | auto-daily SKILL.md 无"资源变化重试"逻辑 | state.json 增加 `resume_reason` + `previous_failure=RESOLVED`，agent 已自然读取但需要写进规则 |
| P9 | **install-env 不装 flash-attn** | requirements.txt 没列，install-env 只装列出的包 | install-env 应该做 import 预检：跑 `python -c "import flash_attn"` 失败则尝试安装 |
| P10 | **run-and-repair 不应切换 git branch** | agent 在 attempt 3 切了 wan 分支，丢掉了之前的修改 | R 规则应限制：run-and-repair 不得 `git checkout` 其他分支，只能在当前分支上修复 |
| P11 | **3 轮修复上限太死** | flash-attn 缺失只需 `pip install`，但第 3 轮已耗尽 | 修复上限应区分"可修复的依赖缺失"和"框架级 bug"。前者不计入上限 |
| P12 | **R4 poll limit 导致长任务被截断** | checkpoint resharding 需要 5-10 分钟，8 轮 poll 不够 | 后台进程 + sentinel 模式已实现（PID + log_path），但 poll 间隔应该动态调整 |

### 6.3 SCAIL 失败根因总结

| Attempt | 分支 | GPU | 错误 | 分类 |
|---------|------|-----|------|------|
| 0 (归档) | main | 1-2 | OOM (42GB > 32GB 单卡) | ✅ 资源不足，非代码bug |
| 1 | main | 4 MP=4 | device mismatch (T5/CLIP → cuda:0) | ⚠️ 代码bug，可修 |
| 2 | main | 4 MP=4 | tensor size 5120≠1280 (resharding) | ❌ SAT 框架深层 bug |
| 3 | wan | 1 | flash_attn AssertionError | ⚠️ 依赖缺失，可修 |

**结论**: SCAIL 在 wan 分支 + flash_attn 安装后大概率能跑通。这是 install-env 阶段遗漏依赖导致的失败，不是模型本身的问题。

### 6.4 关键教训：Monitor 的职责边界

Monitor（人类或 agent）**只观察记录，绝不介入决策**。即使知道"装个 flash-attn 就能跑"，也不应该帮 agent 做。原因：

1. **每个干预都是框架改善机会的丢失** — 如果这次帮装了，install-env 的 import 预检永远不会被加
2. **长尾场景的样本比成功更重要** — 失败记录是优化 spec 的输入
3. **Agent 的自主决策能力需要试错空间** — 不犯错就不知道规则缺什么

---

## 7. 第三轮复盘：续跑假退出问题（2026-06-12 khala 实战）

### 7.1 问题描述

khala（48.6GB 权重）fetch-weights 阶段，后台 `hf download` PID 一直活着，但 cron 续跑反复 "检查一下就退出"，形成 **假退出 → 续跑 → 又假退出** 循环，浪费 token 和 API 调用。

### 7.2 时间线

```
10:00  Run 100001: 选 khala → dispatch fetch-weights → CONCURRENT_HF 导致文件损坏
       → bash_count=100, poll=10, hit R4 → paused_in_progress → 30min后续跑
11:05  Run 110457: 续跑1 → 检测损坏 → force-download 重启 → poll 8 turn → R4 上限
       → paused_in_progress → 30min后续跑
11:53  Run 115235: 续跑2 → poll 进度 24% → 50min wall-clock → paused_in_progress → 30min后续跑
12:40  Run 123924: 续跑3 → poll 进度 44% → 续跑配额 3/3 用完 → 留给次日
```

**4 次 run，总计 ~80 分钟，~300+ API 调用，实际只做了 "看一眼下载还在不在"。**

### 7.3 根因分析

| 问题 | 机制 | 后果 |
|------|------|------|
| fetch-weights PID 在后台活着，不需要 agent 守着 | `setsid nohup hf download &` 已 detached | agent poll 8 turn 确认 "还在下" 然后退 = 纯空转 |
| R4 poll ≤8 turn 太短 | 设计意图防空转，但对后台下载场景误伤 | 8 turn 看几眼就退，下载还要几小时 |
| 50min wall-clock 太短 | 48.6GB 下载需 2-3 小时 | 每次都超时 |
| 每次续跑 agent 重新走完整 auto-daily 流程 | 任务1读state → 任务2跳过 → 任务3 dispatch SubAgent → SubAgent读SKILL → poll → 退出 | 大量 preamble 开销 |
| 续跑配额 3 次/天 | 对 fetch-weights 这种纯等待场景，3 次 x 30min = 90min 完全不够 | 配额用完但下载远没完 |

**核心矛盾**：fetch-weights 的下载是 nohup 后台进程，**根本不需要 agent 守着**。但每次续跑 agent 都重新 poll 8 turn 又退，形成循环空转。

### 7.4 方案：fetch-weights 后台下载免续跑

**核心思路**：后台下载进程还活着时，续跑不应做任何 poll / dispatch SubAgent，直接跳过。

#### 7.4.1 daily.sh 改动

在续跑判断中，区分 "需要 agent 介入的 in_progress" 和 "只需等待的 in_progress"：

```bash
# 现有逻辑：检测所有 in_progress 项目
IN_PROGRESS_SLUGS=$(find workspace/ -maxdepth 2 -name state.json \
  -exec jq -r 'select(.status == "in_progress" or .status == "paused_in_progress") | .slug' {} \;)

# 新增：过滤掉 "后台下载还在跑" 的项目
NEEDS_AGENT_SLUGS=""
for slug in $IN_PROGRESS_SLUGS; do
  sentinel="workspace/${slug}/.cache/handoff/fetch-weights-*.json"
  if ls $sentinel 2>/dev/null; then
    pid=$(jq -r '.pid' $sentinel 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "[$(date -Iseconds)] $slug: fetch-weights PID=$pid 仍在后台下载，跳过续跑" >> "$LOG_DIR/cleanup.log"
      continue  # 不计入 NEEDS_AGENT
    fi
  fi
  NEEDS_AGENT_SLUGS="$NEEDS_AGENT_SLUGS $slug"
done

# 用 NEEDS_AGENT_SLUGS 替代 IN_PROGRESS_SLUGS 做续跑判断
if [ -n "$NEEDS_AGENT_SLUGS" ] && [ "$resume_count" -lt "$MAX_RESUMES" ]; then
  # 有真正需要 agent 的项目 → 续跑
  ...
elif [ -n "$IN_PROGRESS_SLUGS" ]; then
  # 只有后台下载在跑 → 不续跑，也不消耗配额
  echo "[$(date -Iseconds)] 所有 in_progress 项目均在后台下载中，无需 agent 续跑" >> "$LOG_DIR/cleanup.log"
fi
```

**效果**：
- 后台下载进程活着 → 不续跑、不消耗配额、0 token
- 下载完成后 PID 死 → 下次自然 cron（10:00）检测到 PID 死 → 正常续跑推进 install-env
- 下载崩溃（PID 死 + exit_code ≠ 0）→ 同上，下次 cron 处理

#### 7.4.2 auto-daily SKILL 改动

任务 1 接续检查新增规则：

```
如果 state.phase == "fetching" 且 handoff 存在且 PID 仍活着:
  → 不 dispatch fetch-weights SubAgent
  → 不消耗续跑配额
  → 跳到任务 4 写报告（标注 "后台下载进行中，无需 agent 介入"）
  → 让 daily.sh 也不设续跑（通过输出标记告知 daily.sh）
```

主 agent 返回时增加字段：

```json
{
  "paused_in_progress": true,
  "bg_download_alive": true,   // 新增：后台下载进程仍活着
  "skip_resume": true          // 新增：告诉 daily.sh 不需要续跑
}
```

#### 7.4.3 fetch-weights SKILL 改动

现有逻辑：
```
PID 活着 → poll 8 turn → paused_in_progress → 退出
```

改为：
```
PID 活着 → 1 次 kill -0 确认 + 1 次 du -sh 估进度 → 返回 {paused_in_progress: true, bg_download_alive: true, skip_resume: true}
```

**1 turn 完成而不是 8 turn**。省 7 turn 的 API 调用。

#### 7.4.4 场景验证

**场景 1: khala 48.6GB 下载（本次实战）**

```
10:00  Run 1: 选 khala → dispatch fetch-weights → 后台下载启动
       → 1 turn 确认 PID 活着 → bg_download_alive=true, skip_resume=true → 退出
       → daily.sh 检测 skip_resume → 不设续跑，不消耗配额 ✅
       → hf download 在后台继续跑（无 agent 干扰）
次日 10:00  自然 cron → 检测 PID 已死 → 下载完成 → 推进 install-env ✅
```

对比现状：4 次 run × ~20 min × 100+ 调用 → **1 次 run × 1 turn × 1 调用**

**场景 2: 下载中途崩溃**

```
10:00  Run 1: 后台下载启动 → 1 turn 确认 → 退出，不续跑
11:30  hf download 崩溃（磁盘满/网络断）
次日 10:00  自然 cron → 检测 PID 死 → dispatch fetch-weights → 发现 incomplete → force-download → ...
```

与现有行为一致，只是省了中间的无效续跑。

**场景 3: 非 fetch-weights 的 paused_in_progress（install-env 慢）**

```
10:00  Run 1: install-env → pip 很慢 → paused_in_progress → bg_download_alive=false → skip_resume=false
       → daily.sh 设 30min 续跑 ✅（与现有一致）
```

不受影响，只有 fetch-weights 后台下载场景走新逻辑。

### 7.4.5 实现补记(2026-06-12,addendum)

§7.4 草案已全部落地,但实现对草案做了 4 处修正,**以实现为准**:①判活加僵尸排查(`/proc/<pid>/stat` ≠ Z,kill -0 对 Z 误判活);②加 30min 停滞检测(否则"活着但卡死"的下载会被无限跳过,永远没人处理);③"等次日 cron"改为 **0-token 免配额复查链**(10min 一次,下载一结束就接续;复查触发的 agent 启动仍消耗续跑配额防失控);④判定逻辑收敛为 `scripts/check-bg-downloads.sh` 单一真相源(daily.sh 入口 WAIT_GATE + 尾部续跑 + hermes preflight 三处共用),不依赖 agent 输出标记。测试与细节见 [fixes/2026-06-12-resume-fake-exit-fix.md](../fixes/2026-06-12-resume-fake-exit-fix.md)。

### 7.5 实现优先级

| 步骤 | 改动 | 工作量 | 收益 |
|------|------|--------|------|
| 1 | daily.sh 续跑判断加 PID 存活检查 | 10 行 bash | 立即消除假续跑 |
| 2 | fetch-weights SKILL: PID 活着时 1 turn 退出 | 改 SKILL.md 3 行 | 省 7 turn/次 |
| 3 | auto-daily SKILL: 任务 1 加 bg_download_alive 判断 | 改 SKILL.md 5 行 | 省 SubAgent dispatch 开销 |

步骤 1 可以独立上线，步骤 2-3 是进一步优化。

---

## ChangeLog

- **2026-06-11** — 初始设计，基于 cron-2026-06-11-110631 SCAIL 实战复盘
- **2026-06-11** — 第二轮复盘：续跑 3 attempts 全失败，新增 P8-P12，Monitor 职责边界
- **2026-06-12** — 第三轮复盘：khala 实战暴露续跑假退出问题，新增 §7：fetch-weights 后台下载免续跑方案
