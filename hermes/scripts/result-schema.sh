#!/bin/bash
# result-schema.sh — 统一 phase result JSON schema
#
# 所有 phase 脚本 source 此文件,保证输出格式一致。
#
# 必选字段:
#   phase           string  阶段名(intake/fetch-weights/install-env/run-and-repair/verify/runbook/cleanup)
#   status          string  done|failed|paused_in_progress|paused_for_human|blocked
#   duration_seconds number 从 phase 开始到结束的秒数
#   fixes_applied   array   修复动作列表(如 ["pip_install_torch", "path_fix_img10.jpg"])
#   warnings        array   警告列表
#   error_class     string|null 错误类别(如 cuda_oom/dep_missing/file_not_found)
#   error_detail    string|null 错误详情(一行摘要)
#   completed_at    string  ISO 时间戳
#
# Phase-specific 字段放在 phase_specific 对象里,不污染顶层。
#
# 用法:
#   source /root/ai-auto-harness/hermes/scripts/result-schema.sh
#   START_TS=$(date +%s)
#   ... phase 逻辑 ...
#   write_result "$RESULT_FILE" "$PHASE" "$STATUS" "$START_TS" \
#     "$FIXES_APPLIED_JSON" "$WARNINGS_JSON" "$ERROR_CLASS" "$ERROR_DETAIL" "$PHASE_SPECIFIC_JSON"

# 初始化空 JSON 数组(在 phase 脚本开头调用)
init_result_vars() {
  FIXES_APPLIED='[]'
  WARNINGS='[]'
  ERROR_CLASS='null'
  ERROR_DETAIL='null'
  PHASE_SPECIFIC='{}'
}

# 添加一个 fix
add_fix() {
  local fix="$1"
  FIXES_APPLIED=$(echo "$FIXES_APPLIED" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('$fix'); print(json.dumps(a))")
}

# 添加一个 warning
add_warning() {
  local warn="$1"
  WARNINGS=$(echo "$WARNINGS" | python3 -c "import sys,json; a=json.loads(sys.stdin.read()); a.append('$warn'); print(json.dumps(a))")
}

# 写 result JSON
write_result() {
  local outfile="$1"
  local phase="$2"
  local status="$3"
  local start_ts="$4"
  local fixes="$5"
  local warnings="$6"
  local error_class="$7"
  local error_detail="$8"
  local phase_specific="$9"

  local duration=$(( $(date +%s) - start_ts ))
  local completed_at=$(date -Iseconds)

  python3 << PYEOF
import json

result = {
    "phase": "$phase",
    "status": "$status",
    "duration_seconds": $duration,
    "fixes_applied": json.loads('''$fixes'''),
    "warnings": json.loads('''$warnings'''),
    "error_class": $error_class if "$error_class" != "null" else None,
    "error_detail": $error_detail if "$error_detail" != "null" else None,
    "completed_at": "$completed_at",
    "phase_specific": json.loads('''$phase_specific''')
}

with open("$outfile", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

# 验证必选字段
required = ["phase", "status", "duration_seconds", "fixes_applied", "warnings", "error_class", "error_detail", "completed_at"]
for r in required:
    assert r in result, f"Missing required field: {r}"

print(f"[result] $phase: status=$status duration=${duration}s")
PYEOF
}
