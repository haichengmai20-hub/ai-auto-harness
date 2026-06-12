#!/bin/bash
# install.sh — 把 ai-auto-harness Hermes 版装进 ~/.hermes
# 用法:
#   bash hermes/install.sh             # 装 skill/scripts/AGENTS.md/guard 接线,打印 cron 命令(不注册)
#   bash hermes/install.sh --register-cron   # 同时注册 4 个 cron job(daily 会真跑,先停 CC crontab!)
#   bash hermes/install.sh --uninstall # 还原
set -euo pipefail

HARNESS_ROOT="/root/ai-auto-harness"
SRC="$HARNESS_ROOT/hermes"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

[ -d "$HERMES_HOME" ] || { echo "FATAL: $HERMES_HOME 不存在(先装 hermes-agent)"; exit 1; }
command -v hermes >/dev/null || { echo "FATAL: hermes CLI 不在 PATH"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: 需要 jq"; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "$HERMES_HOME/skills/ai-auto-harness"
    rm -f "$HERMES_HOME/scripts/harness-preflight.sh" "$HERMES_HOME/scripts/harness-postflight.sh" \
          "$HERMES_HOME/scripts/monitor-poll.sh" "$HERMES_HOME/scripts/pending-human-notify.sh"
    [ -L "$HARNESS_ROOT/AGENTS.md" ] && rm -f "$HARNESS_ROOT/AGENTS.md"
    echo "已卸载(~/.hermes/.env 的 BASH_ENV 行与 config.yaml 的 env_passthrough 请手动检查/移除;cron job 用 hermes cron list / remove 清)"
    exit 0
fi

echo "== 1/5 安装 skill =="
mkdir -p "$HERMES_HOME/skills"
rm -rf "$HERMES_HOME/skills/ai-auto-harness"
cp -r "$SRC/skills/ai-auto-harness" "$HERMES_HOME/skills/ai-auto-harness"
echo "  → $HERMES_HOME/skills/ai-auto-harness/ ($(find "$HERMES_HOME/skills/ai-auto-harness" -name '*.md' | wc -l) 个 md)"

echo "== 2/5 安装 cron 脚本(symlink,保持与 repo 同步) =="
mkdir -p "$HERMES_HOME/scripts"
for s in harness-preflight.sh harness-postflight.sh monitor-poll.sh pending-human-notify.sh; do
    ln -sfn "$SRC/scripts/$s" "$HERMES_HOME/scripts/$s"
    echo "  → $HERMES_HOME/scripts/$s"
done

echo "== 3/5 AGENTS.md symlink(workdir 注入,压住根 CLAUDE.md) =="
ln -sfn "$SRC/AGENTS.md" "$HARNESS_ROOT/AGENTS.md"
echo "  → $HARNESS_ROOT/AGENTS.md"

echo "== 4/5 guard 接线(BASH_ENV 双轨之一;另一轨是 playbook 内显式 source) =="
ENVF="$HERMES_HOME/.env"
touch "$ENVF"
if ! grep -q "^BASH_ENV=" "$ENVF"; then
    echo "BASH_ENV=$SRC/scripts/guard.env.sh" >> "$ENVF"
    echo "  → $ENVF 追加 BASH_ENV(guard 树外零行为变化)"
else
    echo "  → $ENVF 已有 BASH_ENV,跳过"
fi
# config.yaml: terminal.env_passthrough 放行 BASH_ENV / HF_TOKEN / 代理变量(沙箱默认剥除)
python3 - "$HERMES_HOME/config.yaml" <<'PY'
import sys, yaml, shutil
path = sys.argv[1]
need = ["BASH_ENV", "HF_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        "HF_HUB_DISABLE_XET", "HF_HUB_DOWNLOAD_CONCURRENCY"]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
cur = cfg.setdefault("terminal", {}).setdefault("env_passthrough", [])
added = [v for v in need if v not in cur]
if added:
    shutil.copy2(path, path + ".bak-aiharness")
    cur.extend(added)
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)
    print(f"  → config.yaml env_passthrough += {added}(原文件备份 .bak-aiharness)")
else:
    print("  → config.yaml env_passthrough 已齐,跳过")
PY

echo "== 5/5 cron job =="
CRON_CMDS=$(cat <<EOF
hermes cron create "0 10 * * *" "执行 ai-auto-harness 日常部署:按 preflight 摘要接续或选新项目,走 ai-auto-harness skill 的完整工作流。" --name ai-harness-daily --skill ai-auto-harness --script harness-preflight.sh --workdir $HARNESS_ROOT --deliver local
hermes cron create "every 5m" --name ai-harness-monitor --no-agent --script monitor-poll.sh --deliver local
hermes cron create "every 30m" --name ai-harness-pending-human --no-agent --script pending-human-notify.sh --deliver local
hermes cron create "30 13 * * *" --name ai-harness-postflight --no-agent --script harness-postflight.sh --deliver local
EOF
)
if [ "${1:-}" = "--register-cron" ]; then
    if crontab -l 2>/dev/null | grep -vE "^\s*#" | grep -q "daily.sh"; then
        echo "🔴 拒绝注册:系统 crontab 还挂着 CC 版 daily.sh(双驱同一 workspace 会打架)。"
        echo "   先 crontab -e 注释掉 daily.sh 行,再重跑 --register-cron。打印命令供手动用:"
        echo "$CRON_CMDS"
        exit 1
    fi
    echo "$CRON_CMDS" | while IFS= read -r c; do [ -n "$c" ] && eval "$c"; done
    echo "  → 4 个 job 已注册(hermes cron list 查看;hermes cron pause <id> 可暂停)"
else
    echo "  未注册(默认)。确认停掉 CC crontab 的 daily.sh 后,手动执行以下命令或跑 --register-cron:"
    echo "$CRON_CMDS"
fi

echo ""
echo "完成。冒烟验证:"
echo "  bash $HERMES_HOME/scripts/harness-preflight.sh   # 应输出状态摘要"
echo "  hermes chat 里说: 用 ai-auto-harness skill 跑一轮部署(dry:只做任务1-2不派发)"
