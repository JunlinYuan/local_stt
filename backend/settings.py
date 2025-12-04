"""
Schema-driven settings management with JSON file storage.

To add a new setting:
1. Add entry to SETTINGS_SCHEMA with default, type, and optional validation/display
2. That's it - API and UI will handle it automatically

Example future setting:
    "paste_delay": {
        "default": 0.1,
        "type": "number",
        "min": 0,
        "max": 2.0,
        "description": "Delay in seconds before pasting and restoring clipboard",
    },
"""

import json
from pathlib import Path
from typing import Any

# Settings file location (in backend directory)
SETTINGS_FILE = Path(__file__).parent / "settings.json"

# =============================================================================
# Settings Schema - Add new settings here
# =============================================================================

SETTINGS_SCHEMA: dict[str, dict[str, Any]] = {
    "stt_provider": {
        "default": "local",
        "type": "string",
        "options": ["local", "openai", "groq"],
        "description": "STT provider: local (lightning-whisper-mlx), OpenAI API, or Groq API",
        "display": lambda v: {
            "local": "Local (MLX)",
            "openai": "OpenAI API",
            "groq": "Groq API (Fast)",
        }.get(v, v),
    },
    "language": {
        "default": "",  # Empty = auto-detect
        "type": "string",
        "options": ["", "en", "fr", "zh", "ja"],
        "description": "Transcription language (empty for auto-detect)",
        "display": lambda v: v.upper() if v else "AUTO",
    },
    "keybinding": {
        "default": "ctrl_only",
        "type": "string",
        "options": ["ctrl_only", "ctrl", "shift"],
        "description": "Push-to-talk keybinding (left side only)",
        "display": lambda v: {
            "ctrl_only": "Left Ctrl Only",
            "ctrl": "Left Ctrl + Left Option",
            "shift": "Left Shift + Left Option",
        }.get(v, v),
    },
    "clipboard_sync_delay": {
        "default": 0.05,
        "type": "number",
        "min": 0.0,
        "max": 0.5,
        "description": "Delay after copying to clipboard before pasting (for clipboard sync)",
        "display": lambda v: f"{v:.2f}s",
    },
    "paste_delay": {
        "default": 0.05,
        "type": "number",
        "min": 0.0,
        "max": 0.5,
        "description": "Delay after pasting before restoring original clipboard",
        "display": lambda v: f"{v:.2f}s",
    },
    "content_filter": {
        "default": True,
        "type": "boolean",
        "description": "Filter likely misrecognized profanity",
        "display": lambda v: "On" if v else "Off",
    },
    "min_recording_duration": {
        "default": 0.3,
        "type": "number",
        "min": 0.1,
        "max": 2.0,
        "description": "Minimum recording duration to avoid accidental taps",
        "display": lambda v: f"{v:.1f}s",
    },
    "min_volume_rms": {
        "default": 100,
        "type": "number",
        "min": 0,
        "max": 500,
        "description": "Minimum audio volume (RMS) to trigger transcription. Set to 0 to disable.",
        "display": lambda v: "Off" if v == 0 else str(int(v)),
    },
    "volume_normalization": {
        "default": True,
        "type": "boolean",
        "description": "Normalize audio volume (boost quiet, limit loud) before transcription",
        "display": lambda v: "On" if v else "Off",
    },
    "max_recording_duration": {
        "default": 240,
        "type": "number",
        "min": 30,
        "max": 300,
        "description": "Maximum recording duration in seconds (safety timeout)",
        "display": lambda v: f"{int(v // 60)}m" if v >= 60 else f"{int(v)}s",
    },
    "ffm_enabled": {
        "default": True,
        "type": "boolean",
        "description": "Focus-follows-mouse: automatically focus the window under the cursor",
        "display": lambda v: "On" if v else "Off",
    },
}


# =============================================================================
# Core Functions
# =============================================================================


def _get_defaults() -> dict[str, Any]:
    """Extract default values from schema."""
    return {key: schema["default"] for key, schema in SETTINGS_SCHEMA.items()}


def _load_settings() -> dict[str, Any]:
    """Load settings from JSON file, merged with defaults."""
    defaults = _get_defaults()
    if SETTINGS_FILE.exists():
        try:
            with open(SETTINGS_FILE) as f:
                stored = json.load(f)
                # Only keep known settings (schema keys)
                return {
                    **defaults,
                    **{k: v for k, v in stored.items() if k in SETTINGS_SCHEMA},
                }
        except (json.JSONDecodeError, OSError):
            pass
    return defaults


