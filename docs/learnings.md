# Local STT - Research Learnings

Documentation of key findings from researching local speech-to-text solutions.

## Model Comparison (Speed Focus)

| Model | Speed vs Vanilla Whisper | Size | WER Impact |
|-------|-------------------------|------|------------|
| **distil-large-v3** | 5.8x faster | 756M params | ~1% increase |
| **Whisper Turbo (v3)** | ~3x faster | 809M params | Minimal |
| **faster-whisper** | 4x faster | Same as base | None (inference engine) |
| **whisper.cpp + CoreML** | 3x faster | Same as base | None |

### Recommendation
**faster-whisper with distil-large-v3** provides the best speed/accuracy balance for Apple Silicon.

## Custom Vocabulary (No Training Required)

### Method 1: Initial Prompt
```python
# Bias transcription toward specific terms
result = model.transcribe(
    audio,
    initial_prompt="Context: TEMPEST, Kubernetes, FastAPI. "
)
```

### Method 2: Token Suppression
Suppress commonly misheard tokens to force alternatives:
```python
# If "SDR" keeps being transcribed as "STR"
suppress_tokens = [token_id_for("STR")]
```

## Fine-tuning for Accents

### When to Consider
- WER > 15% on your speech
- Specific accent/dialect not well-represented
- Domain-specific vocabulary beyond what initial_prompt can handle

### LoRA Fine-tuning Results (French)
- Whisper medium: 16% → 9% WER on Common Voice
- Whisper large: 13.9% → 8.15% WER

### Resources
- [Whisper Fine-tuning Event Winner (French)](https://huggingface.co/bofenghuang/whisper-medium-french)
- [Diabolocom Fine-tuning Guide](https://www.diabolocom.com/research/fine-tuning-asr-focus-on-whisper/)

## Apple Silicon Optimizations

### whisper.cpp Benchmark (M1 Max)
- Large-v3 model: ~8.8s for 19-min audio
- CoreML provides ~3x speedup over CPU
- Metal acceleration available

### faster-whisper on Mac
- Uses CTranslate2 backend
- Supports int8 quantization for further speedup
- Works well with Apple Silicon (CPU mode)

## Speed Optimization Settings

```python
# Fastest configuration
config = {
    "beam_size": 1,      # Reduce from default 5
    "best_of": 1,        # Reduce from default 5
    "vad_filter": True,  # Skip silence
    "compression_ratio_threshold": 2.4,
    "log_prob_threshold": -1.0,
}
```

## References

- [faster-whisper GitHub](https://github.com/SYSTRAN/faster-whisper)
- [distil-whisper HuggingFace](https://huggingface.co/distil-whisper/distil-large-v3)
- [mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest)
- [Whisper Variants Comparison](https://towardsai.net/p/machine-learning/whisper-variants-comparison)
