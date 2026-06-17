#!/bin/bash
# workspace-stats.sh — 统计每个 workspace 项目的磁盘占用 + 自动清理 archived 项目
#
# 用法:
#   bash scripts/workspace-stats.sh              # 只统计，不清理
#   bash scripts/workspace-stats.sh --cleanup     # 统计 + 清理 archived/done 项目
#   bash scripts/workspace-stats.sh --cleanup --force  # 不问直接清
#
# 清理规则:
#   - 只清理 state.json 中 phase=archived 或 (phase=done 且 status=done) 的项目
#   - 保留 state.json + results/ 目录（审计用）
#   - 删除: venv/ .cache/ repo/（源码+权重+环境，占空间大头）
#   - 保留 pending_human/ 中的文件（等人项目不碰）
#
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS_DIR="$HARNESS_ROOT/workspace"
DO_CLEANUP=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --cleanup) DO_CLEANUP=true ;;
        --force)   FORCE=true ;;
    esac
done

if [ ! -d "$WS_DIR" ]; then
    echo "workspace/ 目录不存在"
    exit 0
fi

echo "=== Workspace 磁盘统计 ==="
echo ""

total_size=0
total_projects=0
archived_projects=0
archived_size=0

for slug_dir in "$WS_DIR"/*/; do
    [ -d "$slug_dir" ] || continue
    slug=$(basename "$slug_dir")
    
    # 计算目录大小
    size_bytes=$(du -sb "$slug_dir" 2>/dev/null | awk '{print $1}')
    size_mb=$((size_bytes / 1024 / 1024))
    total_size=$((total_size + size_bytes))
    total_projects=$((total_projects + 1))
    
    # 读 state.json
    phase="?"
    status="?"
    state_file="$slug_dir/state.json"
    if [ -f "$state_file" ]; then
        phase=$(jq -r '.phase // "?"' "$state_file" 2>/dev/null || echo "?")
        status=$(jq -r '.status // "?"' "$state_file" 2>/dev/null || echo "?")
    fi
    
    # 判断是否可清理
    can_cleanup=false
    if [ "$phase" = "archived" ] || ([ "$phase" = "done" ] && [ "$status" = "done" ]); then
        can_cleanup=true
        archived_projects=$((archived_projects + 1))
        archived_size=$((archived_size + size_bytes))
    fi
    
    # pending_human 检查
    is_pending=false
    if [ -f "$HARNESS_ROOT/pending_human/$slug.md" ]; then
        is_pending=true
        can_cleanup=false  # 等人项目不碰
    fi
    
    # 格式化输出
    size_str="${size_mb}MB"
    if [ "$size_mb" -ge 1024 ]; then
        size_str="$((size_mb / 1024))GB"
    fi
    
    cleanup_mark=""
    if $can_cleanup; then
        cleanup_mark=" [可清理]"
    fi
    pending_mark=""
    if $is_pending; then
        pending_mark=" [等人]"
    fi
    
    printf "  %-25s %8s  phase=%-15s status=%-10s%s%s\n" \
        "$slug" "$size_str" "$phase" "$status" "$cleanup_mark" "$pending_mark"
done

echo ""
echo "--- 汇总 ---"
total_mb=$((total_size / 1024 / 1024))
archived_mb=$((archived_size / 1024 / 1024))
echo "  总项目: $total_projects"
echo "  总占用: $((total_mb / 1024))GB (${total_mb}MB)"
echo "  可清理: $archived_projects 个项目, $((archived_mb / 1024))GB (${archived_mb}MB)"

# 磁盘剩余
free_gb=$(df -BG "$HARNESS_ROOT" | awk 'NR==2 {gsub("G","",$4); print $4}')
echo "  磁盘剩余: ${free_gb}GB"

if [ "$archived_projects" -gt 0 ]; then
    echo ""
    echo "  清理后预计剩余: $((free_gb + archived_mb / 1024))GB"
fi

# === 清理 ===
if ! $DO_CLEANUP || [ "$archived_projects" -eq 0 ]; then
    if $DO_CLEANUP && [ "$archived_projects" -eq 0 ]; then
        echo ""
        echo "没有可清理的项目"
    fi
    exit 0
fi

echo ""
echo "=== 清理 archived/done 项目 ==="
echo ""

freed_total=0

for slug_dir in "$WS_DIR"/*/; do
    [ -d "$slug_dir" ] || continue
    slug=$(basename "$slug_dir")
    
    # 跳过 pending_human
    if [ -f "$HARNESS_ROOT/pending_human/$slug.md" ]; then
        continue
    fi
    
    state_file="$slug_dir/state.json"
    [ -f "$state_file" ] || continue
    
    phase=$(jq -r '.phase // "?"' "$state_file" 2>/dev/null || echo "?")
    status=$(jq -r '.status // "?"' "$state_file" 2>/dev/null || echo "?")
    
    # 只清理 archived 或 done/done
    if [ "$phase" != "archived" ] && ! ([ "$phase" = "done" ] && [ "$status" = "done" ]); then
        continue
    fi
    
    # 计算可释放空间（venv + .cache + repo）
    cleanup_bytes=0
    for subdir in venv .cache repo; do
        if [ -d "$slug_dir/$subdir" ]; then
            sub_bytes=$(du -sb "$slug_dir/$subdir" 2>/dev/null | awk '{print $1}')
            cleanup_bytes=$((cleanup_bytes + sub_bytes))
        fi
    done
    cleanup_mb=$((cleanup_bytes / 1024 / 1024))
    
    if [ "$cleanup_bytes" -eq 0 ]; then
        echo "  $slug: 无需清理（venv/.cache/repo 已不存在）"
        continue
    fi
    
    # 确认
    if ! $FORCE; then
        echo -n "  清理 $slug (释放 ${cleanup_mb}MB)? [y/N] "
        read -r answer
        case "$answer" in
            [yY]*) ;;
            *) echo "  跳过"; continue ;;
        esac
    fi
    
    # 执行清理：删 venv/ .cache/ repo/，保留 state.json + results/ + logs/
    for subdir in venv .cache repo; do
        if [ -d "$slug_dir/$subdir" ]; then
            rm -rf "$slug_dir/$subdir"
            echo "    删除 $subdir/"
        fi
    done
    
    freed_total=$((freed_total + cleanup_bytes))
    echo "  ✅ $slug 清理完成 (释放 ${cleanup_mb}MB)"
done

echo ""
freed_mb=$((freed_total / 1024 / 1024))
echo "总计释放: $((freed_mb / 1024))GB (${freed_mb}MB)"
