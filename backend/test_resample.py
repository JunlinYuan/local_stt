"""Tests for audio resampling (resample_to_16k in audio_utils)."""

import wave
from pathlib import Path

import numpy as np
import pytest


class TestResampleTo16k:
    """Unit tests for audio_utils.resample_to_16k()."""

    def test_no_resample_when_already_16k(self):
        """If native rate is 16kHz, return input unchanged."""
        from audio_utils import resample_to_16k

        audio = np.array([100, -200, 300, -400], dtype=np.int16)
        result = resample_to_16k(audio, 16000)
        np.testing.assert_array_equal(result, audio)

    def test_48k_to_16k_length(self):
        """48kHz->16kHz: output should be 1/3 the length."""
        from audio_utils import resample_to_16k

        audio = np.zeros(48000, dtype=np.int16)
        result = resample_to_16k(audio, 48000)
        assert len(result) == 16000

    def test_96k_to_16k_length(self):
        """96kHz->16kHz: output should be 1/6 the length."""
        from audio_utils import resample_to_16k

        audio = np.zeros(96000, dtype=np.int16)
        result = resample_to_16k(audio, 96000)
        assert len(result) == 16000

    def test_44100_to_16k_length(self):
        """44.1kHz->16kHz: non-integer ratio still works."""
        from audio_utils import resample_to_16k

        audio = np.zeros(44100, dtype=np.int16)
        result = resample_to_16k(audio, 44100)
        assert len(result) == 16000

    def test_output_dtype_is_int16(self):
        """Output should always be int16."""
        from audio_utils import resample_to_16k

        audio = np.random.randint(-32768, 32767, 48000, dtype=np.int16)
        result = resample_to_16k(audio, 48000)
        assert result.dtype == np.int16

    def test_preserves_silence(self):
        """Resampling silence should produce silence."""
        from audio_utils import resample_to_16k

        audio = np.zeros(48000, dtype=np.int16)
        result = resample_to_16k(audio, 48000)
        np.testing.assert_array_equal(result, np.zeros(16000, dtype=np.int16))

    def test_sine_wave_frequency_preserved(self):
        """A 440Hz sine wave should maintain frequency after resampling."""
        from audio_utils import resample_to_16k

        # Generate 1 second of 440Hz at 48kHz
        t = np.arange(48000) / 48000.0
        sine_48k = (np.sin(2 * np.pi * 440 * t) * 16000).astype(np.int16)
        result = resample_to_16k(sine_48k, 48000)

        # FFT to find peak frequency
        fft = np.abs(np.fft.rfft(result.astype(np.float64)))
        freqs = np.fft.rfftfreq(len(result), 1 / 16000)
        peak_freq = freqs[np.argmax(fft)]
        assert abs(peak_freq - 440) < 5  # Within 5Hz

    def test_max_amplitude_clips_gracefully(self):
        """Near-max amplitude should clip to int16 range, not overflow."""
        from audio_utils import resample_to_16k

        audio = np.full(48000, 32000, dtype=np.int16)
        result = resample_to_16k(audio, 48000)
        assert np.all(result >= -32768)
        assert np.all(result <= 32767)

    def test_snr_improvement_vs_naive_downsample(self):
        """Proper resampling should suppress aliasing that naive skip causes."""
        from audio_utils import resample_to_16k

        # Generate 440Hz (in-band) + 10kHz (above 8kHz Nyquist for 16kHz)
        # The anti-aliasing filter should remove the 10kHz component,
        # but naive every-3rd-sample skipping will alias it down.
        t = np.arange(48000 * 2) / 48000.0  # 2 seconds at 48kHz
        signal = (
            np.sin(2 * np.pi * 440 * t) * 8000  # In-band signal
            + np.sin(2 * np.pi * 10000 * t) * 8000  # High-freq that should be filtered
        ).astype(np.int16)

        # Proper resampling (should filter out 10kHz)
        proper = resample_to_16k(signal, 48000)

        # Naive downsample (10kHz aliases to 10000 - 16000/2*2 = ... appears as distortion)
        naive = signal[::3]

        # Reference: pure 440Hz at 16kHz (what we want)
        t16 = np.arange(len(proper)) / 16000.0
        ref = (np.sin(2 * np.pi * 440 * t16) * 8000).astype(np.int16)

        # Calculate error vs reference (skip edges due to filter transients)
        trim = 500
        min_len = min(len(proper), len(naive), len(ref)) - trim
        proper_err = np.sqrt(
            np.mean(
                (
                    proper[trim:min_len].astype(float)
                    - ref[trim:min_len].astype(float)
                )
                ** 2
            )
        )
        naive_err = np.sqrt(
            np.mean(
                (
                    naive[trim:min_len].astype(float)
                    - ref[trim:min_len].astype(float)
                )
                ** 2
            )
        )

        # Proper resampling should have much lower error (filtered out 10kHz)
        assert proper_err < naive_err, (
            f"Proper ({proper_err:.1f}) should be less than naive ({naive_err:.1f})"
        )

    def test_zero_sample_rate_raises(self):
        """Zero sample rate should raise ValueError, not ZeroDivisionError."""
        from audio_utils import resample_to_16k

        audio = np.zeros(100, dtype=np.int16)
        with pytest.raises(ValueError, match="positive"):
            resample_to_16k(audio, 0)

    def test_negative_sample_rate_raises(self):
        """Negative sample rate should raise ValueError."""
        from audio_utils import resample_to_16k

        audio = np.zeros(100, dtype=np.int16)
        with pytest.raises(ValueError, match="positive"):
            resample_to_16k(audio, -48000)

    def test_short_audio(self):
        """Very short audio (< 100 samples) should resample without error."""
        from audio_utils import resample_to_16k

        audio = np.array([1000, -1000, 500, -500, 200], dtype=np.int16)
        result = resample_to_16k(audio, 48000)
        assert result.dtype == np.int16
        assert len(result) > 0


