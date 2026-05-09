from __future__ import annotations

import re


_whitespace_re = re.compile(r"\s+")


def clean_title(text: str) -> str:
    """Basic cleaner used by tests and report rendering."""
    if text is None:
        return ""
    normalized = _whitespace_re.sub(" ", text)
    return normalized.strip()
