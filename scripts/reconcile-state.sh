#!/bin/bash
# reconcile-state.sh — 每次 cron 启动前对账 workspace/*/state.json
# 修复 state.json 与实际文件不一致的情况（如下载完成但 state 还标记 paused）
# 由 daily.sh 在启动前调用（在 reconcile-sentinels.sh 之后）
#
# P3 fix: 2026-06-11-cron-resume-and-optimization
# 2026-06-11(二) 审查更正(fix: 2026-06-11-p1-p12-implementation-corrections):
#   - 规则 1 路径错误: DEST 约定是 .cache/hf_models/<org>/<repo>(嵌套),不是 org--repo
#   - 规则 1 加体积下限防"目录在但只下了零头"被误判 done
#   - 规则 2 运算符优先级: || 与 && 同级左结合,原写法 phase=installing 时忽略 status 条件
#   - 规则 4 glob 用 [ = ] 永假,改 case
#   - phases_done 去重(unique),不再写 previous_failure="RESOLVED"(语义归 P8 资源类)
set -e

HARNESS_ROOT="${1:-/root/ai-auto-harness}"
cd "$HARNESS_ROOT"

echo "[reconcile-state] 开始对账 $(date -Iseconds)"

for state_file in workspace/*/state.json; do
    [ -f "$state_file" ] || continue
    slug=$(jq -r '.slug // ""' "$state_file" 2>/dev/null || echo "")
    [ -z "$slug" ] && continue
    phase=$(jq -r '.phase' "$state_file" 2>/dev/null)
    status=$(jq -r '.status' "$state_file" 2>/dev/null)
    WORKSPACE="workspace/$slug"

    # === 规则 1: fetch-weights 未 done 但文件已全在 ===
    if [ "$phase" = "fetch-weights" ] || [ "$phase" = "fetching" ]; then
      if [ "$status" != "done" ] && [ "$status" != "paused_for_human" ]; then
        repos=$(jq -r '.hf_repos[]?' "$state_file" 2>/dev/null)
        est_gb=$(jq -r '.estimated_weight_size_gb // 0' "$state_file" 2>/dev/null)
        all_done=true
        [ -z "$repos" ] && all_done=false
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            # DEST 约定(2026-06-08-fetch-dest-path-not-injected-fix): 嵌套 <org>/<repo>
            model_dir="$WORKSPACE/.cache/hf_models/$repo"
            if [ ! -d "$model_dir" ] \
               || [ "$(find "$model_dir" -name '*.incomplete' 2>/dev/null | wc -l)" -gt 0 ] \
               || [ "$(find "$model_dir" -type f 2>/dev/null | head -1 | wc -l)" -eq 0 ]; then
                all_done=false
                break
            fi
        done <<< "$repos"

        # 体积 sanity: 实际落盘 ≥ 估算 80%(防"无 .incomplete 但整文件缺失"误判 done)
        if [ "$all_done" = true ] && [ "${est_gb%%.*}" -gt 0 ] 2>/dev/null; then
            actual_b=$(du -sb "$WORKSPACE/.cache/hf_models" 2>/dev/null | awk '{print $1}')
            min_b=$(( ${est_gb%%.*} * 1024 * 1024 * 1024 * 8 / 10 ))
            [ "${actual_b:-0}" -lt "$min_b" ] && all_done=false
        fi

        if [ "$all_done" = true ]; then
            echo "[reconcile-state] $slug: fetch-weights 文件已全在但 state=$status，修正为 done"
            jq '.phase = "fetch-weights" | .status = "done"
                | .phases_done = ((.phases_done // []) + ["fetch-weights"] | unique)
                | .updated_at = "'$(date -Iseconds)'"
                | .resume_reason = "state_reconciled: 文件已全在磁盘(含体积校验)"' \
                "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        fi
      fi
    fi

    # === 规则 2: install 阶段未 done 但 venv 已可用 ===
    if { [ "$phase" = "installing" ] || [ "$phase" = "install-env" ]; } \
       && [ "$status" != "done" ] && [ "$status" != "paused_for_human" ]; then
        venv="$WORKSPACE/venv/bin/python"
        if [ -f "$venv" ] && "$venv" -c "import torch" 2>/dev/null; then
            echo "[reconcile-state] $slug: install-env venv 已可用但 state=$status，修正为 done"
            jq '.phase = "install-env" | .status = "done"
                | .phases_done = ((.phases_done // []) + ["install-env"] | unique)
                | .updated_at = "'$(date -Iseconds)'"' \
                "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        fi
    fi

    # === 规则 3: running 但记录的后台 PID 已死 ===
    if [ "$status" = "running" ]; then
        bg_pid=$(jq -r '.background_pid // 0' "$state_file" 2>/dev/null)
        if [ "$bg_pid" != "0" ] && [ "$bg_pid" != "null" ]; then
            # 僵尸(Z)也算死 — 容器 PID 1 不收尸,kill -0 会误判活(同 reconcile-sentinels)
            pstate=$(awk '{print $3}' "/proc/$bg_pid/stat" 2>/dev/null || echo "X")
            if [ "$pstate" = "X" ] || [ "$pstate" = "Z" ]; then
                echo "[reconcile-state] $slug: background_pid=$bg_pid 已死(state=$pstate)，标记 paused_in_progress"
                jq '.status = "paused_in_progress" | .updated_at = "'$(date -Iseconds)'"
                    | .resume_reason = "state_reconciled: 后台进程已退出"' \
                    "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
            fi
        fi
    fi

    # === 规则 4: previous_failure=*_RESOLVED 提示(只记录,auto-daily SKILL P8 规则处理) ===
    prev_fail=$(jq -r '.previous_failure // ""' "$state_file" 2>/dev/null)
    case "$prev_fail" in
        *RESOLVED*) echo "[reconcile-state] $slug: previous_failure=$prev_fail, 接续时应重试而非跳过" ;;
    esac
done

echo "[reconcile-state] 对账完成 $(date -Iseconds)"
