from __future__ import annotations

from typing import Any


def apply_coupon(amount: float, coupon: str) -> float:
    code = (coupon or "").strip().upper()
    if code == "SAVE10":
        return amount * 0.9
    if code == "SAVE20":
        return amount * 0.8
    return amount


def calculate_order_total(order: dict[str, Any]) -> float:
    """Calculate order total by summing item price * qty, then applying coupon."""
    items = order.get("items", [])
    subtotal = 0.0
    for item in items:
        price = float(item.get("price", 0.0))
        qty = int(item.get("qty", 0))
        subtotal += price * qty

    total = apply_coupon(subtotal, str(order.get("coupon", "")))
    return round(total, 2)


def summarize_totals(orders: list[dict[str, Any]]) -> dict[str, float]:
    totals = [calculate_order_total(o) for o in orders]
    if not totals:
        return {"count": 0, "sum": 0.0, "avg": 0.0, "max": 0.0}

    return {
        "count": float(len(totals)),
        "sum": round(sum(totals), 2),
        "avg": round(sum(totals) / len(totals), 2),
        "max": round(max(totals), 2),
    }


def layer2_broken_func():
    return "intentional syntax error for Layer2-2.1"
