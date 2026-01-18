"""Speech-to-text engine using lightning-whisper-mlx for Apple Silicon."""

import gc
import tempfile
import time
from pathlib import Path
from typing import Optional, TYPE_CHECKING

# Lazy imports for MLX - only loaded when local transcription is used
# This saves ~2GB memory when using cloud providers (Groq/OpenAI)
if TYPE_CHECKING:
    from lightning_whisper_mlx import LightningWhisperMLX

import replacements
import vocabulary
from content_filter import get_filter
from settings import get_setting, get_stt_provider
from vocabulary_utils import apply_vocabulary_casing


class STTEngine:
    """Wrapper for lightning-whisper-mlx model."""

    def __init__(
        self,
        model_size: str = "large-v3",
        batch_size: int = 6,
        quant: Optional[str] = None,  # None, "4bit", or "8bit"
    ):
        """Initialize the STT engine.

        Args:
            model_size: Model to use (large-v3, distil-large-v3, medium, etc.)
            batch_size: Batch size for inference (lower for larger models)
            quant: Quantization level (None, "4bit", "8bit")
        """
        self.model_size = model_size
        self.batch_size = batch_size
        self.quant = quant
        self.model: Optional[LightningWhisperMLX] = None
        self._model_path: Optional[str] = None  # Path to loaded model weights

        # Custom vocabulary for initial_prompt (loaded from vocabulary.txt)
        self.vocabulary: list[str] = []

    def load_model(self) -> None:
        """Load the Whisper model and warm up inference."""
        # Lazy import MLX libraries - only loaded when local transcription is used
        from lightning_whisper_mlx import LightningWhisperMLX

        quant_str = self.quant or "none"
        print(
            f"Loading model: {self.model_size} (batch_size={self.batch_size}, quant={quant_str})..."
        )
        start = time.time()

        self.model = LightningWhisperMLX(
            model=self.model_size,
            batch_size=self.batch_size,
            quant=self.quant,
        )
        # Store the model path for direct transcribe_audio calls
        self._model_path = f"./mlx_models/{self.model.name}"

        load_time = time.time() - start
        print(f"Model loaded in {load_time:.2f}s")
        print("  → Using: MLX backend (Apple Silicon GPU)")

        # Warm up inference with a short silent audio
        print("  → Warming up inference...")
        warmup_start = time.time()
        self._warmup_inference()
        warmup_time = time.time() - warmup_start
        print(f"  → Warmup complete in {warmup_time:.2f}s")

    def _warmup_inference(self) -> None:
        """Run a dummy inference to warm up GPU kernels and caches."""
        import wave

        # Create a minimal valid WAV file (0.1s of silence)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            with wave.open(f.name, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes(b"\x00" * 3200)  # 0.1s of silence
            temp_path = f.name

        try:
            self.model.transcribe(audio_path=temp_path)
        except Exception:
            pass  # Ignore errors on warmup
        finally:
            Path(temp_path).unlink(missing_ok=True)

    def set_vocabulary(self, words: list[str]) -> None:
        """Set custom vocabulary for biasing transcription."""
        self.vocabulary = words

    def _build_initial_prompt(self, language: str | None = None) -> str:
        """Build initial_prompt from vocabulary."""
        if not self.vocabulary:
            return ""
        return f"Vocabulary: {', '.join(self.vocabulary)}. "

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
    ) -> dict:
        """Transcribe audio data to text.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time'
        """
        # Lazy import MLX transcribe function
        from lightning_whisper_mlx.transcribe import transcribe_audio

        # Lazy load model on first use
        if self.model is None or self._model_path is None:
            print("  [STTEngine] Lazy loading model (first local transcription)...")
            self.load_model()

        total_start = time.time()

        # Log the language setting being used
        lang_mode = language.upper() if language else "AUTO-DETECT"
        print(f"  [STTEngine] transcribe() called with language={lang_mode}")

        # --- Timing: Write audio to temp file ---
        prep_start = time.time()
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(audio_data)
            temp_path = f.name
        prep_time = (time.time() - prep_start) * 1000  # ms

        try:
            # --- Timing: Model inference ---
            inference_start = time.time()

            # Build initial_prompt from vocabulary for better recognition
            initial_prompt = self._build_initial_prompt(language)
            if initial_prompt:
                print(f"  [STTEngine] Using initial_prompt: {initial_prompt[:50]}...")

            # Use transcribe_audio directly to support initial_prompt
            result = transcribe_audio(
                audio=temp_path,
                path_or_hf_repo=self._model_path,
                language=language,
                batch_size=self.batch_size,
                initial_prompt=initial_prompt if initial_prompt else None,
            )
            inference_time = (time.time() - inference_start) * 1000  # ms

            full_text = result.get("text", "").strip()
            # Apply canonical casing from vocabulary and track usage
            full_text, matched_words = apply_vocabulary_casing(
                full_text, self.vocabulary
            )
            if matched_words:
                vocabulary.get_manager().record_usage(matched_words)
            # Apply word replacements (if enabled)
            if get_setting("replacements_enabled"):
                full_text = replacements.get_manager().apply_replacements(full_text)
            # Filter likely misrecognized profanity (if enabled)
            if get_setting("content_filter"):
                full_text = get_filter().filter(full_text)
            detected_language = result.get("language", language or "unknown")

            # Calculate audio duration from segments
            segments = result.get("segments", [])
            # Debug: print actual segment structure
            if segments:
                print(f"  [Debug] Last segment: {segments[-1]}")
            duration = 0
            if segments:
                last_segment = segments[-1]
                if isinstance(last_segment, dict):
                    duration = last_segment.get("end", 0)
                elif isinstance(last_segment, (list, tuple)):
                    # Format is [start, end, text] - end is at index 1
                    duration = float(last_segment[1]) if len(last_segment) > 1 else 0

            if duration == 0:
                # Fallback: estimate from WAV size (16-bit mono 16kHz)
                duration = max(0, (len(audio_data) - 44) / (16000 * 2))

            total_time = time.time() - total_start

            # Detailed timing log
            print(
                f"  [Timing] prep={prep_time:.0f}ms | inference={inference_time:.0f}ms | "
                f"total={total_time * 1000:.0f}ms | audio={duration:.1f}s"
            )

            return {
                "text": full_text,
                "language": detected_language,
                "language_probability": 1.0,  # MLX doesn't provide this
                "duration": duration,
                "processing_time": total_time,
            }

        finally:
            # Clean up temp file
            Path(temp_path).unlink(missing_ok=True)

            # Release MLX/Metal memory to prevent accumulation over long sessions
            # Without this, memory grows ~10-15GB over a day of use
            import mlx.core as mx

            mx.clear_memory_cache()
            gc.collect()


