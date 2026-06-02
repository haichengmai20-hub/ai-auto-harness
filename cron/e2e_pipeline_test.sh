#!/bin/bash
# e2e_pipeline_test.sh — 端到端流水线测试:
#   MCP scan → pick 项目 → auto-deploy → runbook → cleanup → archived
#
# 用法:
#   bash cron/e2e_pipeline_test.sh [<slug_override>]
#
# 若不传 slug_override,则:
#   1. 调 ai-daily-scan 的 scan_today() 扫描最新项目
#   2. 从 findings.jsonl 选最优候选(≤ 8GB weights, 有 GitHub URL)
#   3. 传入 auto-deploy skill
#
# 若传 slug_override,则跳过 scan 直接部署指定项目
set -e

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
AI_DAILY_SCAN_ROOT="${AI_DAILY_SCAN_ROOT:-/root/ai-daily-scan}"
cd "$HARNESS_ROOT"

# ======== Step 0: 检查前置条件 ========
echo "=== e2e_pipeline_test.sh: Step 0 — 检查前置条件 ==="

# GPU 检查
if command -v nvidia-smi &>/dev/null; then
    GPU_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
    echo "  GPU free: ${GPU_FREE}MB"
    if [ "$GPU_FREE" -lt 4000 ] 2>/dev/null; then
        echo "  ⚠️  GPU free < 4GB, 部署可能 OOM"
    fi
else
    echo "  ⚠️  nvidia-smi not found, GPU 检查跳过"
fi

# 磁盘检查
DISK_FREE_GB=$(df -BG . | tail -1 | awk '{print $4}' | tr -d 'G')
echo "  Disk free: ${DISK_FREE_GB}GB"
if [ "${DISK_FREE_GB}" -lt 30 ] 2>/dev/null; then
    echo "  ❌ Disk free < 30GB, 无法部署"
    exit 1
fi

# ======== Step 1: Scan (或使用指定 slug) ========
SLUG_OVERRIDE="${1:-}"

if [ -n "$SLUG_OVERRIDE" ]; then
    echo "=== e2e_pipeline_test.sh: Step 1 — 使用指定 slug: $SLUG_OVERRIDE ==="
    SLUG="$SLUG_OVERRIDE"
    GITHUB_URL=""
    HF_REPO=""
    ESTIMATED_PARAMS=""
    ESTIMATED_WEIGHT_GB=""
else
    echo "=== e2e_pipeline_test.sh: Step 1 — 扫描最新项目 ==="

    # 运行 scan (如果今天还没 scan 过)
    FINDINGS_FILE="$AI_DAILY_SCAN_ROOT/state/findings.jsonl"
    TODAY=$(date +%Y-%m-%d)
    
    if [ -f "$FINDINGS_FILE" ]; then
        FINDINGS_DATE=$(stat -c %Y "$FINDINGS_FILE" 2>/dev/null || stat -f %m "$FINDINGS_FILE" 2>/dev/null || echo 0)
        TODAY_START=$(date -d "$TODAY 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$TODAY" +%s 2>/dev/null || echo 0)
        if [ "$FINDINGS_DATE" -ge "$TODAY_START" ] 2>/dev/null; then
            echo "  findings.jsonl 已是今天($TODAY)的,跳过 scan"
        else
            echo "  findings.jsonl 不是今天的,重新 scan..."
            cd "$AI_DAILY_SCAN_ROOT" && python -m src.ai_scan && cd "$HARNESS_ROOT"
        fi
    else
        echo "  findings.jsonl 不存在,运行 scan..."
        cd "$AI_DAILY_SCAN_ROOT" && python -m src.ai_scan && cd "$HARNESS_ROOT"
    fi

    # 从 findings 选最优候选
    echo ""
    echo "  当前 findings:"
    python3 -c "
import json
with open('$FINDINGS_FILE') as f:
    findings = [json.loads(l) for l in f if l.strip()]
for i, fd in enumerate(findings):
    gh = fd.get('github_url', 'N/A')
    hf = ', '.join(fd.get('hf_repos', []))
    params = fd.get('estimated_params_b', '?')
    wt = fd.get('estimated_weight_size_gb', '?')
    action = fd.get('next_action', '?')
    conf = fd.get('confidence', '?')
    print(f'  [{i}] {fd[\"slug\"]}: {params}B params, {wt}GB weights, github={gh}, action={action}, conf={conf}')
