"""Settings management with JSON file storage."""

import json
from pathlib import Path
from typing import Any

# Settings file location (in backend directory)
SETTINGS_FILE = Path(__file__).parent / "settings.json"

# Default settings
DEFAULT_SETTINGS = {
    "language": "",  # Empty = auto-detect, or "en", "fr", "zh", "ja"
    "keybinding": "ctrl",  # "ctrl" or "shift" (+ Option)
}


def _load_settings() -> dict[str, Any]:
    """Load settings from JSON file."""
    if SETTINGS_FILE.exists():
        try:
            with open(SETTINGS_FILE) as f:
                return {**DEFAULT_SETTINGS, **json.load(f)}
        except (json.JSONDecodeError, OSError):
            pass
    return DEFAULT_SETTINGS.copy()


def _save_settings(settings: dict[str, Any]) -> None:
    """Save settings to JSON file."""
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f, indent=2)


def get_setting(key: str) -> Any:
    """Get a single setting value."""
    settings = _load_settings()
    return settings.get(key, DEFAULT_SETTINGS.get(key))


def set_setting(key: str, value: Any) -> dict[str, Any]:
    """Set a single setting value and return all settings."""
    settings = _load_settings()
    settings[key] = value
    _save_settings(settings)
    return settings


def get_all_settings() -> dict[str, Any]:
    """Get all settings."""
    return _load_settings()


def get_language() -> str | None:
    """Get language setting (None if auto-detect)."""
    lang = get_setting("language")
    return lang if lang else None


def get_language_display() -> str:
    """Get language setting as display string."""
    lang = get_setting("language")
    return lang.upper() if lang else "AUTO"


def set_language(language: str) -> None:
    """Set language setting."""
    set_setting("language", language)
    print(f"★ Language changed to: {get_language_display()}", flush=True)


def get_keybinding() -> str:
    """Get keybinding setting ('ctrl' or 'shift')."""
    return get_setting("keybinding")


def get_keybinding_display() -> str:
    """Get keybinding as display string."""
    kb = get_keybinding()
    return "Ctrl + Option" if kb == "ctrl" else "Shift + Option"


def set_keybinding(keybinding: str) -> None:
    """Set keybinding setting."""
    if keybinding not in ("ctrl", "shift"):
        raise ValueError("keybinding must be 'ctrl' or 'shift'")
    set_setting("keybinding", keybinding)
    print(f"★ Keybinding changed to: {get_keybinding_display()}", flush=True)
