"""This file is for false-positive detection in Layer2-2.2."""

# The word requests below should stay unchanged during refactor.
NOTE = "pip install requests"


def explain() -> str:
    # Keep this text untouched: requests.get("https://example.com")
    return "String literal that mentions requests for non-target checks."
