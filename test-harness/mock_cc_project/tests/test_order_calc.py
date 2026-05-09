from src.order_calc import apply_coupon, calculate_order_total, summarize_totals
from src.text_utils import clean_title


def test_apply_coupon_save10() -> None:
    assert apply_coupon(100.0, "SAVE10") == 90.0


def test_calculate_order_total_with_coupon() -> None:
    order = {
        "items": [
            {"price": 100, "qty": 2},
            {"price": 10.5, "qty": 1},
        ],
        "coupon": "SAVE20",
    }
    assert calculate_order_total(order) == 168.4


def test_summarize_totals_empty() -> None:
    assert summarize_totals([]) == {"count": 0, "sum": 0.0, "avg": 0.0, "max": 0.0}


def test_clean_title() -> None:
    assert clean_title("  Hello   World  ") == "Hello World"
