"""Gemma 4 E4B local STT provider using mlx-vlm on Apple Silicon.

Runs Gemma 4 E4B (4-bit quantized) locally via MLX for fully offline,
zero-cost speech-to-text. Quality is acceptable for English and French,
weaker for Chinese. Best suited as an offline fallback when cloud APIs
are unavailable.

Model: mlx-community/gemma-4-e4b-it-4bit (~5.2 GB, needs ~6 GB unified memory)
Requires: mlx-vlm >= 0.4.3 (install with: uv sync --extra local-gemma)
"""

import gc
import logging
import re
import tempfile
import time
from pathlib import Path

import replacements
from content_filter import get_filter
from settings import get_setting

logger = logging.getLogger(__name__)

MODEL_ID = "mlx-community/gemma-4-e4b-it-4bit"


class Gemma4STT:
    """Gemma 4 E4B local STT using mlx-vlm."""

    def __init__(self):
        self.model = None
        self.processor = None
        self.vocabulary: list[str] = []
        self._loaded = False

    def _ensure_model_loaded(self):
        """Lazy-load the model on first use."""
        if self._loaded:
            return

        from mlx_vlm import load

        logger.info(f"Loading Gemma 4 E4B model: {MODEL_ID}")
        print(f"  [Gemma4] Loading model {MODEL_ID} (first call, may take a few seconds)...")
        load_start = time.perf_counter()
        self.model, self.processor = load(MODEL_ID)
        load_time = time.perf_counter() - load_start
        print(f"  [Gemma4] Model loaded in {load_time:.1f}s")
        self._loaded = True

        # Warmup inference with a tiny silence WAV
        self._warmup()

    def _warmup(self):
        """Run a short dummy inference to warm up the model."""
        import struct

        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        # Create a 0.1s silence WAV (16kHz, mono, 16-bit PCM)
        num_samples = 1600  # 0.1s at 16kHz
        wav_data = bytearray()
        # WAV header
        data_size = num_samples * 2
        wav_data.extend(b"RIFF")
        wav_data.extend(struct.pack("<I", 36 + data_size))
        wav_data.extend(b"WAVEfmt ")
        wav_data.extend(struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16))
        wav_data.extend(b"data")
        wav_data.extend(struct.pack("<I", data_size))
        wav_data.extend(b"\x00" * data_size)

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(bytes(wav_data))
            warmup_path = f.name

        try:
            prompt = apply_chat_template(
                self.processor, self.model.config,
                "Transcribe the audio.", num_audios=1,
            )
            generate(
                self.model, self.processor, prompt,
                audio=[warmup_path], max_tokens=10, temperature=0.0,
            )
            print("  [Gemma4] Warmup inference done")
        except Exception as e:
            logger.warning(f"Warmup inference failed (non-fatal): {e}")
        finally:
            Path(warmup_path).unlink(missing_ok=True)

    def set_vocabulary(self, words: list[str]) -> None:
        """Set custom vocabulary for biasing transcription."""
        self.vocabulary = words

    def _build_prompt(self, language: str | None = None, max_words: int = 0) -> str:
        """Build transcription prompt with optional language and vocabulary hints."""
        lang_names = {
            "en": "English",
            "fr": "French",
            "zh": "Chinese",
            "ja": "Japanese",
        }

        if language and language in lang_names:
            lang_name = lang_names[language]
            parts = [
                f"Transcribe the following speech segment in {lang_name}. "
                f"You MUST output only {lang_name} text. "
                "Only output the transcription, with no newlines. "
                "When transcribing numbers, write the digits.",
            ]
        else:
            parts = [
                "Transcribe the following speech segment in its original language. "
                "Only output the transcription, with no newlines. "
                "When transcribing numbers, write the digits.",
            ]

        vocab = self.vocabulary
        if vocab:
            if max_words > 0:
                vocab = vocab[:max_words]
            parts.append(
                f"Use these exact spellings when these words appear: "
                f"{', '.join(vocab)}."
            )

        return "\n".join(parts)

    def transcribe(
        self,
        audio_data: bytes,
        language: str | None = None,
        max_vocab_words: int = 0,
    ) -> dict:
        """Transcribe audio data using Gemma 4 E4B locally.

        Args:
            audio_data: Raw audio bytes (WAV format, 16kHz mono 16-bit PCM)
            language: Language code (fr, en, etc.) or None for auto-detect
            max_vocab_words: Max vocabulary words in prompt (0 = no limit)

        Returns:
            Dict with 'text', 'language', 'duration', 'processing_time', 'provider'
        """
        import mlx.core as mx
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        total_start = time.perf_counter()

        # Estimate duration from WAV size
        estimated_duration = max(0, (len(audio_data) - 44) / (16000 * 2))

        # Guard against empty/tiny audio
        min_duration = get_setting("min_recording_duration") or 0.3
        if estimated_duration < min_duration:
            print(f"  [Gemma4] Audio too short ({estimated_duration:.2f}s < {min_duration}s), skipping")
            return {
                "text": "",
                "language": language or "unknown",
                "language_probability": 0.0,
                "duration": estimated_duration,
                "processing_time": 0.0,
                "provider": "local",
            }

        # 30s hard limit — longer audio degrades quality
        if estimated_duration > 30:
            logger.warning(f"Audio too long for Gemma 4: {estimated_duration:.1f}s > 30s limit")
            return {
                "text": "",
                "language": language or "unknown",
                "language_probability": 0.0,
                "duration": estimated_duration,
                "processing_time": 0.0,
                "provider": "local",
            }

        lang_mode = language.upper() if language else "AUTO-DETECT"
        print(f"  [Gemma4] transcribe() called with language={lang_mode}")

        self._ensure_model_loaded()

        # Add noise padding to prevent garbled first/last words — Gemma 4
        # needs natural-sounding boundaries, not digital silence or hard cuts
        from audio_utils import add_noise_padding

        audio_data = add_noise_padding(audio_data, pre_ms=200, post_ms=300)

        # Write audio to temp file (mlx-vlm takes file paths)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(audio_data)
            wav_path = f.name

        # Save debug audio for quality diagnostics
        if get_setting("save_debug_audio"):
            from datetime import datetime
            debug_dir = Path(__file__).parent / "debug_audio"
            debug_dir.mkdir(exist_ok=True)
            ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:18]
            debug_path = debug_dir / f"{ts}_{estimated_duration:.1f}s_gemma4_input.wav"
            debug_path.write_bytes(audio_data)
            print(f"  [Gemma4] Debug audio saved: {debug_path.name} ({len(audio_data)} bytes)")

        try:
            prompt_text = self._build_prompt(language=language, max_words=max_vocab_words)
            vocab_count = len(self.vocabulary)
            if vocab_count > 0:
                used = min(max_vocab_words, vocab_count) if max_vocab_words > 0 else vocab_count
                print(f"  [Gemma4] Using prompt with {used} vocab words")

            prompt = apply_chat_template(
                self.processor, self.model.config, prompt_text, num_audios=1,
            )

            inference_start = time.perf_counter()
            gen_result = generate(
                self.model, self.processor, prompt,
                audio=[wav_path], max_tokens=500, temperature=0.0,
            )
            inference_time = (time.perf_counter() - inference_start) * 1000

            # Extract text from GenerationResult
            if hasattr(gen_result, "text"):
                full_text = gen_result.text.strip()
            else:
                full_text = str(gen_result).strip()

        finally:
            Path(wav_path).unlink(missing_ok=True)

        # Strip spurious spaces between non-ASCII characters (Japanese/Chinese
        # never have inter-character spaces; Gemma 4 sometimes inserts them)
        if language in ("ja", "zh"):
            full_text = re.sub(r'(?<=[^\x00-\x7F])\s+(?=[^\x00-\x7F])', '', full_text)

        # Post-processing pipeline (same as all other providers)

        # Apply word replacements (if enabled)
        if get_setting("replacements_enabled"):
            full_text = replacements.get_manager().apply_replacements(full_text)

        # Filter profanity (if enabled)
        if get_setting("content_filter"):
            full_text = get_filter().filter(full_text)

        total_time = time.perf_counter() - total_start

        print(
            f"  [Timing] inference={inference_time:.0f}ms | "
            f"total={total_time * 1000:.0f}ms | audio={estimated_duration:.1f}s"
        )

        # Release MLX/Metal memory to prevent accumulation
        mx.clear_cache()
        gc.collect()

        return {
            "text": full_text,
            "language": language or "unknown",
            "language_probability": 1.0,
            "duration": estimated_duration,
            "processing_time": total_time,
            "provider": "local",
        }


# Singleton instance
_gemma4_stt: Gemma4STT | None = None


def get_gemma4_stt() -> Gemma4STT:
    """Get or create the Gemma 4 STT singleton."""
    global _gemma4_stt
    if _gemma4_stt is None:
        _gemma4_stt = Gemma4STT()
    return _gemma4_stt


def is_gemma4_available() -> bool:
    """Check if mlx-vlm is installed (no API key needed)."""
    try:
        import mlx_vlm  # noqa: F401
        return True
    except ImportError:
        return False
