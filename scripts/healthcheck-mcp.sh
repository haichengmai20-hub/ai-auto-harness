#!/usr/bin/env bash
# healthcheck-mcp.sh — check ai_daily_scan MCP configuration and tool surface.
set -uo pipefail

HARNESS_ROOT="${AI_AUTO_HARNESS_ROOT:-/root/ai-auto-harness}"
SETTINGS="$HARNESS_ROOT/.claude/settings.json"
MCP_CONFIG="$HARNESS_ROOT/.mcp.json"
EXPECTED_TOOLS="scan_today get_recent_findings record_outcome analyze_project"

python3 - "$SETTINGS" "$MCP_CONFIG" $EXPECTED_TOOLS <<'PY'
import ast
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

settings_path = pathlib.Path(sys.argv[1])
mcp_config_path = pathlib.Path(sys.argv[2])
expected = set(sys.argv[3:])
failures: list[str] = []

print("=== healthcheck-mcp ===")
print(f"  settings: {settings_path}")
print(f"  mcp_json: {mcp_config_path}")


def load_json(path: pathlib.Path, label: str) -> dict:
    if not path.exists():
        failures.append(f"{label} missing: {path}")
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        failures.append(f"{label} invalid JSON: {exc}")
        return {}


settings = load_json(settings_path, "settings")
mcp_config = load_json(mcp_config_path, "mcp config")

allow = ((settings.get("permissions") or {}).get("allow") or [])
if "mcp__ai_daily_scan__*" not in allow:
    failures.append("settings permissions missing mcp__ai_daily_scan__* allow rule")

settings_server = (settings.get("mcpServers") or {}).get("ai_daily_scan")
runtime_server = (mcp_config.get("mcpServers") or {}).get("ai_daily_scan")
if not settings_server:
    failures.append("settings mcpServers.ai_daily_scan missing")
if not runtime_server:
    failures.append(".mcp.json mcpServers.ai_daily_scan missing")

server = runtime_server or settings_server
if server:
    command = server.get("command")
    args = server.get("args") or []
    env = server.get("env") or {}
    print(f"  command: {command}")
    print(f"  args:    {args}")
    if not command:
        failures.append("ai_daily_scan.command missing")
    if not args:
        failures.append("ai_daily_scan.args missing")
    server_path = pathlib.Path(args[0]) if args else None
    if server_path and not server_path.exists():
        failures.append(f"MCP server path missing: {server_path}")
    elif server_path:
        spec = importlib.util.spec_from_file_location("ai_daily_scan_mcp_stdio", server_path)
        module = importlib.util.module_from_spec(spec)
        assert spec and spec.loader
        spec.loader.exec_module(module)
        wrapper_tools = set(getattr(module, "TOOLS", {}).keys())
        print(f"  wrapper_tools: {sorted(wrapper_tools)}")
        missing = expected - wrapper_tools
        if missing:
            failures.append(f"wrapper tools missing: {sorted(missing)}")

        source_path = pathlib.Path("/root/ai-daily-scan/mcp_server.py")
        if not source_path.exists():
            failures.append(f"ai-daily-scan source MCP missing: {source_path}")
            source = ""
        else:
            source = source_path.read_text(encoding="utf-8")
        tree = ast.parse(source)
        tools: set[str] = set()
        for node in tree.body:
            if not isinstance(node, ast.FunctionDef):
                continue
            for dec in node.decorator_list:
                if (
                    isinstance(dec, ast.Call)
                    and isinstance(dec.func, ast.Attribute)
                        and dec.func.attr == "tool"
                    ):
                        tools.add(node.name)
        print(f"  source_tools:  {sorted(tools)}")
        missing = expected - tools
        if missing:
            failures.append(f"ai-daily-scan source tools missing: {sorted(missing)}")

        if command and server_path.exists():
            proc_env = dict(**env)
            init_msg = {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "healthcheck-mcp", "version": "0.0.1"},
                },
            }
            initialized_msg = {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            }
            list_msg = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
            payload = "\n".join(
                json.dumps(item) for item in (init_msg, initialized_msg, list_msg)
            ) + "\n"
            probe = subprocess.run(
                [command, *args],
                input=payload,
                capture_output=True,
                text=True,
                timeout=5,
                env={**os.environ, **proc_env, **dict(PYTHONUNBUFFERED="1")},
            )
            responses: list[dict] = []
            for line in probe.stdout.splitlines():
                if not line.strip():
                    continue
                try:
                    responses.append(json.loads(line))
                except Exception:
                    failures.append(f"stdio probe returned invalid JSON: {line.strip()}")
            ids = {item.get("id") for item in responses}
            if 1 not in ids:
                failures.append("stdio probe initialize response missing")
            list_resp = next((item for item in responses if item.get("id") == 2), None)
            if not list_resp:
                failures.append("stdio probe tools/list response missing")
            else:
                listed = {
                    tool.get("name")
                    for tool in ((list_resp.get("result") or {}).get("tools") or [])
                }
                missing = expected - listed
                if missing:
                    failures.append(f"stdio probe tools missing: {sorted(missing)}")
            if probe.stderr.strip():
                print(f"  stdio_stderr: {probe.stderr.strip()[:500]}")
            print(f"  stdio_probe: {len(responses)} response(s)")
else:
    failures.append("ai_daily_scan server config unavailable")

print()
if failures:
    print("FAIL:")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)

print("PASS: ai_daily_scan MCP runtime config, permission allowlist, and tool declarations are present")
PY
