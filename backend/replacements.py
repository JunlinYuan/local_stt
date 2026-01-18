"""
Word replacement management with file-based storage and auto-reload.

Replacements are stored in replacements.json as a list of {from, to} pairs.
File is watched for changes and auto-reloaded.
Replacements are applied case-insensitively with whole-word matching.
"""

import json
import re
import threading
import time
from pathlib import Path
from typing import Callable

# Replacement file location (in backend directory)
REPLACEMENTS_FILE = Path(__file__).parent / "replacements.json"

# Maximum number of replacement rules
MAX_REPLACEMENTS = 100


class ReplacementManager:
    """Manages word replacements with file persistence and auto-reload."""

    def __init__(self, on_change: Callable[[list[dict]], None] | None = None):
        """
        Initialize replacement manager.

        Args:
            on_change: Callback when replacements change (receives new rules list)
        """
        self._replacements: list[dict[str, str]] = []
        self._on_change = on_change
        self._last_modified: float = 0
        self._watcher_thread: threading.Thread | None = None
        self._stop_watcher = threading.Event()
        self._lock = threading.Lock()

        # Initial load
        self._load_from_file()

    @property
    def replacements(self) -> list[dict[str, str]]:
        """Get current replacement rules."""
        with self._lock:
            return self._replacements.copy()

    def _load_from_file(self) -> bool:
        """Load replacements from file. Returns True if changed."""
        if not REPLACEMENTS_FILE.exists():
            # Create default empty file
            self._save_to_file()
            return False

        try:
            mtime = REPLACEMENTS_FILE.stat().st_mtime
            if mtime == self._last_modified:
                return False  # No change

            with open(REPLACEMENTS_FILE, encoding="utf-8") as f:
                data = json.load(f)

            # Parse replacements list
            replacements = data.get("replacements", [])

            # Validate structure
            valid_replacements = []
            for rule in replacements:
                if (
                    isinstance(rule, dict)
                    and "from" in rule
                    and "to" in rule
                    and rule["from"].strip()
                    and rule["to"].strip()
                ):
                    valid_replacements.append(
                        {"from": rule["from"].strip(), "to": rule["to"].strip()}
                    )

            # Truncate to max size
            if len(valid_replacements) > MAX_REPLACEMENTS:
                print(
                    f"[Replacements] Warning: File has {len(valid_replacements)} rules, "
                    f"only using first {MAX_REPLACEMENTS}"
                )
                valid_replacements = valid_replacements[:MAX_REPLACEMENTS]

            self._last_modified = mtime

            with self._lock:
                old_replacements = self._replacements
                self._replacements = valid_replacements

            if valid_replacements != old_replacements:
                print(
                    f"[Replacements] Loaded {len(valid_replacements)} rules"
                    + (
                        f": {valid_replacements[0]['from']}→{valid_replacements[0]['to']}..."
                        if valid_replacements
                        else ""
                    )
                )
                if self._on_change:
                    self._on_change(valid_replacements)
                return True

        except (json.JSONDecodeError, OSError) as e:
            print(f"[Replacements] Error loading file: {e}")

        return False

    def _save_to_file(self) -> None:
        """Save replacements to file."""
        try:
            with self._lock:
                data = {"replacements": self._replacements}

            with open(REPLACEMENTS_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)

            self._last_modified = REPLACEMENTS_FILE.stat().st_mtime
            print(f"[Replacements] Saved {len(self._replacements)} rules to file")
        except OSError as e:
            print(f"[Replacements] Error saving file: {e}")

    def add_replacement(
        self, from_text: str, to_text: str
    ) -> tuple[bool, str | None]:
        """
        Add a replacement rule.

        Args:
            from_text: Text to find (case-insensitive matching)
            to_text: Text to replace with

        Returns:
            Tuple of (success, error_message).
            - (True, None) if rule was added
            - (False, "reason") if rule was not added
        """
        from_text = from_text.strip()
        to_text = to_text.strip()

        if not from_text:
            return False, "Source text is required"

        if not to_text:
            return False, "Replacement text is required"

        if from_text.lower() == to_text.lower():
            return False, "Source and replacement must be different"

        with self._lock:
            # Check limit
            if len(self._replacements) >= MAX_REPLACEMENTS:
                return (
                    False,
                    f"Replacement limit reached ({MAX_REPLACEMENTS} rules). Remove a rule first.",
                )

            # Check for duplicate (case-insensitive on 'from' field)
            if any(r["from"].lower() == from_text.lower() for r in self._replacements):
                return False, f"Replacement for '{from_text}' already exists"

            self._replacements.append({"from": from_text, "to": to_text})

        self._save_to_file()

        if self._on_change:
            self._on_change(self._replacements)

        print(f"[Replacements] Added: '{from_text}' → '{to_text}'")
        return True, None

    def remove_replacement(self, from_text: str) -> bool:
        """
        Remove a replacement rule by its 'from' value.

        Returns True if rule was removed.
        """
        from_text = from_text.strip()

        with self._lock:
            # Find and remove (case-insensitive match)
            for i, rule in enumerate(self._replacements):
                if rule["from"].lower() == from_text.lower():
                    removed = self._replacements.pop(i)
                    break
            else:
                return False

        self._save_to_file()

        if self._on_change:
            self._on_change(self._replacements)

        print(f"[Replacements] Removed: '{removed['from']}' → '{removed['to']}'")
        return True

    def set_replacements(self, rules: list[dict[str, str]]) -> None:
        """Replace entire replacement list (for bulk operations)."""
        valid_rules = []
        for rule in rules:
            if (
                isinstance(rule, dict)
                and rule.get("from", "").strip()
                and rule.get("to", "").strip()
            ):
                valid_rules.append(
                    {"from": rule["from"].strip(), "to": rule["to"].strip()}
                )

        with self._lock:
            self._replacements = valid_rules[:MAX_REPLACEMENTS]

        self._save_to_file()

        if self._on_change:
            self._on_change(self._replacements)

    def apply_replacements(self, text: str) -> str:
        """
        Apply all replacement rules to text.

        Matching is case-insensitive and whole-word only.
        Rules are applied in order.

        Args:
            text: Input text from transcription

        Returns:
            Text with replacements applied
        """
        if not text:
            return text

        with self._lock:
            rules = self._replacements.copy()

        if not rules:
            return text

        result = text
        for rule in rules:
            from_text = rule["from"]
            to_text = rule["to"]

            # Whole-word matching with case-insensitive flag
            # re.escape handles special regex characters in user input
            pattern = r"\b" + re.escape(from_text) + r"\b"
            result = re.sub(pattern, to_text, result, flags=re.IGNORECASE)

        return result

    def start_watcher(self, interval: float = 1.0) -> None:
        """Start background thread to watch for file changes."""
        if self._watcher_thread and self._watcher_thread.is_alive():
            return  # Already running

        self._stop_watcher.clear()

        def watch_loop():
            while not self._stop_watcher.is_set():
                self._load_from_file()
                time.sleep(interval)

        self._watcher_thread = threading.Thread(target=watch_loop, daemon=True)
        self._watcher_thread.start()
        print(f"[Replacements] File watcher started (checking every {interval}s)")

    def stop_watcher(self) -> None:
        """Stop the file watcher thread."""
        self._stop_watcher.set()
        if self._watcher_thread:
            self._watcher_thread.join(timeout=2.0)
            print("[Replacements] File watcher stopped")


# Singleton instance
_manager: ReplacementManager | None = None


def get_manager() -> ReplacementManager:
    """Get or create the replacement manager singleton."""
    global _manager
    if _manager is None:
        _manager = ReplacementManager()
    return _manager


def init_manager(
    on_change: Callable[[list[dict]], None] | None = None,
) -> ReplacementManager:
    """Initialize the replacement manager with optional change callback."""
    global _manager
    _manager = ReplacementManager(on_change=on_change)
    return _manager
