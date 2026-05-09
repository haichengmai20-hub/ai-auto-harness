from __future__ import annotations

import httpx


def fetch_status(base_url: str) -> int:
    response = httpx.get(f"{base_url}/status", timeout=5)
    return response.status_code
