"""Speech-to-text engine using lightning-whisper-mlx for Apple Silicon."""

import gc
import tempfile
import time
from datetime import datetime
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

    def _build_initial_prompt(
        self, language: str | None = None, max_words: int = 0
    ) -> str:
        """Build initial_prompt from vocabulary.

        Args:
            language: Language code (unused, kept for API consistency)
            max_words: Max vocabulary words to include (0 = no limit)
        """
        if not self.vocabulary:
            return ""
        words = self.vocabulary[:max_words] if max_words > 0 else self.vocabulary
        return f"Vocabulary: {', '.join(words)}. "

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
        max_vocab_words: int = 0,
    ) -> dict:
        """Transcribe audio data to text.

        Args:
            audio_data: Raw audio bytes (WAV format)
            language: Language code (fr, en, etc.) or None for auto-detect
            max_vocab_words: Max vocabulary words in prompt (0 = no limit)

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
            initial_prompt = self._build_initial_prompt(
                language, max_words=max_vocab_words
            )
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


def _save_debug_audio(
    audio_data: bytes,
    suffix: str,
    timestamp: str,
    duration: float,
) -> Path | None:
    """Save audio to debug_audio/ directory. Returns path or None on failure."""
    try:
        debug_dir = Path(__file__).parent / "debug_audio"
        debug_dir.mkdir(exist_ok=True)
        filename = f"{timestamp}_{duration:.1f}s_{suffix}.wav"
        path = debug_dir / filename
        path.write_bytes(audio_data)
        print(f"  [Debug] Saved: {path.name}")
        return path
    except Exception as e:
        print(f"  [Debug] Failed to save audio: {e}")
        return None


def _save_debug_metadata(
    timestamp: str,
    preprocess_info: dict,
    provider: str,
    language: str | None,
    language_override: str | None,
    vocab_words_used: int,
    result: dict,
) -> None:
    """Write companion metadata file for debug audio."""
    try:
        debug_dir = Path(__file__).parent / "debug_audio"
        path = debug_dir / f"{timestamp}_meta.txt"
        duration = preprocess_info.get("duration", 0)
        lines = [
            f"Timestamp: {timestamp}",
            f"Duration: {duration:.2f}s",
            f"Provider: {provider}",
            f"Language setting: {language or 'AUTO'}",
        ]
        if language_override:
            lines.append(f"Language override: {language_override} (short clip)")
        lines += [
            f"Detected language: {result.get('language', '?')}",
            f"RMS (original): {preprocess_info.get('original_rms', 0):.0f}",
            f"RMS (processed): {preprocess_info.get('processed_rms', 0):.0f}",
            f"Gain: {preprocess_info.get('gain_db', 0):+.1f}dB",
            f"Normalized: {preprocess_info.get('normalized', False)}",
            f"Padded: {preprocess_info.get('padded', False)}",
            f"Vocab words in prompt: {vocab_words_used}",
            f"Transcription: {result.get('text', '')}",
            f"Processing time: {result.get('processing_time', 0):.2f}s",
        ]
        path.write_text("\n".join(lines) + "\n")
    except Exception as e:
        print(f"  [Debug] Failed to save metadata: {e}")


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
    save_debug = get_setting("save_debug_audio")
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:18]  # Include ms

    # Save raw audio before any preprocessing
    raw_duration = (
        max(0, (len(audio_data) - 44) / (16000 * 2)) if len(audio_data) > 44 else 0
    )
    if save_debug:
        _save_debug_audio(audio_data, "raw", timestamp, raw_duration)

    # Preprocess audio (normalize + volume check + silence padding)
    audio_data, preprocess_info = preprocess_audio(audio_data)
    audio_duration = preprocess_info.get("duration", 0)

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

    # Diagnostic: flag short clips
    if audio_duration > 0 and audio_duration < 3.0:
        print(f"  [SHORT CLIP] {audio_duration:.1f}s — accuracy may be reduced")

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

    # Short clip language override: force a specific language for clips < 3s
    language_override = None
    if language is None and audio_duration > 0 and audio_duration < 3.0:
        override = get_setting("short_clip_language_override")
        if override:
            language_override = override
            language = override
            print(
                f"  [Language] Short clip override: AUTO -> {override.upper()} "
                f"({audio_duration:.1f}s < 3.0s)"
            )

    # Short clip vocab limit
    max_vocab_words = 0
    if audio_duration > 0 and audio_duration < 3.0:
        limit = get_setting("short_clip_vocab_limit")
        if limit and limit > 0:
            max_vocab_words = int(limit)
            print(f"  [Vocab] Short clip limit: {max_vocab_words} words")

    provider = get_stt_provider()

    # Save final preprocessed audio (exact bytes sent to STT)
    if save_debug:
        lang_tag = language or "auto"
        _save_debug_audio(
            audio_data, f"{provider}_{lang_tag}_final", timestamp, audio_duration
        )

    # Build audio_info for frontend volume indicator
    audio_info = {
        "original_rms": preprocess_info.get("original_rms", 0),
        "processed_rms": preprocess_info.get("processed_rms", 0),
        "gain_db": preprocess_info.get("gain_db", 0),
        "normalized": preprocess_info.get("normalized", False),
    }

    result = None

    if provider == "groq":
        from groq_stt import get_groq_stt, is_groq_available

        if not is_groq_available():
            print("  [Warning] Groq API key not available, falling back to local")
            provider = "local"
        else:
            print("  [Router] Using Groq Whisper API")
            groq_stt = get_groq_stt()
            result = groq_stt.transcribe(
                audio_data, language, max_vocab_words=max_vocab_words
            )
            result["audio_info"] = audio_info

    if result is None and provider == "openai":
        from openai_stt import get_openai_stt, is_openai_available

        if not is_openai_available():
            print("  [Warning] OpenAI API key not available, falling back to local")
            provider = "local"
        else:
            print("  [Router] Using OpenAI Whisper API")
            openai_stt = get_openai_stt()
            result = openai_stt.transcribe(
                audio_data, language, max_vocab_words=max_vocab_words
            )
            result["audio_info"] = audio_info

    if result is None:
        # Default: local MLX model
        print("  [Router] Using local lightning-whisper-mlx")
        engine = get_engine()
        result = engine.transcribe(
            audio_data, language, max_vocab_words=max_vocab_words
        )
        result["provider"] = "local"
        result["audio_info"] = audio_info

    # Save debug metadata after transcription
    if save_debug:
        vocab_mgr = vocabulary.get_manager()
        total_vocab = len(vocab_mgr.words) if vocab_mgr else 0
        vocab_used = (
            min(max_vocab_words, total_vocab) if max_vocab_words > 0 else total_vocab
        )
        _save_debug_metadata(
            timestamp,
            preprocess_info,
            provider,
            language,
            language_override,
            vocab_used,
            result,
        )

    return result
