"""
Audio utilities for WAV processing, normalization, and preprocessing.

Centralizes audio handling for all STT providers:
- RMS volume calculation
- Dynamic range compression (volume normalization)
- Audio preprocessing pipeline
"""

import struct
from math import gcd

import numpy as np

from settings import get_min_volume_rms, get_setting

# WAV format constants
WAV_HEADER_SIZE = 44  # Minimum header size (RIFF + fmt + data headers, no extra chunks)
SAMPLE_RATE = 16000


def _find_wav_data_offset(audio_data: bytes) -> int:
    """Find the offset where PCM sample data begins in a WAV file.

    Parses RIFF/WAV chunks to find the 'data' chunk, handling extra chunks
    (e.g. LIST, INFO) that may appear between 'fmt ' and 'data'.

    Returns the byte offset of the first sample (after the 'data' chunk header).
    Falls back to 44 if parsing fails.
    """
    if len(audio_data) < 44:
        return WAV_HEADER_SIZE

    # Verify RIFF header
    if audio_data[:4] != b"RIFF" or audio_data[8:12] != b"WAVE":
        return WAV_HEADER_SIZE

    # Walk chunks starting after "WAVE" (offset 12)
    offset = 12
    while offset + 8 <= len(audio_data):
        chunk_id = audio_data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", audio_data, offset + 4)[0]

        if chunk_id == b"data":
            return offset + 8  # data starts right after chunk header

        # Skip this chunk (header is 8 bytes + chunk_size payload)
        offset += 8 + chunk_size
        # WAV chunks are word-aligned (pad to even)
        if chunk_size % 2 == 1:
            offset += 1

    # Fallback: standard 44-byte header
    return WAV_HEADER_SIZE


