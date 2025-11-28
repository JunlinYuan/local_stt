"""
Vocabulary management with file-based storage and auto-reload.

Vocabulary is stored in vocabulary.txt (one word per line).
File is watched for changes and auto-reloaded.
"""

import threading
import time
from pathlib import Path
from typing import Callable

# Vocabulary file location (in backend directory)
VOCABULARY_FILE = Path(__file__).parent / "vocabulary.txt"


class VocabularyManager:
    """Manages vocabulary with file persistence and auto-reload."""

    def __init__(self, on_change: Callable[[list[str]], None] | None = None):
        """
        Initialize vocabulary manager.

        Args:
            on_change: Callback when vocabulary changes (receives new word list)
        """
        self._words: list[str] = []
        self._on_change = on_change
        self._last_modified: float = 0
        self._watcher_thread: threading.Thread | None = None
        self._stop_watcher = threading.Event()

        # Initial load
        self._load_from_file()

    @property
    def words(self) -> list[str]:
        """Get current vocabulary words."""
        return self._words.copy()

    def _load_from_file(self) -> bool:
        """Load vocabulary from file. Returns True if changed."""
        if not VOCABULARY_FILE.exists():
            # Create default file
            self._save_to_file()
            return False

        try:
            mtime = VOCABULARY_FILE.stat().st_mtime
            if mtime == self._last_modified:
                return False  # No change

            with open(VOCABULARY_FILE, encoding="utf-8") as f:
                lines = f.readlines()

            # Parse: skip empty lines and comments
            words = []
            for line in lines:
                line = line.strip()
                if line and not line.startswith("#"):
                    words.append(line)

            self._last_modified = mtime
            old_words = self._words
            self._words = words

            if words != old_words:
                print(
                    f"[Vocabulary] Loaded {len(words)} words: {words[:5]}{'...' if len(words) > 5 else ''}"
                )
                if self._on_change:
                    self._on_change(words)
                return True

        except OSError as e:
            print(f"[Vocabulary] Error loading file: {e}")

        return False

    def _save_to_file(self) -> None:
        """Save vocabulary to file."""
        try:
            with open(VOCABULARY_FILE, "w", encoding="utf-8") as f:
                f.write("# Custom vocabulary for speech-to-text\n")
                f.write("# One word/phrase per line, comments start with #\n")
                f.write("# Words are case-sensitive (TEMPEST stays TEMPEST)\n\n")
                for word in self._words:
                    f.write(f"{word}\n")
            self._last_modified = VOCABULARY_FILE.stat().st_mtime
            print(f"[Vocabulary] Saved {len(self._words)} words to file")
        except OSError as e:
            print(f"[Vocabulary] Error saving file: {e}")

    def add_word(self, word: str) -> bool:
        """
        Add a word to vocabulary (appends to file).
        Returns True if word was added (not duplicate).
        """
        word = word.strip()
        if not word:
            return False

        # Check for duplicate (case-insensitive check, but preserve case)
        if any(w.lower() == word.lower() for w in self._words):
            print(f"[Vocabulary] '{word}' already exists (skipping)")
            return False

        self._words.append(word)
        self._save_to_file()

        if self._on_change:
            self._on_change(self._words)

        print(f"[Vocabulary] Added: {word}")
        return True

    def remove_word(self, word: str) -> bool:
        """
        Remove a word from vocabulary.
        Returns True if word was removed.
        """
        word = word.strip()

        # Find and remove (case-insensitive match)
        for i, w in enumerate(self._words):
            if w.lower() == word.lower():
                removed = self._words.pop(i)
                self._save_to_file()

                if self._on_change:
                    self._on_change(self._words)

                print(f"[Vocabulary] Removed: {removed}")
                return True

        return False

    def set_words(self, words: list[str]) -> None:
        """Replace entire vocabulary (for bulk operations)."""
        self._words = [w.strip() for w in words if w.strip()]
        self._save_to_file()

        if self._on_change:
            self._on_change(self._words)

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
        print(f"[Vocabulary] File watcher started (checking every {interval}s)")

    def stop_watcher(self) -> None:
        """Stop the file watcher thread."""
        self._stop_watcher.set()
        if self._watcher_thread:
            self._watcher_thread.join(timeout=2.0)
            print("[Vocabulary] File watcher stopped")


# Singleton instance
_manager: VocabularyManager | None = None


def get_manager() -> VocabularyManager:
    """Get or create the vocabulary manager singleton."""
    global _manager
    if _manager is None:
        _manager = VocabularyManager()
    return _manager


def init_manager(
    on_change: Callable[[list[str]], None] | None = None,
) -> VocabularyManager:
    """Initialize the vocabulary manager with optional change callback."""
    global _manager
    _manager = VocabularyManager(on_change=on_change)
    return _manager