# Singleton instance
_engine: Optional[STTEngine] = None


def get_engine() -> STTEngine:
    """Get or create the STT engine singleton."""
    global _engine
    if _engine is None:
        _engine = STTEngine()
    return _engine


def transcribe_audio_with_provider(
    audio_data: bytes,
    language: str | None = None,
) -> dict:
    """Transcribe audio using the configured provider (local, OpenAI, or Groq).

    This is the main entry point for transcription that:
    1. Preprocesses audio (normalize volume, check threshold)
    2. Routes to the appropriate backend based on settings

    Args:
        audio_data: Raw audio bytes (WAV format)
        language: Language code (fr, en, etc.) or None for auto-detect

    Returns:
        Dict with 'text', 'language', 'duration', 'processing_time', 'provider'
    """
    from audio_utils import preprocess_audio

    start_time = time.time()

    # Preprocess audio (normalize + volume check)
    audio_data, preprocess_info = preprocess_audio(audio_data)

    # Log preprocessing results
    if preprocess_info.get("normalized"):
        gain_str = (
            f"{preprocess_info['gain_db']:+.1f}dB"
            if preprocess_info["gain_db"] != 0
            else "0dB"
        )
        print(
            f"  [Audio] Normalized: RMS {preprocess_info['original_rms']:.0f} -> "
            f"{preprocess_info['processed_rms']:.0f} ({gain_str})"
        )
    else:
        print(
            f"  [Audio] RMS: {preprocess_info['original_rms']:.0f} (normalization disabled)"
        )

    # Early return if audio too quiet
    if preprocess_info.get("skipped"):
        print("  [Audio] Audio too quiet, skipping transcription")
        return {
            "text": "",
            "language": language or "unknown",
            "language_probability": 0.0,
            "duration": preprocess_info.get("duration", 0.0),
            "processing_time": time.time() - start_time,
            "skipped": "low_volume",
            "provider": "none",
        }

    provider = get_stt_provider()

    # Build audio_info for frontend volume indicator
    audio_info = {
        "original_rms": preprocess_info.get("original_rms", 0),
        "processed_rms": preprocess_info.get("processed_rms", 0),
        "gain_db": preprocess_info.get("gain_db", 0),
        "normalized": preprocess_info.get("normalized", False),
    }

    if provider == "groq":
        from groq_stt import get_groq_stt, is_groq_available

        if not is_groq_available():
            print("  [Warning] Groq API key not available, falling back to local")
            provider = "local"
        else:
            print("  [Router] Using Groq Whisper API")
            groq_stt = get_groq_stt()
            result = groq_stt.transcribe(audio_data, language)
            result["audio_info"] = audio_info
            return result

    if provider == "openai":
        from openai_stt import get_openai_stt, is_openai_available

        if not is_openai_available():
            print("  [Warning] OpenAI API key not available, falling back to local")
            provider = "local"
        else:
            print("  [Router] Using OpenAI Whisper API")
            openai_stt = get_openai_stt()
            result = openai_stt.transcribe(audio_data, language)
            result["audio_info"] = audio_info
            return result

    # Default: local MLX model
    print("  [Router] Using local lightning-whisper-mlx")
    engine = get_engine()
    result = engine.transcribe(audio_data, language)
    result["provider"] = "local"
    result["audio_info"] = audio_info
    return result
