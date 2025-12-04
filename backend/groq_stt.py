"""Groq Whisper API client for speech-to-text.

Groq offers ultra-fast Whisper inference (200-300x real-time) at lower cost than OpenAI.
Uses OpenAI-compatible API, making integration straightforward.

Models available:
- whisper-large-v3: Best accuracy (~10.3% WER), $0.111/hr
- whisper-large-v3-turbo: Fast + good accuracy (~12% WER), $0.04/hr (default)
- distil-whisper-large-v3-en: Fastest, English-only (~13% WER), $0.02/hr
"""

import os
import tempfile
import time
from pathlib import Path

from groq import Groq

from content_filter import get_filter
from settings import get_setting


class GroqSTT:
    """Groq Whisper API client."""

    def __init__(self):
        """Initialize the Groq client."""
        api_key = os.environ.get("GROQ_API_KEY")
        if not api_key:
            raise ValueError(
                "GROQ_API_KEY environment variable not set. "
                "Get your API key from https://console.groq.com"
            )
        self.client = Groq(api_key=api_key)
        # Default to turbo model (good balance of speed/accuracy/cost)
        self.model = "whisper-large-v3-turbo"

        # Custom vocabulary for prompt
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
        """Transcribe audio data using Groq Whisper API.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time'
        """
        total_start = time.time()

        lang_mode = language.upper() if language else "AUTO-DETECT"
        print(f"  [Groq] transcribe() called with language={lang_mode}")

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
                print(f"  [Groq] Using prompt: {prompt[:50]}...")

            # Open file for API call
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

            # Get duration from response
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
                "provider": "groq",
            }

        finally:
            # Clean up temp file
            Path(temp_path).unlink(missing_ok=True)


# Singleton instance
_groq_stt: GroqSTT | None = None


def get_groq_stt() -> GroqSTT:
    """Get or create the Groq STT singleton."""
    global _groq_stt
    if _groq_stt is None:
        _groq_stt = GroqSTT()
    return _groq_stt


def is_groq_available() -> bool:
    """Check if Groq API key is available."""
    return bool(os.environ.get("GROQ_API_KEY"))
