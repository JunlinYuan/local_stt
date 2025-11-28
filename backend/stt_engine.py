"""Speech-to-text engine using faster-whisper."""

import io
import time
from pathlib import Path
from typing import Optional

from faster_whisper import WhisperModel


class STTEngine:
    """Wrapper for faster-whisper model."""

    def __init__(
        self,
        model_size: str = "large-v3",  # Use full model for French support
        device: str = "auto",
        compute_type: str = "auto",
    ):
        """Initialize the STT engine.

        Args:
            model_size: Model to use (distil-large-v3, large-v3, etc.)
            device: Device to run on (auto, cpu, cuda)
            compute_type: Computation type (auto, float16, int8, etc.)
        """
        self.model_size = model_size
        self.model: Optional[WhisperModel] = None
        self.device = device
        self.compute_type = compute_type

        # Custom vocabulary for initial_prompt
        self.vocabulary: list[str] = ["TEMPEST"]

    def load_model(self) -> None:
        """Load the Whisper model."""
        print(f"Loading model: {self.model_size}...")
        start = time.time()

        self.model = WhisperModel(
            self.model_size,
            device=self.device,
            compute_type=self.compute_type,
        )

        elapsed = time.time() - start
        print(f"Model loaded in {elapsed:.2f}s")

    def set_vocabulary(self, words: list[str]) -> None:
        """Set custom vocabulary for biasing transcription."""
        self.vocabulary = words

    def _build_initial_prompt(self, language: str = "fr") -> str:
        """Build initial_prompt from vocabulary in target language."""
        if not self.vocabulary:
            # Return a French prompt to bias toward French output
            if language == "fr":
                return "Transcription en français. "
            return ""

        # Use French context for French transcription
        if language == "fr":
            return f"Transcription en français. Vocabulaire: {', '.join(self.vocabulary)}. "
        return f"Context: {', '.join(self.vocabulary)}. "

    def transcribe(
        self,
        audio_data: bytes,
        language: str = "fr",
    ) -> dict:
        """Transcribe audio data to text.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.)

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time'
        """
        if self.model is None:
            raise RuntimeError("Model not loaded. Call load_model() first.")

        start = time.time()

        # Create file-like object from bytes
        audio_file = io.BytesIO(audio_data)

        # Transcribe with speed optimizations
        segments, info = self.model.transcribe(
            audio_file,
            language=language,
            task="transcribe",
            # initial_prompt disabled for testing
            beam_size=1,  # Speed optimization
            best_of=1,  # Speed optimization
            vad_filter=True,  # Filter out silence
            condition_on_previous_text=False,  # Prevent hallucinations
        )

        # Collect all segments
        text_parts = []
        for segment in segments:
            text_parts.append(segment.text)

        full_text = "".join(text_parts).strip()
        processing_time = time.time() - start

        return {
            "text": full_text,
            "language": info.language,
            "language_probability": info.language_probability,
            "duration": info.duration,
            "processing_time": processing_time,
        }


# Singleton instance
_engine: Optional[STTEngine] = None


def get_engine() -> STTEngine:
    """Get or create the STT engine singleton."""
    global _engine
    if _engine is None:
        _engine = STTEngine()
    return _engine
