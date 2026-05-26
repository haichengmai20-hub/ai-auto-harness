#!/usr/bin/env bash
# validate-runbook.sh — write-deploy-runbook 产出验收脚本
#
# 用法:
#   bash scripts/validate-runbook.sh <runbook.md> <runbook.json>
#   bash scripts/validate-runbook.sh reports/runbooks/song-generation-run2-2026-05-25.md workspace/song-generation-run2/results/runbook.json
#
# 退出码: 0=全过 / 非 0=有失败(stdout 列出每个 check 的 PASS/FAIL)
# 设计原则:
#   - 每条 check 独立 echo + 局部 fail 不中断后续(全跑完才知道全貌)
#   - 比 retro 里手工 grep 更精确(P3-6:只匹配 `^### 已知踩坑 N` 标题行)
#   - S-3: traps_documented 数字与实际 trap 标题数交叉校验

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <runbook.md path> <runbook.json path>" >&2
    exit 2
fi

RUNBOOK_MD="$1"
RUNBOOK_JSON="$2"
FAIL=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; }

echo "=== validate-runbook ==="
echo "  md:   $RUNBOOK_MD"
echo "  json: $RUNBOOK_JSON"
echo

# ============================================================
# V1: 文件存在 + 非空
# ============================================================
echo "[V1] 文件存在 + 非空"
[ -f "$RUNBOOK_MD" ]   && pass "runbook.md 存在"   || { fail "runbook.md 不存在: $RUNBOOK_MD"; exit 1; }
[ -f "$RUNBOOK_JSON" ] && pass "runbook.json 存在" || { fail "runbook.json 不存在: $RUNBOOK_JSON"; exit 1; }
[ "$(wc -c < "$RUNBOOK_MD")" -ge 2048 ] && pass "runbook.md ≥ 2KB" || fail "runbook.md < 2KB,疑似半成品"

# ============================================================
# V2: frontmatter 必填字段
# ============================================================
echo
echo "[V2] frontmatter 必填字段"
for field in slug github date status duration_min total_cost_usd gpu_required_gb disk_required_gb; do
    if head -25 "$RUNBOOK_MD" | grep -qE "^${field}:" ; then
        pass "frontmatter.$field 存在"
    else
        fail "frontmatter.$field 缺失"
    fi
done

# ============================================================
# V3: 节编号 1-6 必须按顺序出现(7 仅在 status≠success 时有)
# ============================================================
echo
echo "[V3] 节编号顺序(1-6 必须按顺序出现)"
# 抽出 `## N.` 里的 N(支持中文标题),只取数字部分
SECTIONS=$(grep -oE "^## [0-9]+\." "$RUNBOOK_MD" | grep -oE "[0-9]+" | tr '\n' ' ' | sed 's/ $//')
EXPECTED="1 2 3 4 5 6"
if [[ "$SECTIONS" == "$EXPECTED "* || "$SECTIONS" == "$EXPECTED" ]]; then
    pass "节编号 1-6 顺序正确 ($SECTIONS)"
else
    fail "节编号顺序错: 实际=[$SECTIONS], 期望以 '$EXPECTED' 开头"
fi

# ============================================================
# V4: 5 Stage 完整(节 3 每个 Stage 必须有命令 + 成功标志)
# ============================================================
echo
echo "[V4] 节 3 内 5 个 Stage 标题完整"
STAGE_TITLES=(
    "Stage 1: clone"
    "Stage 2: 拉权重"
    "Stage 3: 装环境"
    "Stage 4: 推理"
    "Stage 5: 验证"
)
for title in "${STAGE_TITLES[@]}"; do
    if grep -qF "$title" "$RUNBOOK_MD" ; then
        pass "找到 '$title'"
    else
        fail "缺失或错字:'$title'(L1 实测出现过'腅环境')"
    fi
done

# ============================================================
# V5: 已知踩坑(精确 grep,不匹配引用行)
# ============================================================
echo
echo "[V5] 已知踩坑数(精确匹配标题行)"
# P3-6: 只匹配 `^### 已知踩坑 N:` 这种标题行,不计 AI prompt 节里的引用
TRAP_IN_MD=$(grep -cE "^### 已知踩坑 [0-9]+:" "$RUNBOOK_MD" || true)
echo "  实际 trap 标题数: $TRAP_IN_MD"

