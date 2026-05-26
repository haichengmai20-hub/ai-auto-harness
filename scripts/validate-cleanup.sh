#!/usr/bin/env bash
# validate-cleanup.sh — cleanup-deployed-workspace 产出验收脚本
#
# 用法:
#   bash scripts/validate-cleanup.sh <workspace_path> <expected_mode>
#   bash scripts/validate-cleanup.sh workspace/song-generation-run2 dry_run
#   bash scripts/validate-cleanup.sh workspace/song-generation-run2 production
#
# expected_mode 决定校验逻辑:
#   - dry_run:    cleanup.json 应有 would_remove 字段,state.json 仍 phase=done
#   - production: cleanup.json 应有 removed 字段,state.json 已 phase=archived

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <workspace_path> <dry_run|production>" >&2
    exit 2
fi

WORKSPACE="$1"
EXPECTED_MODE="$2"
FAIL=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  $1"; }

CLEANUP_JSON="$WORKSPACE/results/cleanup.json"
CLEANUP_LOG="$WORKSPACE/logs/cleanup.log"
STATE_JSON="$WORKSPACE/state.json"

echo "=== validate-cleanup ==="
echo "  workspace:     $WORKSPACE"
echo "  expected_mode: $EXPECTED_MODE"
echo

# ============================================================
# V1: 文件存在
# ============================================================
echo "[V1] 必需文件存在"
[ -f "$CLEANUP_JSON" ] && pass "cleanup.json 存在" || { fail "cleanup.json 不存在"; exit 1; }
[ -f "$CLEANUP_LOG" ]  && pass "cleanup.log 存在"  || { fail "cleanup.log 不存在"; exit 1; }
[ -f "$STATE_JSON" ]   && pass "state.json 存在"   || fail "state.json 不存在"

# ============================================================
# V2: PHASE_START / PHASE_END 都在 cleanup.log 里(R8 + P4-1)
# ============================================================
echo
echo "[V2] R8 PHASE_START / PHASE_END 标记"
if grep -qE "^=== PHASE_START phase=cleanup " "$CLEANUP_LOG"; then
    pass "PHASE_START 存在"
else
    fail "PHASE_START 缺失"
fi
if grep -qE "^=== PHASE_END   phase=cleanup .* status=(done|skipped) " "$CLEANUP_LOG"; then
    pass "PHASE_END 存在(R8 + P4-1)"
else
    fail "PHASE_END 缺失(L1 实测漏写过 — 检查 tee -a 是否生效)"
fi

# ============================================================
# V3: cleanup.json schema 校验(dry_run vs production 不同字段)
# ============================================================
echo
echo "[V3] cleanup.json schema"
DRY_RUN_VAL=$(python3 -c "import json; print(json.load(open('$CLEANUP_JSON'))['dry_run'])" 2>/dev/null || echo "MISSING")
echo "  dry_run = $DRY_RUN_VAL"

case "$EXPECTED_MODE" in
    dry_run)
        [ "$DRY_RUN_VAL" = "True" ] && pass "dry_run=true 与 expected_mode 一致" || fail "expected_mode=dry_run 但 dry_run=$DRY_RUN_VAL"
        if python3 -c "import json; assert 'would_remove' in json.load(open('$CLEANUP_JSON'))" 2>/dev/null; then
            pass "P4-2: dry_run 模式有 would_remove 字段"
        else
            fail "P4-2: dry_run 模式缺 would_remove 字段(语义不准)"
        fi
        if python3 -c "import json; assert 'removed' not in json.load(open('$CLEANUP_JSON'))" 2>/dev/null; then
            pass "P4-2: dry_run 模式无 removed 字段(不混用)"
        else
            warn "P4-2: dry_run 模式不应有 removed 字段"
        fi
        ;;
    production)
        [ "$DRY_RUN_VAL" = "False" ] && pass "dry_run=false 与 expected_mode 一致" || fail "expected_mode=production 但 dry_run=$DRY_RUN_VAL"
        if python3 -c "import json; assert 'removed' in json.load(open('$CLEANUP_JSON'))" 2>/dev/null; then
            pass "production 模式有 removed 字段"
        else
            fail "production 模式缺 removed 字段"
        fi
        ;;
    *)
        fail "expected_mode 必须是 dry_run|production"
        exit 2
        ;;
esac

# 必填字段
for field in slug skipped_not_exist kept freed_bytes freed_gib freed_human run_cache_freed_bytes run_cache_removed runbook_path completed_at; do
    if python3 -c "import json; assert '$field' in json.load(open('$CLEANUP_JSON'))" 2>/dev/null; then
        pass "字段 $field 存在"
    else
        fail "字段 $field 缺失"
    fi
done

# ============================================================
# V4: P4-4 freed_gib 单位与 freed_bytes/(1024^3) 一致
# ============================================================
echo
echo "[V4] P4-4 freed_gib 单位一致性"
python3 <<PY
import json, sys
d = json.load(open('$CLEANUP_JSON'))
fb = d.get('freed_bytes', 0)
fg = d.get('freed_gib', 0.0)
expected = round(fb / 1073741824, 2)
ok = abs(expected - fg) < 0.01
print(f"  freed_bytes={fb} → expected freed_gib={expected}, actual={fg}")
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then
    pass "freed_gib 与 freed_bytes/(1024^3) 一致"
else
    fail "freed_gib 与 bytes 不一致"
fi

# ============================================================
# V5: 白名单遍历完整(P4-6: 每个 target 都在 log 里有记录)
# ============================================================
echo
echo "[V5] P4-6 白名单遍历完整(venv / .cache / hf_cache / repo 每个都在 log 里)"
for target in venv .cache hf_cache repo; do
    # log 应该写了 removed/would rm/skipped/NOT EXIST 中的一个
    if grep -qE "(removed|would rm -rf|skipped).+/$target( |\$|\b)" "$CLEANUP_LOG" || \
       grep -qE "/$target.+NOT EXIST" "$CLEANUP_LOG"; then
        pass "target $target 有处理记录"
    else
        fail "P4-6: target $target 在 cleanup.log 无任何记录(漏遍历)"
    fi
done

# ============================================================
# V6: 保留清单未被误删
# ============================================================
echo
echo "[V6] 保留清单(state.json/results/logs/output)未被误删"
for keep in state.json results logs; do
    if [ -e "$WORKSPACE/$keep" ]; then
        pass "保留 $keep ✓"
    else
        fail "$keep 被误删!"
    fi
done

# ============================================================
# V7: state.json 状态(production 模式应该 archived)
# ============================================================
echo
echo "[V7] state.json 状态"
if [ -f "$STATE_JSON" ]; then
    PHASE=$(python3 -c "import json; print(json.load(open('$STATE_JSON')).get('phase','MISSING'))" 2>/dev/null)
    case "$EXPECTED_MODE" in
        production)
            [ "$PHASE" = "archived" ] && pass "state.phase=archived" || fail "production 模式 state.phase 应为 archived, 实际=$PHASE"
            if python3 -c "import json; d=json.load(open('$STATE_JSON')); assert 'archived_at' in d and 'freed_bytes' in d" 2>/dev/null; then
                pass "state.json 有 archived_at + freed_bytes"
            else
                fail "state.json 缺 archived_at 或 freed_bytes"
            fi
            ;;
        dry_run)
            [ "$PHASE" != "archived" ] && pass "dry_run 模式 state.phase 未改 ($PHASE)" || fail "dry_run 模式不应改 state.phase 到 archived"
            ;;
    esac
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
