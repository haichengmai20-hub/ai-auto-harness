#!/usr/bin/env bash
# validate-verify.sh — verify-agent 产出 verify.json schema 验收
#
# 用法:
#   bash scripts/validate-verify.sh <workspace_path>
#   bash scripts/validate-verify.sh workspace/song-generation-run2
#
# 退出码: 0=schema 合法 / 非 0=schema 违规
#
# 起因: 2026-05-26 L1 实测 hunyuan3d-2 + omnivoice 的 verify.json 用了自创 schema
# (status+checks / status+verdict),根字段缺 passed,下游 cleanup G4 jq 拿到 null
# 误判 verify_not_passed。本脚本机器化拦截。

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <workspace_path>" >&2
    exit 2
fi

WORKSPACE="$1"
VFILE="$WORKSPACE/results/verify.json"
FAIL=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== validate-verify ==="
echo "  workspace: $WORKSPACE"
echo "  verify.json: $VFILE"
echo

# ============================================================
# V1: 文件存在 + 合法 JSON
# ============================================================
echo "[V1] 文件存在 + 合法 JSON"
[ -f "$VFILE" ] && pass "verify.json 存在" || { fail "verify.json 不存在"; exit 1; }
jq empty "$VFILE" 2>/dev/null && pass "JSON 语法合法" || { fail "JSON 语法非法"; exit 1; }

# ============================================================
# V2: 6 个必填根字段都在(防自创 schema)
# ============================================================
echo
echo "[V2] 6 个根字段(防 LLM 自创 schema)"
for f in passed failed_at evidence notes confidence completed_at; do
    if jq -e --arg k "$f" 'has($k)' "$VFILE" >/dev/null 2>&1; then
        pass "字段 .$f 存在"
    else
        fail "字段 .$f 缺失(L1 实测 hunyuan3d-2/omnivoice 因此踩坑)"
    fi
done

# ============================================================
# V3: passed 类型必须是 boolean(不许 null / 字符串)
# ============================================================
echo
echo "[V3] .passed 字段类型"
PASSED_TYPE=$(jq -r '.passed | type' "$VFILE" 2>/dev/null)
PASSED_VAL=$(jq -r '.passed' "$VFILE" 2>/dev/null)
case "$PASSED_TYPE" in
    boolean)
        pass ".passed = $PASSED_VAL (boolean, 合法)"
        ;;
    null)
        fail ".passed = null — 下游 cleanup G4 / auto-status 会误判 verify_not_passed"
        ;;
    *)
        fail ".passed 类型是 $PASSED_TYPE (应为 boolean),实际值: $PASSED_VAL"
        ;;
esac

# ============================================================
# V4: failed_at 一致性(passed=true 时应为 null;passed=false 时应为字符串)
# ============================================================
echo
echo "[V4] .failed_at 与 .passed 一致性"
FAILED_AT_TYPE=$(jq -r '.failed_at | type' "$VFILE" 2>/dev/null)
if [ "$PASSED_VAL" = "true" ]; then
    if [ "$FAILED_AT_TYPE" = "null" ]; then
        pass "passed=true + failed_at=null (一致)"
    else
        fail "passed=true 但 failed_at 不是 null (type=$FAILED_AT_TYPE) — 矛盾"
    fi
elif [ "$PASSED_VAL" = "false" ]; then
    if [ "$FAILED_AT_TYPE" = "string" ]; then
        FA=$(jq -r '.failed_at' "$VFILE")
        pass "passed=false + failed_at=\"$FA\" (一致)"
    else
        fail "passed=false 但 failed_at 不是字符串 (type=$FAILED_AT_TYPE) — 应说明哪步失败"
    fi
fi

# ============================================================
# V5: confidence 取值
# ============================================================
echo
echo "[V5] .confidence 取值"
CONF=$(jq -r '.confidence' "$VFILE" 2>/dev/null)
case "$CONF" in
    high|medium|low) pass "confidence=$CONF (合法)" ;;
    *)               fail "confidence=$CONF (应为 high|medium|low)" ;;
esac

# ============================================================
# 汇总
# ============================================================
echo
echo "=== 汇总 ==="
if [ $FAIL -eq 0 ]; then
    echo "✅ schema 合法"
    exit 0
else
    echo "❌ $FAIL 项违规"
    exit 1
fi
