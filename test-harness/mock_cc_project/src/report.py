from __future__ import annotations

import json
from pathlib import Path

from .order_calc import summarize_totals
from .text_utils import clean_title


def load_orders(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    base = Path(__file__).resolve().parent.parent
    data_path = base / "data" / "sample_orders.json"
    orders = load_orders(data_path)
    metrics = summarize_totals(orders)

    title = clean_title("  demo   order  summary  ")
    print(f"{title}: {metrics}")


if __name__ == "__main__":
    main()
