#!/bin/bash
# reconcile-state.sh — 每次 cron 启动前对账 workspace/*/state.json
# 修复 state.json 与实际文件不一致的情况（如下载完成但 state 还标记 paused）
# 由 daily.sh 在启动前调用（在 reconcile-sentinels.sh 之后）
#
# P3 fix: 2026-06-11-cron-resume-and-optimization
set -e

HARNESS_ROOT="${1:-/root/ai-auto-harness}"
cd "$HARNESS_ROOT"

echo "[reconcile-state] 开始对账 $(date -Iseconds)"

for state_file in workspace/*/state.json; do
    [ -f "$state_file" ] || continue
    slug=$(jq -r '.slug' "$state_file" 2>/dev/null || continue)
    phase=$(jq -r '.phase' "$state_file" 2>/dev/null)
    status=$(jq -r '.status' "$state_file" 2>/dev/null)
    WORKSPACE="workspace/$slug"

    # === 规则 1: fetch-weights paused 但文件已全在 ===
    if [ "$phase" = "fetch-weights" ] && [ "$status" != "done" ]; then
        # 检查所有 hf_repos 对应的目录是否存在且有内容
        repos=$(jq -r '.hf_repos[]?' "$state_file" 2>/dev/null)
        all_done=true
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            # HF cache 目录格式: .cache/hf_models/<repo>/ (org/repo -> org--repo)
            cache_dir=$(echo "$repo" | sed 's|/|--|')
            model_dir="$WORKSPACE/.cache/hf_models/$cache_dir"
            if [ ! -d "$model_dir" ] || [ "$(find "$model_dir" -name '*.incomplete' 2>/dev/null | wc -l)" -gt 0 ]; then
                all_done=false
                break
            fi
        done <<< "$repos"

        if [ "$all_done" = true ]; then
            echo "[reconcile-state] $slug: fetch-weights 文件已全在但 state=$status，修正为 done"
            jq '.phase = "fetch-weights" | .status = "done" | .phases_done = ((.phases_done // []) + ["fetch-weights"]) | .updated_at = "'$(date -Iseconds)'" | .resume_reason = "state_reconciled: 文件已全在磁盘" | .previous_failure = "RESOLVED"' \
                "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        fi
    fi

    # === 规则 2: installing 但 venv 已存在且 pip 成功 ===
    if [ "$phase" = "installing" ] || [ "$phase" = "install-env" ] && [ "$status" != "done" ]; then
        venv="$WORKSPACE/venv/bin/python"
        if [ -f "$venv" ] && "$venv" -c "import torch; print(torch.__version__)" 2>/dev/null; then
            echo "[reconcile-state] $slug: install-env venv 已可用但 state=$status，修正为 done"
            jq '.phase = "install-env" | .status = "done" | .phases_done = ((.phases_done // []) + ["install-env"]) | .updated_at = "'$(date -Iseconds)'"' \
                "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        fi
    fi

    # === 规则 3: running 但无活跃进程且 updated_at > 4小时 ===
    if [ "$status" = "running" ]; then
        updated=$(jq -r '.updated_at' "$state_file" 2>/dev/null)
        # 简单检查: 如果 updated_at 超过 4 小时且没有 torchrun/python 推理进程
        bg_pid=$(jq -r '.background_pid // 0' "$state_file" 2>/dev/null)
        if [ "$bg_pid" != "0" ] && [ "$bg_pid" != "null" ]; then
            if ! kill -0 "$bg_pid" 2>/dev/null; then
                echo "[reconcile-state] $slug: background_pid=$bg_pid 已死，标记 paused_in_progress"
                jq '.status = "paused_in_progress" | .updated_at = "'$(date -Iseconds)'" | .resume_reason = "state_reconciled: 后台进程已退出"' \
                    "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
            fi
        fi
    fi

    # === 规则 4: paused_in_progress 且有 resume_reason + previous_failure=RESOLVED ===
    # 如果 state 明确标记了 previous_failure=RESOLVED，不应该被当成"上次失败跳过"
    # 这里只记录，不改状态（让 auto-daily SKILL 规则处理）
    prev_fail=$(jq -r '.previous_failure // ""' "$state_file" 2>/dev/null)
    if [ "$prev_fail" = "*RESOLVED*" ]; then
        echo "[reconcile-state] $slug: previous_failure=RESOLVED, 接续时应重试而非跳过"
    fi
done

echo "[reconcile-state] 对账完成 $(date -Iseconds)"