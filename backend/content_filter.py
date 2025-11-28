"""Content filter for detecting likely misrecognized profanity and hallucinations."""

import logging
import re
from datetime import datetime
from pathlib import Path

from better_profanity import profanity

# Known Whisper hallucination phrases (when audio is silent/quiet)
# These are filtered only when they constitute the ENTIRE transcription
HALLUCINATION_PHRASES = {
    # English
    "thank you",
    "thank you.",
    "thanks",
    "thanks.",
    "thanks for watching",
    "thanks for watching.",
    "thanks for listening",
    "thanks for listening.",
    "thank you for watching",
    "thank you for watching.",
    "thank you for listening",
    "thank you for listening.",
    "like and subscribe",
    "like and subscribe.",
    "subscribe",
    "subscribe.",
    "see you next time",
    "see you next time.",
    "bye",
    "bye.",
    "goodbye",
    "goodbye.",
    "see you",
    "see you.",
    # Chinese
    "謝謝",
    "谢谢",
    "謝謝觀看",
    "谢谢观看",
    # Japanese
    "ありがとう",
    "ありがとうございます",
    "ご視聴ありがとうございました",
    # French
    "merci",
    "merci.",
    "merci d'avoir regardé",
    # Other common ones
    "...",
    "…",
    "you",
    "you.",
}

# Set up logging for detected profanity (helps spot patterns)
_log_path = Path(__file__).parent / "filter_log.txt"
_logger = logging.getLogger("content_filter")


def _log_detection(original: str, filtered: str) -> None:
    """Log detected profanity for pattern analysis."""
    try:
        with open(_log_path, "a") as f:
            timestamp = datetime.now().isoformat(timespec="seconds")
            f.write(f"{timestamp} | {original!r} -> {filtered!r}\n")
    except Exception:
        pass  # Don't fail transcription due to logging


class ContentFilter:
    """Detects and filters likely misrecognized profanity."""

    def __init__(self, replacement: str = "[?]"):
        """Initialize the filter.

        Args:
            replacement: What to replace detected profanity with.
                        "[?]" signals uncertainty (recommended)
                        "" removes the word entirely
        """
        self.replacement = replacement
        self._enabled = True
        # Load default word list
        profanity.load_censor_words()

    @property
    def enabled(self) -> bool:
        return self._enabled

    @enabled.setter
    def enabled(self, value: bool) -> None:
        self._enabled = value

    def contains_profanity(self, text: str) -> bool:
        """Check if text contains profanity."""
        return profanity.contains_profanity(text)

    def is_hallucination(self, text: str) -> bool:
        """Check if text is a known Whisper hallucination.

        Only returns True if the ENTIRE text is a hallucination phrase.
        """
        normalized = text.strip().lower()
        return normalized in HALLUCINATION_PHRASES

    def filter_hallucination(self, text: str) -> str:
        """Filter out hallucination phrases.

        Returns empty string if text is a hallucination, otherwise returns original.
        """
        if self.is_hallucination(text):
            print(f"  [ContentFilter] Filtered hallucination: {text!r}")
            return ""
        return text

    def filter(self, text: str) -> str:
        """Filter profanity from text.

        Returns the filtered text. If profanity was detected,
        logs the original for pattern analysis.
        """
        if not self._enabled or not text:
            return text

        if not profanity.contains_profanity(text):
            return text

        # Profanity detected - likely a misrecognition
        filtered = profanity.censor(text, censor_char="")

        # Clean up multiple spaces from removed words
        filtered = re.sub(r"\s+", " ", filtered).strip()

        # If replacement is specified, the library already handles it
        # But we want custom replacement, so we do it differently
        if self.replacement:
            # Re-censor with our custom marker
            filtered = profanity.censor(text, censor_char="*")
            # Replace asterisk sequences with our replacement
            filtered = re.sub(r"\*+", self.replacement, filtered)
            filtered = re.sub(r"\s+", " ", filtered).strip()

        _log_detection(text, filtered)
        print(f"  [ContentFilter] Detected likely misrecognition: {text!r}")

        return filtered


# Singleton instance
_filter: ContentFilter | None = None


def get_filter() -> ContentFilter:
    """Get or create the content filter singleton."""
    global _filter
    if _filter is None:
        _filter = ContentFilter()
    return _filter