" 2>/dev/null || echo "  (无 findings 或解析失败)"

    # 自动选候选:≤8GB weights, 有 github_url, confidence=high 优先
    CANDIDATE=$(python3 -c "
import json
with open('$FINDINGS_FILE') as f:
    findings = [json.loads(l) for l in f if l.strip()]

# 过滤: 有 github_url + weights <= 8GB
candidates = []
for fd in findings:
    wt = fd.get('estimated_weight_size_gb', 999)
    if wt is None: wt = 999
    gh = fd.get('github_url', '')
    if gh and wt <= 8:
        candidates.append(fd)

if not candidates:
    # 放宽: 只要 github_url 存在
    for fd in findings:
        gh = fd.get('github_url', '')
        if gh:
            candidates.append(fd)

if not candidates:
    print('ERROR:no_candidates')
    exit(0)

# 排序: confidence=high 优先, params 小优先(快速部署)
def sort_key(fd):
    conf_order = {'high': 0, 'medium': 1, 'low': 2, '?': 3}
    params = fd.get('estimated_params_b', 999)
    if params is None: params = 999
    return (conf_order.get(fd.get('confidence', '?'), 3), params)

candidates.sort(key=sort_key)
best = candidates[0]
print(best['slug'])
" 2>/dev/null)

    if [ "$CANDIDATE" = "ERROR:no_candidates" ] || [ -z "$CANDIDATE" ]; then
        echo "  ❌ 没有找到合适的候选项目(需要有 GitHub URL)"
        exit 1
    fi

    # 提取候选详情
    eval "$(python3 -c "
import json
with open('$FINDINGS_FILE') as f:
    findings = [json.loads(l) for l in f if l.strip()]
for fd in findings:
    if fd['slug'] == '$CANDIDATE':
        print(f'SLUG=\"{fd[\"slug\"]}\"')
        print(f'GITHUB_URL=\"{fd.get(\"github_url\", \"\")}\"')
        hf = fd.get('hf_repos', [])
        print(f'HF_REPO=\"{hf[0] if hf else \"\"}\"')
        print(f'ESTIMATED_PARAMS=\"{fd.get(\"estimated_params_b\", \"\")}\"')
        print(f'ESTIMATED_WEIGHT_GB=\"{fd.get(\"estimated_weight_size_gb\", \"\")}\"')
        break
" 2>/dev/null)"

    echo ""
    echo "  ✅ 选定候选: $SLUG"
    echo "     GitHub: $GITHUB_URL"
    echo "     HF Repo: $HF_REPO"
    echo "     Params: ${ESTIMATED_PARAMS}B"
    echo "     Weight: ${ESTIMATED_WEIGHT_GB}GB"
fi

# ======== Step 2: 构建 prompt 并启动 auto-deploy ========
echo ""
echo "=== e2e_pipeline_test.sh: Step 2 — 启动 auto-deploy ==="

RUN_ID="e2e-${SLUG:-manual}-$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HARNESS_ROOT/runs/$RUN_ID"

PROMPT="请使用 auto-deploy skill 部署项目:
- slug: ${SLUG}
- github_url: ${GITHUB_URL}
- hf_repo: ${HF_REPO}
- estimated_params_b: ${ESTIMATED_PARAMS}
- estimated_weight_size_gb: ${ESTIMATED_WEIGHT_GB}

完整流水线:intake → fetch-weights → install-env → run-and-repair → verify → write-deploy-runbook → cleanup-deployed-workspace

部署成功后,必须:
1. 调用 write-deploy-runbook skill 写 runbook
2. 调用 cleanup-deployed-workspace skill 清理 workspace
3. 最终 state = archived"

echo "  Run ID: $RUN_ID"
echo "  Log dir: $LOG_DIR"
echo "  Prompt: ${PROMPT:0:200}..."
echo ""

# 启动 worker
bash "$HARNESS_ROOT/cron/launch_worker.sh" "$PROMPT" "$LOG_DIR" "${SLUG}"
EXIT_CODE=$?

echo ""
echo "=== e2e_pipeline_test.sh: 完成 ==="
echo "  Exit code: $EXIT_CODE"
echo "  Run ID: $RUN_ID"

# ======== Step 3: 验证 e2e 结果 ========
echo ""
echo "=== e2e_pipeline_test.sh: Step 3 — 验证 e2e 结果 ==="

WORKSPACE="$HARNESS_ROOT/workspace/$SLUG"

# 检查 state.json
if [ -f "$WORKSPACE/state.json" ]; then
    STATE_PHASE=$(python3 -c "import json; print(json.load(open('$WORKSPACE/state.json')).get('phase','?'))" 2>/dev/null || echo "?")
    echo "  state.json phase: $STATE_PHASE"
    if [ "$STATE_PHASE" = "archived" ]; then
        echo "  ✅ 全流水线成功: state=archived"
    elif [ "$STATE_PHASE" = "done" ]; then
        echo "  ⚠️  state=done(verify 通过但 cleanup 未跑)"
    else
        echo "  ❌ state=$STATE_PHASE(流水线未完成)"
    fi
else
    echo "  ❌ state.json 不存在"
fi

# 检查 runbook
RUNBOOK=$(ls "$HARNESS_ROOT/reports/runbooks/${SLUG}"*.md 2>/dev/null | head -1)
if [ -n "$RUNBOOK" ]; then
    RUNBOOK_SIZE=$(wc -c < "$RUNBOOK")
    echo "  ✅ Runbook: $RUNBOOK (${RUNBOOK_SIZE} bytes)"
else
    echo "  ❌ Runbook 未生成"
fi

# 检查 cleanup.json
if [ -f "$WORKSPACE/results/cleanup.json" ]; then
    echo "  ✅ cleanup.json 存在"
    python3 -c "import json; d=json.load(open('$WORKSPACE/results/cleanup.json')); print(f'    freed: {d.get(\"freed_human\",\"?\")}, removed: {d.get(\"removed\",[])}')" 2>/dev/null
else
    echo "  ❌ cleanup.json 不存在"
fi

# 检查 workspace 清理后大小
if [ -d "$WORKSPACE" ]; then
    WS_SIZE=$(du -sh "$WORKSPACE" 2>/dev/null | awk '{print $1}')
    echo "  Workspace size after cleanup: $WS_SIZE"
fi

echo ""
echo "=== e2e_pipeline_test.sh: done ==="
exit $EXIT_CODE
