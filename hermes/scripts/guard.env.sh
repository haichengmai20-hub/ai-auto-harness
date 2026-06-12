# guard.env.sh — Hermes 版 R 规则软拦截层(替代 CC PostToolUse hook,迁移方案"难题1"方案A)
#
# 加载方式(双轨,任一生效即可):
#   1) BASH_ENV=/root/ai-auto-harness/hermes/scripts/guard.env.sh
#      (install.sh 写入 ~/.hermes/.env + config.yaml terminal.env_passthrough)
#      → 每个非交互 bash 启动时自动 source
#   2) skill 命令模板显式 `source /root/ai-auto-harness/hermes/scripts/guard.env.sh`
#      (各阶段 reference 的"第0步"已内置,双保险)
#
# 激活条件:PWD 在 /root/ai-auto-harness 树内,或 AI_HARNESS_GUARD=1。
# 树外零行为变化(不影响 Hermes 其他用途,如 ai-daily-scan)。
# 平台自有脚本(preflight/monitor 等)设 AI_HARNESS_GUARD_SKIP=1 防自触发。
#
# 拦截能力(违规写 state/guard-violations.log + stderr 警告 → 出现在工具结果里,LLM 能看到):
#   R4  sleep >60s        → 警告 + 截断为 60s
#   R1  kill 非自有 PID    → 拒绝(exit 125)
#   R6  pip --no-cache-dir → 警告 + 自动剥除该 flag
#   R11 git checkout/switch(无 `--`) → 拒绝(exit 125)
#   R7  huggingface-cli   → 警告 + 自动改用 hf
# 此为 ~50-80% 约束力的软层;事后审计由 harness-postflight.sh 补(方案D)。
# 长期方案 C(给 Hermes 提 PostToolUse hook PR)见 docs/migration-to-hermes.md 难题1。

# ---- 激活判定 ----
if [ "${AI_HARNESS_GUARD_SKIP:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
case "${PWD:-}" in
    /root/ai-auto-harness*) : ;;
    *)
        if [ "${AI_HARNESS_GUARD:-0}" != "1" ]; then
            return 0 2>/dev/null || exit 0
        fi
        ;;
esac
if [ -n "${_AI_HARNESS_GUARD_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_AI_HARNESS_GUARD_LOADED=1

_GUARD_HARNESS_ROOT="/root/ai-auto-harness"
_GUARD_LOG="$_GUARD_HARNESS_ROOT/state/guard-violations.log"
mkdir -p "$_GUARD_HARNESS_ROOT/state" 2>/dev/null || true

# 心跳:preflight 用 mtime 判断"是否有 agent 在跑"(替代 CC daily.sh 的 flock 全程持锁)
touch "$_GUARD_HARNESS_ROOT/state/agent-heartbeat" 2>/dev/null || true

# 恢复正典环境(Hermes terminal sandbox 可能剥除 env;.env 是代理/HF_TOKEN 唯一真相源)
# 🔴 严禁 unset proxy / 把外网域名加进 no_proxy — 本机无直连外网(fix #36)
if [ -z "${HF_TOKEN:-}" ] || [ -z "${http_proxy:-}" ]; then
    if [ -f "$_GUARD_HARNESS_ROOT/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$_GUARD_HARNESS_ROOT/.env"
        set +a
    fi
fi
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export HF_HUB_DOWNLOAD_CONCURRENCY="${HF_HUB_DOWNLOAD_CONCURRENCY:-2}"

_guard_warn() {
    echo "$(date -Iseconds) pid=$$ pwd=$PWD $1" >> "$_GUARD_LOG" 2>/dev/null || true
    echo "⚠️ [R-guard] $1" >&2
}

# ---- R4: sleep ≤ 60s ----
sleep() {
    local total=0 a v
    for a in "$@"; do
        v="$a"
        case "$v" in
            *m) v=$(( ${v%m} * 60 )) 2>/dev/null || v=0 ;;
            *h) v=$(( ${v%h} * 3600 )) 2>/dev/null || v=0 ;;
            *s) v="${v%s}" ;;
        esac
        v="${v%%.*}"
        case "$v" in ''|*[!0-9]*) v=0 ;; esac
        total=$(( total + v ))
    done
    if [ "$total" -gt 60 ]; then
        _guard_warn "R4 VIOLATION: sleep ${total}s 超过 60s 单次上限,已截断为 60s。长等待用 terminal(background=true, notify_on_complete=true) 或 paused_in_progress return 让下次 cron 接续(便宜 1000 倍)"
        command sleep 60
    else
        command sleep "$@"
    fi
}

# ---- R1: kill 只许动自有 PID ----
kill() {
    local arg pid ok p i
    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
            ''|*[!0-9]*) continue ;;
        esac
        pid="$arg"
        ok=0
        # 1) PID 登记在某个 workspace 的 pid 文件里 → 自有
        if grep -qsx "$pid" "$_GUARD_HARNESS_ROOT"/workspace/*/.cache/*.pid 2>/dev/null; then
            ok=1
        fi
        # 2) 是当前 shell 的后代 → 自有
        if [ "$ok" = "0" ]; then
            p="$pid"; i=0
            while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$i" -lt 25 ]; do
                if [ "$p" = "$$" ]; then ok=1; break; fi
                p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
                i=$((i+1))
            done
        fi
        if [ "$ok" = "0" ]; then
            _guard_warn "R1 VIOLATION: 拒绝 kill $pid — 不在任何 workspace/*/.cache/*.pid 登记内,也不是当前 shell 后代。GPU 上的占用是用户训练进程,严禁动。起后台进程后立刻 echo \$! > \$WORKSPACE/.cache/<task>.pid"
            return 125
        fi
    done
    command kill "$@"
}

# ---- R6: pip 禁 --no-cache-dir(剥除 + 警告) ----
_guard_pip() {
    local bin="$1"; shift
    local had=0 a
    local args=()
    for a in "$@"; do
        if [ "$a" = "--no-cache-dir" ]; then had=1; continue; fi
        args+=("$a")
    done
    if [ "$had" = "1" ]; then
        _guard_warn "R6 VIOLATION: pip --no-cache-dir 已自动剥除 — PIP_CACHE_DIR 已 env 隔离,加它只会反复重下 wheel 抢带宽"
    fi
    command "$bin" "${args[@]}"
}
pip()  { _guard_pip pip  "$@"; }
pip3() { _guard_pip pip3 "$@"; }

# ---- R11: 禁 git checkout/switch 切分支(git checkout -- <file> 豁免) ----
git() {
    local a sub="" has_dd=0
    for a in "$@"; do
        [ "$a" = "--" ] && has_dd=1
    done
    for a in "$@"; do
        case "$a" in -*) continue ;; esac
        sub="$a"; break
    done
    if { [ "$sub" = "checkout" ] || [ "$sub" = "switch" ]; } && [ "$has_dd" = "0" ]; then
        _guard_warn "R11 VIOLATION: 拒绝 git $sub — 切分支会丢掉已打的修复补丁且新分支结构可能不兼容(SCAIL 实测)。恢复单文件用 git checkout -- <file>;当前分支跑不通 → paused_for_human 并把分支建议写进 next_steps_suggested"
        return 125
    fi
    command git "$@"
}

# ---- R7: huggingface-cli → hf ----
huggingface-cli() {
    _guard_warn "R7: huggingface-cli 已废弃,已自动改用 hf 执行"
    command hf "$@"
}
