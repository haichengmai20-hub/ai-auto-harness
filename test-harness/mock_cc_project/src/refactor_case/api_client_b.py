from __future__ import annotations

import httpx


def fetch_items(base_url: str, page: int = 1) -> list[dict]:
    params = {"page": page, "limit": 20}
    response = httpx.get(f"{base_url}/items", params=params, timeout=8)
    return response.json().get("items", [])
