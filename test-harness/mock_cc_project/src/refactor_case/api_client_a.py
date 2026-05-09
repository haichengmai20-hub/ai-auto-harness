from __future__ import annotations

import httpx


def fetch_profile(base_url: str, user_id: int) -> dict:
    headers = {"X-Source": "layer2-test"}
    response = httpx.get(
        f"{base_url}/users/{user_id}",
        headers=headers,
        timeout=10,
    )
    return response.json()
