#!/usr/bin/env bash
# validate-artifacts.sh — verify/runbook/cleanup artifacts gate.
#
# Usage:
#   bash scripts/validate-artifacts.sh <workspace_path>
#
# Exit codes:
#   0 = artifacts match the phase/result expectations
#   1 = validation failed
#   2 = usage error
set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <workspace_path>" >&2
    exit 2
fi

WORKSPACE="$1"

python3 - "$WORKSPACE" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
results = workspace / "results"
failures: list[str] = []
warnings: list[str] = []

def load_json(path: pathlib.Path, label: str):
    if not path.exists():
        failures.append(f"{label} missing: {path}")
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        failures.append(f"{label} invalid JSON: {exc}")
        return None

print("=== validate-artifacts ===")
print(f"  workspace: {workspace}")
print(f"  results:   {results}")
print()

if not workspace.exists():
    failures.append(f"workspace missing: {workspace}")
if not results.exists():
    failures.append(f"results dir missing: {results}")

verify = load_json(results / "verify.json", "verify.json") if results.exists() else None
verify_passed = False
if verify is not None:
    required = ["passed", "failed_at", "evidence", "notes", "confidence", "verify_level", "completed_at"]
    for key in required:
        if key not in verify:
            failures.append(f"verify.json missing root field: {key}")
    if not isinstance(verify.get("passed"), bool):
        failures.append("verify.json .passed must be boolean")
    else:
        verify_passed = bool(verify["passed"])
    if verify.get("confidence") not in {"high", "medium", "low"}:
        failures.append("verify.json .confidence must be high|medium|low")
    print(f"  verify.passed: {verify.get('passed')!r}")

runbook = load_json(results / "runbook.json", "runbook.json") if results.exists() else None
if runbook is not None:
    for key in ["slug", "runbook_path", "status", "completed_at"]:
        if key not in runbook:
            failures.append(f"runbook.json missing root field: {key}")
    rb_path = runbook.get("runbook_path")
    if rb_path and not pathlib.Path(str(rb_path)).exists():
        warnings.append(f"runbook_path does not exist on disk: {rb_path}")

cleanup_path = results / "cleanup.json"
if verify_passed:
    cleanup = load_json(cleanup_path, "cleanup.json")
    if cleanup is not None:
        for key in ["slug", "dry_run", "freed_bytes", "completed_at"]:
            if key not in cleanup:
                failures.append(f"cleanup.json missing root field: {key}")
else:
    if cleanup_path.exists():
        warnings.append("verify did not pass, but cleanup.json exists; check whether cleanup was intentional")
    else:
        print("  cleanup.json: not required because verify.passed is not true")

# 通用检查: results/*.json 任何字符串值含未求值的 shell 表达式字面量
# (Fix: 2026-05-29-completed-at-literal-not-evaluated — hunyuan3d-2 实测
#  completed_at 落成 "$(date -Iseconds)" 字面量;根因是模板被 Write 工具原样
#  写盘而非 Bash heredoc 求值)
def scan_literals(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            scan_literals(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            scan_literals(v, f"{path}[{i}]")
    elif isinstance(node, str) and ("$(" in node or node.startswith("<") and node.endswith(">")):
        failures.append(f"unevaluated literal in {path}: {node!r}")

if results.exists():
    for jf in sorted(results.glob("*.json")):
        try:
            scan_literals(json.loads(jf.read_text(encoding="utf-8")), jf.name)
        except Exception:
            pass  # invalid JSON 已由上方 load_json 报过

print()
if warnings:
    print("Warnings:")
    for item in warnings:
        print(f"  WARN: {item}")
    print()

if failures:
    print("FAIL:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print("PASS: artifact set is valid")
PY
