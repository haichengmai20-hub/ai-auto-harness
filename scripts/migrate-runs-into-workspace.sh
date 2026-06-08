#!/bin/bash
# migrate-runs-into-workspace.sh — 把全局 runs/<id> 的"项目 run"迁移到 workspace/<slug>/runs/<id>
# (Fix: 2026-06-08-run-dir-into-workspace)
#
# 🔴 安全边界(为什么不是 prompt 里那个裸 mv 循环):
#   - 跳过任何 worker.pid 仍存活的 run(live;迁移会破坏正在写入的 worker,违反 R1)
#   - 只迁移能映射到**现有 workspace** 的 run(slug 取自 meta.json.slug,fallback 名字最长前缀匹配)
#   - 不创建新 workspace;无映射的(test fixture / scan-e2e / cron / 交互式自造 id)留在全局
#   - 目标已存在同名 run → 跳过(不覆盖)
#   - 幂等:可重复跑;5 个 live worker 结束后再跑一次即可补迁
#
# 用法:
#   bash scripts/migrate-runs-into-workspace.sh --dry-run   # 预览,不动
#   bash scripts/migrate-runs-into-workspace.sh             # 实际迁移 dead run
set -u
HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
cd "$HARNESS_ROOT" || exit 1

DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

# 现有 workspace slug 列表,按长度降序(让 song-generation-run2 先于 song-generation 匹配)
mapfile -t SLUGS < <(find workspace -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
    | awk '{print length"\t"$0}' | sort -rn | cut -f2-)

is_alive() { local pid="$1"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

moved=0; live=0; nomap=0; exists=0
for run_dir in runs/*/; do
    run_dir="${run_dir%/}"
    [ -d "$run_dir" ] || continue
    id="$(basename "$run_dir")"

    # 1) live 检查:worker.pid 还活着就绝不动
    if [ -f "$run_dir/worker.pid" ]; then
        pid="$(cat "$run_dir/worker.pid" 2>/dev/null)"
        if is_alive "$pid"; then
            echo "SKIP  live    $id (worker.pid=$pid alive)"; live=$((live+1)); continue
        fi
    fi

    # 2) slug:从 meta.json 抓 "slug" 字段。注意 launch_worker 在 JSON 闭合后又 append 了
    #    "isolated cache: ..." 等非 JSON 行,故不能 json.load,直接 grep 抓字段最稳。
    slug=""
    if [ -f "$run_dir/meta.json" ]; then
        slug="$(grep -m1 -oE '"slug"[[:space:]]*:[[:space:]]*"[^"]+"' "$run_dir/meta.json" 2>/dev/null \
            | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/')"
    fi
    # 3) fallback:名字最长前缀匹配(去掉 e2e- 前缀)
    if [ -z "$slug" ]; then
        name_norm="${id#e2e-}"
        for s in "${SLUGS[@]}"; do
            case "$name_norm" in "$s"|"$s"-*|"$s"_*) slug="$s"; break;; esac
        done
    fi

    # 4) 校验:slug 非空且对应 workspace 存在,否则留在全局
    if [ -z "$slug" ] || [ ! -d "workspace/$slug" ]; then
        echo "SKIP  no-map  $id (slug='${slug:-?}' 无对应 workspace)"; nomap=$((nomap+1)); continue
    fi

    target="workspace/$slug/runs/$id"
    if [ -e "$target" ]; then
        echo "SKIP  exists  $id -> $target 已存在"; exists=$((exists+1)); continue
    fi

    if $DRY; then
        echo "[DRY] would mv $run_dir -> $target"
    else
        mkdir -p "workspace/$slug/runs"
        if mv "$run_dir" "$target"; then
            echo "MOVED $id -> $target"
        else
            echo "ERROR mv 失败:$run_dir -> $target"; continue
        fi
    fi
    moved=$((moved+1))
done

echo "---"
echo "migrate summary: moved=$moved skipped_live=$live skipped_nomap=$nomap skipped_exists=$exists (dry_run=$DRY)"
