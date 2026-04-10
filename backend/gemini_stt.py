"""Gemini API client for speech-to-text.

Uses Gemini 3.1 Flash-Lite for audio transcription. Unlike Whisper-based providers,
Gemini is an LLM that can accept rich prompts with vocabulary AND replacement rules
embedded directly (no 896-char limit). Post-processing pipeline still applied for
consistency and as a safety net.

Model:
- gemini-3.1-flash-lite-preview: Fast, cheap LLM-based transcription
"""

import os
import time

from google import genai
from google.genai import types

import replacements
import vocabulary
from content_filter import get_filter
from settings import get_setting
from vocabulary_utils import apply_vocabulary_casing


class GeminiSTT:
    """Gemini API client for audio transcription."""

    def __init__(self):
        """Initialize the Gemini client."""
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise ValueError(
                "GEMINI_API_KEY environment variable not set. "
                "Get your API key from https://aistudio.google.com/apikey"
            )
        self.client = genai.Client(api_key=api_key)
        self.model = "gemini-3.1-flash-lite-preview"

        # Custom vocabulary for prompt
        self.vocabulary: list[str] = []

    def set_vocabulary(self, words: list[str]) -> None:
        """Set custom vocabulary for biasing transcription."""
        self.vocabulary = words

    def _build_prompt(self, language: str | None = None, max_words: int = 0) -> str:
        """Build a rich prompt with vocabulary and replacement rules.

        Unlike Whisper-based providers, Gemini accepts full LLM prompts with no
        character limit. We embed vocabulary and replacement rules directly.

        Args:
            language: Language code hint (e.g. "en", "fr", "ja")
            max_words: Max vocabulary words to include (0 = no limit)
        """
        parts = [
            "Transcribe the audio accurately. Return ONLY the transcribed text, "
            "with no preamble, explanation, or formatting.",
            "Write numbers as digits (e.g. 42 not forty-two).",
        ]

        # Language hint
        if language:
            lang_names = {
                "en": "English",
                "fr": "French",
                "zh": "Chinese",
                "ja": "Japanese",
            }
            lang_name = lang_names.get(language, language)
            parts.append(f"The audio is in {lang_name}.")

        # Vocabulary list (no character limit)
        vocab = self.vocabulary
        if vocab:
            if max_words > 0:
                vocab = vocab[:max_words]
            parts.append(
                f"Use these exact spellings when these words appear: "
                f"{', '.join(vocab)}."
            )

        # Replacement rules embedded in prompt
        try:
            rules = replacements.get_manager().replacements
            if rules and get_setting("replacements_enabled"):
                rule_strs = [f'"{r["from"]}" -> "{r["to"]}"' for r in rules]
                parts.append(
                    f"Apply these word replacements in the output: "
                    f"{'; '.join(rule_strs)}."
                )
        except Exception:
            pass  # Replacements not initialized yet

        return "\n".join(parts)

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
        max_vocab_words: int = 0,
    ) -> dict:
        """Transcribe audio data using Gemini API.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect
            max_vocab_words: Max vocabulary words in prompt (0 = no limit)

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time', 'provider'
        """
        total_start = time.time()

        # Guard against empty/tiny audio — Gemini hallucinates from prompt vocabulary
        min_duration = get_setting("min_recording_duration") or 0.3
        estimated_duration = max(0, (len(audio_data) - 44) / (16000 * 2))
        if estimated_duration < min_duration:
            print(
                f"  [Gemini] Audio too short ({estimated_duration:.2f}s < {min_duration}s), skipping"
            )
            return {
                "text": "",
                "language": language or "unknown",
                "language_probability": 0.0,
                "duration": estimated_duration,
                "processing_time": 0.0,
                "provider": "gemini",
            }

        lang_mode = language.upper() if language else "AUTO-DETECT"
        print(f"  [Gemini] transcribe() called with language={lang_mode}")

        # --- Build prompt ---
        prompt = self._build_prompt(language=language, max_words=max_vocab_words)
        vocab_count = len(self.vocabulary)
        if vocab_count > 0:
            used = (
                min(max_vocab_words, vocab_count)
                if max_vocab_words > 0
                else vocab_count
            )
            print(f"  [Gemini] Using prompt with {used} vocab words (no char limit)")

        # --- Send inline audio bytes and call API ---
        inference_start = time.time()

        audio_part = types.Part.from_bytes(data=audio_data, mime_type="audio/wav")
        response = self.client.models.generate_content(
            model=self.model,
            contents=[audio_part, prompt],
        )

        inference_time = (time.time() - inference_start) * 1000

        full_text = response.text.strip() if response.text else ""

        # Apply canonical casing from vocabulary and track usage
        full_text, matched_words = apply_vocabulary_casing(full_text, self.vocabulary)
        if matched_words:
            vocabulary.get_manager().record_usage(matched_words)

        # Apply word replacements (if enabled) — safety net, also in prompt
        if get_setting("replacements_enabled"):
            full_text = replacements.get_manager().apply_replacements(full_text)

        # Filter profanity (if enabled)
        if get_setting("content_filter"):
            full_text = get_filter().filter(full_text)

        # Gemini doesn't return audio duration — estimate from WAV size
        duration = max(0, (len(audio_data) - 44) / (16000 * 2))

        # Detected language: Gemini doesn't report it, use hint or "unknown"
        detected_language = language or "unknown"

        total_time = time.time() - total_start

        print(
            f"  [Timing] API={inference_time:.0f}ms | "
            f"total={total_time * 1000:.0f}ms | audio={duration:.1f}s"
        )

        return {
            "text": full_text,
            "language": detected_language,
            "language_probability": 1.0,
            "duration": duration,
            "processing_time": total_time,
            "provider": "gemini",
        }


# Singleton instance
_gemini_stt: GeminiSTT | None = None


def get_gemini_stt() -> GeminiSTT:
    """Get or create the Gemini STT singleton."""
    global _gemini_stt
    if _gemini_stt is None:
        _gemini_stt = GeminiSTT()
    return _gemini_stt


def is_gemini_available() -> bool:
    """Check if Gemini API key is available."""
    return bool(os.environ.get("GEMINI_API_KEY"))