class TestResampleWithDebugAudio:
    """Integration tests using actual recorded debug audio files."""

    DEBUG_DIR = Path(__file__).parent / "debug_audio" / "test_run_01"

    @pytest.fixture
    def raw_wav_files(self):
        """Get list of raw WAV files from test_run_01."""
        if not self.DEBUG_DIR.exists():
            pytest.skip("Debug audio directory not found")
        files = sorted(self.DEBUG_DIR.glob("*_raw.wav"))
        if not files:
            pytest.skip("No raw WAV files found")
        return files

    def test_debug_wavs_are_16k_mono_int16(self, raw_wav_files):
        """Verify existing debug WAVs are 16kHz mono int16."""
        for wav_path in raw_wav_files:
            with wave.open(str(wav_path), "rb") as f:
                assert f.getframerate() == 16000, f"{wav_path.name} not 16kHz"
                assert f.getnchannels() == 1, f"{wav_path.name} not mono"
                assert f.getsampwidth() == 2, f"{wav_path.name} not 16-bit"

    def test_resample_roundtrip_preserves_duration(self, raw_wav_files):
        """Upsampling then downsampling should preserve approximate duration."""
        from scipy.signal import resample_poly

        from audio_utils import resample_to_16k

        for wav_path in raw_wav_files[:3]:  # Test first 3 files
            with wave.open(str(wav_path), "rb") as f:
                data = np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16)
                original_duration = len(data) / 16000

            # Simulate: "upsample" to 48k (as if recorded at native rate)
            upsampled = resample_poly(data.astype(np.float64), 3, 1).astype(np.int16)

            # Resample back to 16k
            result = resample_to_16k(upsampled, 48000)
            result_duration = len(result) / 16000

            assert abs(result_duration - original_duration) < 0.01, (
                f"{wav_path.name}: duration mismatch "
                f"{original_duration:.3f}s vs {result_duration:.3f}s"
            )