def _save_settings(settings: dict[str, Any]) -> None:
    """Save settings to JSON file."""
    # Only save known settings
    to_save = {k: v for k, v in settings.items() if k in SETTINGS_SCHEMA}
    with open(SETTINGS_FILE, "w") as f:
        json.dump(to_save, f, indent=2)


def _validate_setting(key: str, value: Any) -> tuple[bool, str]:
    """Validate a setting value against its schema. Returns (valid, error_message)."""
    if key not in SETTINGS_SCHEMA:
        return False, f"Unknown setting: {key}"

    schema = SETTINGS_SCHEMA[key]
    expected_type = schema["type"]

    # Type validation
    if expected_type == "string" and not isinstance(value, str):
        return False, f"{key} must be a string"
    if expected_type == "number" and not isinstance(value, (int, float)):
        return False, f"{key} must be a number"
    if expected_type == "boolean" and not isinstance(value, bool):
        return False, f"{key} must be a boolean"

    # Options validation (enum)
    if "options" in schema and value not in schema["options"]:
        return False, f"{key} must be one of: {schema['options']}"

    # Range validation for numbers
    if expected_type == "number":
        if "min" in schema and value < schema["min"]:
            return False, f"{key} must be >= {schema['min']}"
        if "max" in schema and value > schema["max"]:
            return False, f"{key} must be <= {schema['max']}"

    return True, ""


def _get_display_value(key: str, value: Any) -> str:
    """Get display string for a setting value."""
    schema = SETTINGS_SCHEMA.get(key, {})
    if "display" in schema:
        return schema["display"](value)
    # Default display
    if isinstance(value, bool):
        return "On" if value else "Off"
    return str(value).upper() if isinstance(value, str) else str(value)


# =============================================================================
# Public API
# =============================================================================


def get_setting(key: str) -> Any:
    """Get a single setting value."""
    settings = _load_settings()
    return settings.get(key, SETTINGS_SCHEMA.get(key, {}).get("default"))


def set_setting(key: str, value: Any) -> dict[str, Any]:
    """
    Set a single setting value with validation.
    Returns the updated settings dict.
    Raises ValueError if validation fails.
    """
    valid, error = _validate_setting(key, value)
    if not valid:
        raise ValueError(error)

    settings = _load_settings()
    settings[key] = value
    _save_settings(settings)

    print(f"★ {key} changed to: {_get_display_value(key, value)}", flush=True)
    return settings


def get_all_settings() -> dict[str, Any]:
    """Get all settings with their current values."""
    return _load_settings()


def get_settings_response() -> dict[str, Any]:
    """
    Get all settings formatted for API response.
    Includes both raw values and display values.
    """
    settings = _load_settings()
    response = {}

    for key, value in settings.items():
        response[key] = value
        response[f"{key}_display"] = _get_display_value(key, value)

    return response


def get_schema() -> dict[str, dict[str, Any]]:
    """
    Get settings schema for frontend.
    Excludes functions (display) - only serializable data.
    """
    schema = {}
    for key, config in SETTINGS_SCHEMA.items():
        schema[key] = {
            "default": config["default"],
            "type": config["type"],
        }
        if "options" in config:
            schema[key]["options"] = config["options"]
        if "min" in config:
            schema[key]["min"] = config["min"]
        if "max" in config:
            schema[key]["max"] = config["max"]
        if "description" in config:
            schema[key]["description"] = config["description"]
    return schema


# =============================================================================
# Convenience Functions (for type hints and cleaner code in main.py)
# =============================================================================


def get_language() -> str | None:
    """Get language setting (None if auto-detect)."""
    lang = get_setting("language")
    return lang if lang else None


def get_keybinding() -> str:
    """Get keybinding setting."""
    return get_setting("keybinding")


def get_min_recording_duration() -> float:
    """Get minimum recording duration in seconds."""
    return get_setting("min_recording_duration")


def get_min_volume_rms() -> int:
    """Get minimum volume RMS threshold (0 = disabled)."""
    return int(get_setting("min_volume_rms"))


def get_stt_provider() -> str:
    """Get STT provider setting ('local' or 'openai')."""
    return get_setting("stt_provider")
