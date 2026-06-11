#!/usr/bin/env python3
"""Minimal stdio MCP wrapper for /root/ai-daily-scan.

The installed Python FastMCP stdio server currently hangs during initialize in
this environment. This wrapper implements the small JSON-RPC surface Claude Code
needs while delegating tool behavior to ai-daily-scan's existing functions.
"""
from __future__ import annotations

import json
import pathlib
import sys
import traceback
from typing import Any, Callable

AI_DAILY_SCAN_ROOT = pathlib.Path("/root/ai-daily-scan")
if str(AI_DAILY_SCAN_ROOT) not in sys.path:
    sys.path.insert(0, str(AI_DAILY_SCAN_ROOT))
if str(AI_DAILY_SCAN_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(AI_DAILY_SCAN_ROOT / "src"))

import mcp_server as daily_scan  # noqa: E402


PROTOCOL_VERSION = "2025-11-25"

TOOLS: dict[str, dict[str, Any]] = {
    "scan_today": {
        "description": "Check or trigger today's ai-daily-scan. async_mode=true (default) starts scan in background and returns immediately; use scan_status() to poll progress.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "force": {"type": "boolean", "default": False},
                "async_mode": {"type": "boolean", "default": True},
            },
            "additionalProperties": False,
        },
    },
    "scan_status": {
        "description": "Query the status of a background scan. Returns running state, stage progress (stage name, description, progress_pct, detail), and elapsed time estimate.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    "get_recent_findings": {
        "description": "Read recent ai-daily-scan findings. The 'days' parameter is currently unimplemented — always returns the latest batch.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "default": 7}},
            "additionalProperties": False,
        },
    },
    "record_outcome": {
        "description": "Append an ai-auto-harness deployment outcome to ai-daily-scan state.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "slug": {"type": "string"},
                "status": {"type": "string"},
                "run_id": {"type": "string", "default": ""},
                "error_class": {"type": ["string", "null"]},
                "phase_failed_at": {"type": ["string", "null"]},
                "notes": {"type": ["string", "null"]},
                "repair_count": {"type": "integer", "default": 0},
            },
            "required": ["slug", "status"],
            "additionalProperties": False,
        },
    },
    "analyze_project": {
        "description": "Run an ad-hoc ai-daily-scan analysis for a GitHub or HuggingFace URL.",
        "inputSchema": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
            "additionalProperties": False,
        },
    },
}

HANDLERS: dict[str, Callable[..., Any]] = {
    "scan_today": daily_scan.scan_today,
    "scan_status": daily_scan.scan_status,
    "get_recent_findings": daily_scan.get_recent_findings,
    "record_outcome": daily_scan.record_outcome,
    "analyze_project": daily_scan.analyze_project,
}


def write_message(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result_response(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def error_response(message_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": message_id, "error": error}


def tool_specs() -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "description": spec["description"],
            "inputSchema": spec["inputSchema"],
        }
        for name, spec in TOOLS.items()
    ]


def handle_request(message: dict[str, Any]) -> dict[str, Any] | None:
    message_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}

    if message_id is None:
        return None

    if method == "initialize":
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        return result_response(
            message_id,
            {
                "protocolVersion": requested or PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "ai_daily_scan", "version": "0.1.0"},
                "instructions": "ai-daily-scan tools for ai-auto-harness.",
            },
        )

    if method == "tools/list":
        return result_response(message_id, {"tools": tool_specs()})

    if method == "tools/call":
        if not isinstance(params, dict):
            return error_response(message_id, -32602, "Invalid params")
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in HANDLERS:
            return error_response(message_id, -32601, f"Unknown tool: {name}")
        if not isinstance(args, dict):
            return error_response(message_id, -32602, "Tool arguments must be an object")
        try:
            value = HANDLERS[name](**args)
        except Exception as exc:  # pragma: no cover - exercised by integration probes
            return result_response(
                message_id,
                {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(
                                {
                                    "error": "tool_failed",
                                    "exc": type(exc).__name__,
                                    "msg": str(exc),
                                    "traceback": traceback.format_exc(limit=8),
                                },
                                ensure_ascii=False,
                            ),
                        }
                    ],
                    "isError": True,
                },
            )
        call_result: dict[str, Any] = {
            "content": [
                {"type": "text", "text": json.dumps(value, ensure_ascii=False)}
            ],
            "isError": False,
        }
        if isinstance(value, dict):
            call_result["structuredContent"] = value
        return result_response(message_id, call_result)

    if method in {"ping", "notifications/initialized"}:
        return result_response(message_id, {})

    if method in {"resources/list", "prompts/list"}:
        key = "resources" if method == "resources/list" else "prompts"
        return result_response(message_id, {key: []})

    return error_response(message_id, -32601, f"Method not found: {method}")


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            write_message(error_response(None, -32700, "Parse error", str(exc)))
            continue
        if not isinstance(message, dict):
            write_message(error_response(None, -32600, "Invalid Request"))
            continue
        response = handle_request(message)
        if response is not None:
            write_message(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
