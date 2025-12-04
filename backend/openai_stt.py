"""OpenAI Whisper API client for speech-to-text."""

import os
import tempfile
import time
from pathlib import Path

from openai import OpenAI

from content_filter import get_filter
from settings import get_setting


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

    def _build_prompt(self) -> str | None:
        """Build prompt from vocabulary for better recognition."""
        if not self.vocabulary:
            return None
        return f"Vocabulary: {', '.join(self.vocabulary)}."

    def _apply_vocabulary_casing(self, text: str) -> str:
        """Replace vocabulary words with their canonical casing."""
        import re

        if not self.vocabulary:
            return text
        for word in self.vocabulary:
            pattern = re.compile(rf"\b{re.escape(word)}\b", re.IGNORECASE)
            text = pattern.sub(word, text)
        return text

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
    ) -> dict:
        """Transcribe audio data using OpenAI Whisper API.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect

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

            prompt = self._build_prompt()
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

            # Apply canonical casing from vocabulary
            full_text = self._apply_vocabulary_casing(full_text)

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
