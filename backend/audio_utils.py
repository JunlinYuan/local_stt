"""
Audio utilities for WAV processing, normalization, and preprocessing.

Centralizes audio handling for all STT providers:
- RMS volume calculation
- Dynamic range compression (volume normalization)
- Audio preprocessing pipeline
"""

import numpy as np

from settings import get_min_volume_rms, get_setting

# WAV format constants
WAV_HEADER_SIZE = 44
SAMPLE_RATE = 16000


def calculate_audio_rms(audio_data: bytes) -> float:
    """Calculate RMS (root mean square) volume of WAV audio data.

    Args:
        audio_data: Raw WAV file bytes (with 44-byte header)

    Returns:
        RMS value (0 = silence, ~3000 = normal speech, 32767 = max)
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return 0.0

    samples = np.frombuffer(audio_data[WAV_HEADER_SIZE:], dtype=np.int16)

    if len(samples) == 0:
        return 0.0

    rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))
    return float(rms)


def normalize_audio(
    audio_data: bytes,
    target_rms: float = 3000.0,
    max_gain_db: float = 30.0,
) -> tuple[bytes, float, float, float]:
    """Apply simple gain normalization to audio volume.

    Boosts quiet audio toward target RMS with hard clipping for peaks.
    Optimized for speed - single pass through audio data.

    Args:
        audio_data: Raw WAV file bytes (with 44-byte header)
        target_rms: Target RMS level (default 3000, typical speech level for 16-bit)
        max_gain_db: Maximum gain to apply in dB (prevents noise amplification)

    Returns:
        Tuple of (normalized WAV bytes, original RMS, gain in dB, final RMS)
    """
    if len(audio_data) <= WAV_HEADER_SIZE:
        return audio_data, 0.0, 0.0, 0.0

    header = audio_data[:WAV_HEADER_SIZE]
    samples = np.frombuffer(audio_data[WAV_HEADER_SIZE:], dtype=np.int16)

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

    return header + samples_out.tobytes(), current_rms, gain_db, final_rms


def preprocess_audio(audio_data: bytes) -> tuple[bytes, dict]:
    """Main preprocessing pipeline for audio before transcription.

    Optimized for speed - minimizes array passes:
    1. If normalization enabled: single call to normalize_audio (returns all RMS values)
    2. If disabled: single RMS calculation

    Args:
        audio_data: Raw WAV file bytes

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

    # Calculate duration from WAV size (16-bit mono 16kHz)
    if len(audio_data) > WAV_HEADER_SIZE:
        info["duration"] = (len(audio_data) - WAV_HEADER_SIZE) / (SAMPLE_RATE * 2)

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

    # Volume threshold check (use processed RMS for comparison)
    min_rms = get_min_volume_rms()
    if min_rms > 0 and info["processed_rms"] < min_rms:
        info["skipped"] = True

    return audio_data, info