def _rebuild_wav(samples: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Build a clean 44-byte-header WAV from raw int16 samples.

    Produces a minimal RIFF/WAV with only fmt and data chunks — no extra
    metadata chunks that might confuse strict parsers like miniaudio.
    """
    data_bytes = samples.astype(np.int16).tobytes()
    data_size = len(data_bytes)
    header = bytearray(44)
    struct.pack_into("4s", header, 0, b"RIFF")
    struct.pack_into("<I", header, 4, 36 + data_size)
    struct.pack_into("4s", header, 8, b"WAVE")
    struct.pack_into("4s", header, 12, b"fmt ")
    struct.pack_into("<I", header, 16, 16)  # fmt chunk size
    struct.pack_into("<H", header, 20, 1)  # PCM format
    struct.pack_into("<H", header, 22, 1)  # mono
    struct.pack_into("<I", header, 24, sample_rate)
    struct.pack_into("<I", header, 28, sample_rate * 2)  # byte rate
    struct.pack_into("<H", header, 32, 2)  # block align
    struct.pack_into("<H", header, 34, 16)  # bits per sample
    struct.pack_into("4s", header, 36, b"data")
    struct.pack_into("<I", header, 40, data_size)
    return bytes(header) + data_bytes


def resample_to_16k(
    audio: np.ndarray, original_rate: int, target_rate: int = SAMPLE_RATE
) -> np.ndarray:
    """Resample audio from original_rate to target_rate using polyphase filtering.

    Applies a proper anti-aliasing low-pass FIR filter before downsampling,
    preventing the noise artifacts that occur when PortAudio does real-time
    resampling from a mic's native rate (e.g. 48kHz) to 16kHz.

    Args:
        audio: Audio samples as np.int16 array
        original_rate: Source sample rate (e.g. 48000)
        target_rate: Target sample rate (default: 16000)

    Returns:
        Resampled np.int16 array at target_rate
    """
    if original_rate == target_rate:
        return audio

    if original_rate <= 0 or target_rate <= 0:
        raise ValueError(
            f"Sample rates must be positive: original={original_rate}, target={target_rate}"
        )

    from scipy.signal import resample_poly

    # Calculate up/down factors, reduced by GCD
    # e.g., 48000->16000: gcd=16000, up=1, down=3
    # e.g., 44100->16000: gcd=100, up=160, down=441
    g = gcd(target_rate, original_rate)
    up = target_rate // g
    down = original_rate // g

    # Process in float64 for precision, resample with anti-aliasing filter
    resampled = resample_poly(audio.astype(np.float64), up, down)

    # Clip to int16 range (filter overshoot can exceed original range)
    np.clip(resampled, -32768, 32767, out=resampled)
    return resampled.astype(np.int16)


def calculate_audio_rms(audio_data: bytes) -> float:
    """Calculate RMS (root mean square) volume of WAV audio data.

    Args:
        audio_data: Raw WAV file bytes (with header)

    Returns:
        RMS value (0 = silence, ~3000 = normal speech, 32767 = max)
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return 0.0

    data_offset = _find_wav_data_offset(audio_data)
    samples = np.frombuffer(audio_data[data_offset:], dtype=np.int16)

    if len(samples) == 0:
        return 0.0

    rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
    return float(rms)


def normalize_audio(
    audio_data: bytes,
    target_rms: float = 3000.0,
    max_gain_db: float = 40.0,
) -> tuple[bytes, float, float, float]:
    """Apply simple gain normalization to audio volume.

    Boosts quiet audio toward target RMS with hard clipping for peaks.
    Optimized for speed - single pass through audio data.

    Args:
        audio_data: Raw WAV file bytes (with valid WAV header)
        target_rms: Target RMS level (default 3000, typical speech level for 16-bit)
        max_gain_db: Maximum gain to apply in dB (prevents noise amplification)

    Returns:
        Tuple of (normalized WAV bytes, original RMS, gain in dB, final RMS)
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return audio_data, 0.0, 0.0, 0.0

    data_offset = _find_wav_data_offset(audio_data)
    samples = np.frombuffer(audio_data[data_offset:], dtype=np.int16)

    if len(samples) == 0:
        return audio_data, 0.0, 0.0, 0.0

    # Convert to float32 once (faster than float64 for our needs)
    samples_float = samples.astype(np.float32)

    # Calculate current RMS
    current_rms = float(np.sqrt(np.mean(samples_float**2)))

    if current_rms < 1.0:  # Near silence, don't amplify noise
        return audio_data, current_rms, 0.0, current_rms

    # Calculate required gain (clamped to max/min)
    gain_linear = target_rms / current_rms
    max_gain_linear = 10 ** (max_gain_db / 20)  # 20dB = 10x
    gain_linear = max(0.1, min(gain_linear, max_gain_linear))

    # Calculate actual gain in dB for logging
    gain_db = float(20 * np.log10(gain_linear))

    # Apply gain and hard clip in one step
    samples_float *= gain_linear
    np.clip(samples_float, -32768, 32767, out=samples_float)
    samples_out = samples_float.astype(np.int16)

    # Calculate final RMS (avoid second pass if no clipping occurred)
    final_rms = float(np.sqrt(np.mean(samples_out.astype(np.float32) ** 2)))

    # Rebuild clean WAV with standard 44-byte header (no extra chunks)
    return _rebuild_wav(samples_out), current_rms, gain_db, final_rms


def add_noise_padding(
    audio_data: bytes,
    pre_ms: int = 200,
    post_ms: int = 300,
    noise_amplitude: float = 30.0,
) -> bytes:
    """Add low-level noise padding before and after audio.

    Unlike zero-silence padding, noise padding mimics ambient mic noise.
    This prevents Gemma 4 from hallucinating at speech boundaries — the model
    was trained on real-world audio with natural ambient noise, not digital silence.

    Args:
        audio_data: Raw WAV file bytes (with valid WAV header)
        pre_ms: Milliseconds of noise to add before audio
        post_ms: Milliseconds of noise to add after audio
        noise_amplitude: Peak amplitude of noise in int16 range (default 30,
            roughly -60dB, similar to ambient mic self-noise)

    Returns:
        Padded WAV bytes with clean 44-byte header
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return audio_data

    data_offset = _find_wav_data_offset(audio_data)
    samples = np.frombuffer(audio_data[data_offset:], dtype=np.int16)

    pre_samples = (pre_ms * SAMPLE_RATE) // 1000
    post_samples = (post_ms * SAMPLE_RATE) // 1000

    rng = np.random.default_rng()
    pre_noise = (rng.standard_normal(pre_samples) * noise_amplitude).astype(np.int16)
    post_noise = (rng.standard_normal(post_samples) * noise_amplitude).astype(np.int16)

    padded = np.concatenate([pre_noise, samples, post_noise])
    return _rebuild_wav(padded)


def add_silence_padding(
    audio_data: bytes,
    pre_silence_ms: int = 100,
    post_silence_ms: int = 200,
) -> bytes:
    """Add silence padding before and after audio.

    Helps Whisper models which were trained on 30-second clips with natural
    starts/stops. Padding reduces edge artifacts on short clips.

    Args:
        audio_data: Raw WAV file bytes (with valid WAV header)
        pre_silence_ms: Milliseconds of silence to add before audio
        post_silence_ms: Milliseconds of silence to add after audio

    Returns:
        Padded WAV bytes with updated header
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return audio_data

    data_offset = _find_wav_data_offset(audio_data)
    samples = np.frombuffer(audio_data[data_offset:], dtype=np.int16)

    pre_samples = (pre_silence_ms * SAMPLE_RATE) // 1000
    post_samples = (post_silence_ms * SAMPLE_RATE) // 1000

    padded = np.concatenate(
        [
            np.zeros(pre_samples, dtype=np.int16),
            samples,
            np.zeros(post_samples, dtype=np.int16),
        ]
    )

    # Rebuild clean WAV with standard 44-byte header
    return _rebuild_wav(padded)


def preprocess_audio(
    audio_data: bytes, skip_transforms: bool = False
) -> tuple[bytes, dict]:
    """Main preprocessing pipeline for audio before transcription.

    Optimized for speed - minimizes array passes:
    1. If normalization enabled: single call to normalize_audio (returns all RMS values)
    2. If disabled: single RMS calculation

    Args:
        audio_data: Raw WAV file bytes
        skip_transforms: If True, skip normalization and silence padding but still
            calculate RMS and duration. Used for Gemma 4 which is sensitive to
            audio transformations.

    Returns:
        Tuple of (processed WAV bytes, info dict)
        Info dict contains: original_rms, processed_rms, normalized, gain_db, skipped, duration
    """
    info = {
        "original_rms": 0.0,
        "processed_rms": 0.0,
        "normalized": False,
        "gain_db": 0.0,
        "skipped": False,
        "duration": 0.0,
    }

    # Calculate duration from WAV data size (16-bit mono 16kHz)
    if len(audio_data) > WAV_HEADER_SIZE:
        data_offset = _find_wav_data_offset(audio_data)
        info["duration"] = (len(audio_data) - data_offset) / (SAMPLE_RATE * 2)

    if skip_transforms:
        # Skip normalization and padding — only calculate RMS for volume check
        original_rms = calculate_audio_rms(audio_data)
        info["original_rms"] = original_rms
        info["processed_rms"] = original_rms
        # Rebuild clean WAV header (strip extra chunks for miniaudio compat)
        data_offset = _find_wav_data_offset(audio_data)
        if data_offset != WAV_HEADER_SIZE:
            samples = np.frombuffer(audio_data[data_offset:], dtype=np.int16)
            audio_data = _rebuild_wav(samples)
        print("  [Audio] Skipping transforms (Gemma 4 mode)")
    else:
        # Apply normalization if enabled (returns all RMS values in one pass)
        if get_setting("volume_normalization"):
            audio_data, original_rms, gain_db, final_rms = normalize_audio(audio_data)
            info["original_rms"] = original_rms
            info["normalized"] = True
            info["gain_db"] = gain_db
            info["processed_rms"] = final_rms
        else:
            # Single RMS calculation when normalization disabled
            original_rms = calculate_audio_rms(audio_data)
            info["original_rms"] = original_rms
            info["processed_rms"] = original_rms

        # Add silence padding for short clips if enabled
        if (
            get_setting("silence_padding")
            and info["duration"] > 0
            and info["duration"] < 5.0
        ):
            original_duration = info["duration"]
            audio_data = add_silence_padding(audio_data)
            info["padded"] = True
            # Recalculate duration after padding
            info["duration"] = (len(audio_data) - WAV_HEADER_SIZE) / (SAMPLE_RATE * 2)
            print(
                f"  [Audio] Added silence padding to {original_duration:.1f}s clip "
                f"(100ms pre + 200ms post) -> {info['duration']:.1f}s"
            )

    # Volume threshold check (use processed RMS for comparison)
    min_rms = get_min_volume_rms()
    if min_rms > 0 and info["processed_rms"] < min_rms:
        info["skipped"] = True

    return audio_data, info