TRAP_IN_JSON=$(python3 -c "import json; print(json.load(open('$RUNBOOK_JSON'))['traps_documented'])" 2>/dev/null || echo "MISSING")
echo "  runbook.json.traps_documented: $TRAP_IN_JSON"

# S-3: 交叉校验
if [ "$TRAP_IN_JSON" = "MISSING" ]; then
    fail "runbook.json.traps_documented 字段缺失"
elif [ "$TRAP_IN_MD" -eq "$TRAP_IN_JSON" ]; then
    pass "traps_documented=$TRAP_IN_JSON 与实际 trap 标题数 $TRAP_IN_MD 一致"
else
    fail "S-3 不一致: traps_documented=$TRAP_IN_JSON, 实际=$TRAP_IN_MD"
fi

# ============================================================
# V6: 每个 trap 4 字段完整(触发条件/根因/修复/验证)
# ============================================================
echo
echo "[V6] 每个 trap 必须含 4 字段"
if [ "$TRAP_IN_MD" -gt 0 ]; then
    for n in $(seq 1 "$TRAP_IN_MD"); do
        # 抽这条 trap 的内容块(到下一条 trap 标题或下一个 ## 节为止)
        BLOCK=$(awk -v n="$n" '
            $0 ~ "^### 已知踩坑 "n":" { capture=1; next }
            capture && /^### 已知踩坑 [0-9]+:/ { capture=0 }
            capture && /^## [0-9]+\./ { capture=0 }
            capture { print }
        ' "$RUNBOOK_MD")
        MISSING=""
        echo "$BLOCK" | grep -qE "\*\*触发条件\*\*"     || MISSING="$MISSING 触发条件"
        echo "$BLOCK" | grep -qE "\*\*根因\*\*"         || MISSING="$MISSING 根因"
        echo "$BLOCK" | grep -qE "\*\*修复\*\*"         || MISSING="$MISSING 修复"
        echo "$BLOCK" | grep -qE "\*\*验证修复成功\*\*" || MISSING="$MISSING 验证修复成功"
        if [ -z "$MISSING" ]; then
            pass "trap $n: 4 字段齐"
        else
            fail "trap $n 缺字段:$MISSING"
        fi
    done
else
    warn "无 trap,跳过 V6"
fi

# ============================================================
# V7: R 规则违反扫描(R7 huggingface-cli / R6 --no-cache-dir)
# ============================================================
echo
echo "[V7] R 规则违反扫描"
if grep -qE "huggingface-cli\s+(download|upload|login)" "$RUNBOOK_MD"; then
    fail "R7 违反: 命中 huggingface-cli 命令,必须替换为 hf"
    grep -nE "huggingface-cli\s+(download|upload|login)" "$RUNBOOK_MD" | sed 's/^/    /'
else
    pass "R7: 无 huggingface-cli 命令"
fi

if grep -qE "pip\s+install\s+.*--no-cache-dir" "$RUNBOOK_MD"; then
    fail "R6 违反: 命中 pip install --no-cache-dir,launch_worker 已 env 隔离 cache"
    grep -nE "pip\s+install\s+.*--no-cache-dir" "$RUNBOOK_MD" | sed 's/^/    /'
else
    pass "R6: 无 pip install --no-cache-dir"
fi

# ============================================================
# V8: 敏感信息扫描
# ============================================================
echo
echo "[V8] 敏感信息扫描"
if grep -qE "hf_[a-zA-Z0-9]{30,}" "$RUNBOOK_MD"; then
    fail "HF_TOKEN 真实值泄露"
else
    pass "无 HF_TOKEN 泄露"
fi
if grep -qE "sk-ant-[a-zA-Z0-9_-]{20,}" "$RUNBOOK_MD"; then
    fail "Anthropic key 泄露"
else
    pass "无 Anthropic key 泄露"
fi
if grep -qF "/root/ai-auto-harness/" "$RUNBOOK_MD"; then
    fail "绝对路径 /root/ai-auto-harness/ 泄露(应用 \${HARNESS_ROOT}/ 占位符)"
    grep -nF "/root/ai-auto-harness/" "$RUNBOOK_MD" | head -3 | sed 's/^/    /'
else
    pass "无绝对路径泄露"
fi

# ============================================================
# 汇总
# ============================================================
echo
echo "=== 汇总 ==="
if [ $FAIL -eq 0 ]; then
    echo "✅ 全部通过"
    exit 0
else
    echo "❌ $FAIL 项失败"
    exit 1
fi
