"""OpenAI Whisper API client for speech-to-text."""

import os
import tempfile
import time
from pathlib import Path

from openai import OpenAI

import replacements
import vocabulary
from content_filter import get_filter
from settings import get_setting
from vocabulary_utils import apply_vocabulary_casing


class OpenAISTT:
    """OpenAI Whisper API client."""

    def __init__(self):
        """Initialize the OpenAI client."""
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise ValueError(
                "OPENAI_API_KEY environment variable not set. "
                "Please set it in your .env file or shell environment."
            )
        self.client = OpenAI(api_key=api_key)
        self.model = "whisper-1"  # OpenAI's Whisper model

        # Custom vocabulary for prompt (loaded from vocabulary.txt)
        self.vocabulary: list[str] = []

    def set_vocabulary(self, words: list[str]) -> None:
        """Set custom vocabulary for biasing transcription."""
        self.vocabulary = words

    def _build_prompt(self, max_words: int = 0) -> str | None:
        """Build prompt from vocabulary for better recognition.

        Args:
            max_words: Max vocabulary words to include (0 = no limit)
        """
        if not self.vocabulary:
            return None
        words = self.vocabulary[:max_words] if max_words > 0 else self.vocabulary
        return f"Vocabulary: {', '.join(words)}."

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
        max_vocab_words: int = 0,
    ) -> dict:
        """Transcribe audio data using OpenAI Whisper API.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect
            max_vocab_words: Max vocabulary words in prompt (0 = no limit)

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time'
        """
        total_start = time.time()

        lang_mode = language.upper() if language else "AUTO-DETECT"
        print(f"  [OpenAI] transcribe() called with language={lang_mode}")

        # --- Write audio to temp file ---
        prep_start = time.time()
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(audio_data)
            temp_path = f.name
        prep_time = (time.time() - prep_start) * 1000

        try:
            # --- API call ---
            inference_start = time.time()

            prompt = self._build_prompt(max_words=max_vocab_words)
            if prompt:
                print(f"  [OpenAI] Using prompt: {prompt[:50]}...")

            # Open file for API call (use context manager to ensure cleanup)
            with open(temp_path, "rb") as audio_file:
                # Build API call parameters
                api_params = {
                    "model": self.model,
                    "file": audio_file,
                    "response_format": "verbose_json",
                }

                if language:
                    api_params["language"] = language
                if prompt:
                    api_params["prompt"] = prompt

                # Make API call
                response = self.client.audio.transcriptions.create(**api_params)

            inference_time = (time.time() - inference_start) * 1000

            full_text = response.text.strip() if response.text else ""

            # Apply canonical casing from vocabulary and track usage
            full_text, matched_words = apply_vocabulary_casing(
                full_text, self.vocabulary
            )
            if matched_words:
                vocabulary.get_manager().record_usage(matched_words)

            # Apply word replacements (if enabled)
            if get_setting("replacements_enabled"):
                full_text = replacements.get_manager().apply_replacements(full_text)

            # Filter profanity (if enabled)
            if get_setting("content_filter"):
                full_text = get_filter().filter(full_text)

            # Get duration from response (verbose_json includes it)
            duration = getattr(response, "duration", 0) or 0

            if duration == 0:
                # Fallback: estimate from WAV size
                duration = max(0, (len(audio_data) - 44) / (16000 * 2))

            # Get detected language
            detected_language = getattr(response, "language", language or "unknown")

            total_time = time.time() - total_start

            print(
                f"  [Timing] prep={prep_time:.0f}ms | API={inference_time:.0f}ms | "
                f"total={total_time * 1000:.0f}ms | audio={duration:.1f}s"
            )

            return {
                "text": full_text,
                "language": detected_language,
                "language_probability": 1.0,
                "duration": duration,
                "processing_time": total_time,
                "provider": "openai",
            }

        finally:
            # Clean up temp file
            Path(temp_path).unlink(missing_ok=True)


# Singleton instance
_openai_stt: OpenAISTT | None = None


def get_openai_stt() -> OpenAISTT:
    """Get or create the OpenAI STT singleton."""
    global _openai_stt
    if _openai_stt is None:
        _openai_stt = OpenAISTT()
    return _openai_stt


def is_openai_available() -> bool:
    """Check if OpenAI API key is available."""
    return bool(os.environ.get("OPENAI_API_KEY"))
