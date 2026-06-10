#!/usr/bin/env bash
# clean-old-runs.sh — 全局 runs/ 历史目录保守清理
#
# 问题(Fix: 2026-06-10-external-review-sentinel-wallclock-runs-fix):
#   runs/ 累积 68 目录 / 4.1GB,无自动清理。
#
# 保守策略(宁可少删):
#   只删同时满足: (a) mtime 超过 RETENTION_DAYS(默认 14 天)
#                 (b) 目录小于 SIZE_CAP(默认 100MB — 只回收日志/元数据级目录)
#                 (c) 不在排除清单(用户声明自管的目录,R-HO-2)
#   大目录/排除目录只列入 .last_cleanup.log 供人决策,绝不自动删。
#   默认 dry-run;加 --delete 才真删。
#
# Usage: bash scripts/clean-old-runs.sh [--delete] [HARNESS_ROOT]
set -uo pipefail
DELETE=0
[ "${1:-}" = "--delete" ] && { DELETE=1; shift; }
HARNESS_ROOT="${1:-/root/ai-auto-harness}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
SIZE_CAP_BYTES="${SIZE_CAP_BYTES:-104857600}"   # 100MB

# 🔴 用户声明自行处理的目录(R-HO-2),永不自动删
EXCLUDES="songgen-e2e-run2-20260521-132245 songgen-e2e-20260521-124245"

RUNS_DIR="$HARNESS_ROOT/runs"
LOG="$RUNS_DIR/.last_cleanup.log"
NOW_TS=$(date +%s)
echo "=== $(date -Iseconds) clean-old-runs (delete=$DELETE, retention=${RETENTION_DAYS}d, cap=$((SIZE_CAP_BYTES/1024/1024))MB) ===" | tee -a "$LOG"

CURRENT_RUN_ID=$(cat "$RUNS_DIR/.current_run_id" 2>/dev/null || echo "")
deleted=0; skipped_big=0; kept=0
for d in "$RUNS_DIR"/*/; do
    d="${d%/}"
    name=$(basename "$d")
    [ "$name" = "$CURRENT_RUN_ID" ] && { kept=$((kept+1)); continue; }
    case " $EXCLUDES " in *" $name "*)
        echo "  EXCLUDE(user-owned): $name" | tee -a "$LOG"; continue ;;
    esac
    mtime=$(stat -c %Y "$d" 2>/dev/null || echo "$NOW_TS")
    age_days=$(( (NOW_TS - mtime) / 86400 ))
    [ "$age_days" -lt "$RETENTION_DAYS" ] && { kept=$((kept+1)); continue; }
    size=$(du -sb "$d" 2>/dev/null | awk '{print $1}')
    if [ "${size:-0}" -gt "$SIZE_CAP_BYTES" ]; then
        echo "  SKIP(big $(numfmt --to=iec ${size:-0}), 人决策): $name" | tee -a "$LOG"
        skipped_big=$((skipped_big+1)); continue
    fi
    if [ "$DELETE" -eq 1 ]; then
        rm -rf "$d" && echo "  DELETED(${age_days}d, $(numfmt --to=iec ${size:-0})): $name" | tee -a "$LOG"
        deleted=$((deleted+1))
    else
        echo "  WOULD-DELETE(${age_days}d, $(numfmt --to=iec ${size:-0})): $name" | tee -a "$LOG"
        deleted=$((deleted+1))
    fi
done
echo "=== done: ${deleted} $([ $DELETE -eq 1 ] && echo deleted || echo would-delete), $skipped_big big-skipped, $kept kept ===" | tee -a "$LOG"
