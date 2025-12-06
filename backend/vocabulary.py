"""
Vocabulary management with file-based storage and auto-reload.

Vocabulary is stored in vocabulary.txt (one word per line).
Usage counts are stored in vocabulary_usage.json.
File is watched for changes and auto-reloaded.
Words are automatically ordered by usage frequency (most-used first).
"""

import json
import threading
import time
from pathlib import Path
from typing import Callable

# Vocabulary file location (in backend directory)
VOCABULARY_FILE = Path(__file__).parent / "vocabulary.txt"
USAGE_FILE = Path(__file__).parent / "vocabulary_usage.json"


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

        # Usage tracking
        self._usage: dict[str, int] = {}
        self._usage_lock = threading.Lock()

        # Initial load
        self._load_from_file()
        self._load_usage()

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
        """Save vocabulary to file, ordered by usage frequency (most-used first)."""
        try:
            # Reorder by usage before saving
            self._words = self._reorder_by_usage()

            with open(VOCABULARY_FILE, "w", encoding="utf-8") as f:
                f.write("# Custom vocabulary for speech-to-text\n")
                f.write("# One word/phrase per line, comments start with #\n")
                f.write("# Words are case-sensitive (TEMPEST stays TEMPEST)\n")
                f.write("# Ordered by usage frequency (most-used first)\n\n")
                for word in self._words:
                    f.write(f"{word}\n")
            self._last_modified = VOCABULARY_FILE.stat().st_mtime
            print(
                f"[Vocabulary] Saved {len(self._words)} words to file (ordered by usage)"
            )
        except OSError as e:
            print(f"[Vocabulary] Error saving file: {e}")

    def add_word(self, word: str) -> bool:
        """
        Add a word to vocabulary (appends to file).
        Returns True if word was added (not duplicate).
        New words start with 0 usage count.
        """
        word = word.strip()
        if not word:
            return False

        # Check for duplicate (case-insensitive check, but preserve case)
        if any(w.lower() == word.lower() for w in self._words):
            print(f"[Vocabulary] '{word}' already exists (skipping)")
            return False

        self._words.append(word)

        # Initialize usage count for new word
        with self._usage_lock:
            if word not in self._usage:
                self._usage[word] = 0
            self._save_usage()

        self._save_to_file()

        if self._on_change:
            self._on_change(self._words)

        print(f"[Vocabulary] Added: {word}")
        return True

    def remove_word(self, word: str) -> bool:
        """
        Remove a word from vocabulary.
        Returns True if word was removed.
        Also cleans up usage data for the removed word.
        """
        word = word.strip()

        # Find and remove (case-insensitive match)
        for i, w in enumerate(self._words):
            if w.lower() == word.lower():
                removed = self._words.pop(i)

                # Clean up usage data
                with self._usage_lock:
                    self._usage.pop(removed, None)
                    self._save_usage()

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

    # -------------------------------------------------------------------------
    # Usage tracking methods
    # -------------------------------------------------------------------------

    def _load_usage(self) -> None:
        """Load usage counts from JSON file."""
        if not USAGE_FILE.exists():
            self._usage = {}
            return

        try:
            with open(USAGE_FILE, encoding="utf-8") as f:
                self._usage = json.load(f)
            print(f"[Vocabulary] Loaded usage data for {len(self._usage)} words")
        except (json.JSONDecodeError, OSError) as e:
            print(f"[Vocabulary] Error loading usage file: {e}")
            self._usage = {}

    def _save_usage(self) -> None:
        """Save usage counts to JSON file."""
        try:
            with open(USAGE_FILE, "w", encoding="utf-8") as f:
                json.dump(self._usage, f, indent=2, sort_keys=True)
        except OSError as e:
            print(f"[Vocabulary] Error saving usage file: {e}")

    def _reorder_by_usage(self) -> list[str]:
        """Return words ordered by usage count (most-used first), preserving order for ties."""
        with self._usage_lock:
            # Take a snapshot of usage counts to avoid race conditions
            usage_snapshot = self._usage.copy()
        # Python's sorted() is stable, so words with same usage keep their relative order
        return sorted(self._words, key=lambda w: -usage_snapshot.get(w, 0))

    def record_usage(self, words: list[str]) -> None:
        """
        Record that vocabulary words appeared in a transcription.
        Thread-safe. Saves immediately.

        Args:
            words: List of matched vocabulary words
        """
        if not words:
            return

        # Take a snapshot of vocabulary to avoid race conditions with file watcher
        words_snapshot = self._words.copy()

        with self._usage_lock:
            for word in words:
                # Normalize to canonical form (match against our vocabulary)
                canonical = next(
                    (w for w in words_snapshot if w.lower() == word.lower()), word
                )
                self._usage[canonical] = self._usage.get(canonical, 0) + 1
            self._save_usage()

        # Log usage update
        print(f"[Vocabulary] Recorded usage for: {', '.join(words)}")

    def get_usage(self) -> dict[str, int]:
        """Get usage counts for all vocabulary words."""
        with self._usage_lock:
            return {word: self._usage.get(word, 0) for word in self._words}

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
