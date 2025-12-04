"""
Dictation history management with JSON file storage.
Stores last 20 transcriptions (text only, newest first).
"""

import json
from pathlib import Path

HISTORY_FILE = Path(__file__).parent / "history.json"
MAX_ENTRIES = 20


def _load_history() -> list[str]:
    """Load history from JSON file."""
    if HISTORY_FILE.exists():
        try:
            with open(HISTORY_FILE, encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    return data[:MAX_ENTRIES]
        except (json.JSONDecodeError, OSError):
            pass
    return []


def _save_history(entries: list[str]) -> None:
    """Save history to JSON file."""
    with open(HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(entries[:MAX_ENTRIES], f, indent=2, ensure_ascii=False)


def add_entry(text: str) -> None:
    """Add a transcription to history (prepends, trims to MAX_ENTRIES)."""
    text = text.strip()
    if not text:
        return
    entries = _load_history()
    entries.insert(0, text)
    _save_history(entries[:MAX_ENTRIES])


def get_all() -> list[str]:
    """Get all history entries (newest first)."""
    return _load_history()


def delete_entry(index: int) -> bool:
    """Delete entry by index. Returns True if deleted."""
    entries = _load_history()
    if 0 <= index < len(entries):
        entries.pop(index)
        _save_history(entries)
        return True
    return False


def clear_all() -> None:
    """Clear all history."""
    _save_history([])
