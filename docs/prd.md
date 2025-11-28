# Local Speech-to-Text Tool — PRD

## Overview

A local web-based speech-to-text application optimized for Apple Silicon, primarily for French transcription with occasional English. Focus on speed with custom vocabulary support.

## Goals

1. **Fast transcription** — Speed prioritized over maximum accuracy
2. **Offline-first** — All processing happens locally
3. **Custom vocabulary** — Bias toward user-defined technical terms
4. **Daily driver** — Reliable enough for regular use

## User Requirements

| Requirement | Details |
|-------------|---------|
| Primary language | French (with English mixed in) |
| Hardware | Apple Silicon Mac (Metal acceleration) |
| Transcription modes | Real-time streaming + batch |
| Output | Display on screen |
| Key feature | Custom vocabulary/hotwords support |

## Technical Architecture

### Model Selection

**Primary: `faster-whisper` with `distil-large-v3`**

Rationale:
- 5.8x faster than vanilla Whisper
- 51% smaller model (756M vs 1.55B parameters)
- <1% WER degradation on out-of-distribution data
- Supports `initial_prompt` for vocabulary biasing
- Compatible with whisper.cpp for additional optimization

**Fallback options to test:**
- `whisper.cpp` with CoreML (native Metal support)
- `bofenghuang/whisper-medium-french` (pre-fine-tuned for French)

### System Components

```
┌─────────────────────────────────────────────────────────┐
│                    Web UI (Local)                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Record Btn  │  │ Transcript  │  │ Vocabulary Cfg  │  │
│  │ (Push-key)  │  │   Display   │  │   (Hotwords)    │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                   Python Backend                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   FastAPI   │  │ Audio Queue │  │  STT Engine     │  │
│  │  WebSocket  │  │  + VAD      │  │ (faster-whisper)│  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Key Features

#### 1. Push-to-Talk Recording
- **Trigger**: Hold Control + Option keys simultaneously
- **Chord detection**: Single key press (Control only OR Option only) does nothing
- Visual feedback during recording (pulsing indicator)
- Recording starts when both keys held, stops when either released
- Audio preprocessing (noise reduction optional)

#### 2. Dual Transcription Modes
- **Batch mode**: Record → Release → Transcribe (more accurate)
- **Real-time mode**: Stream audio → Progressive transcription (faster feedback)

#### 3. Custom Vocabulary (initial_prompt)
```python
# Initial vocabulary configuration
vocabulary = {
    "technical_terms": ["TEMPEST"],  # Start with one term for testing
    # Add more terms as needed
}

# Passed to Whisper as initial_prompt
prompt = f"Context: {', '.join(all_terms)}. "
```

**Approach**: Option A — Use `initial_prompt` only (no fine-tuning initially)

#### 4. Language Configuration
```python
config = {
    "language": "fr",           # Primary: French
    "task": "transcribe",       # Not translate
    "initial_prompt": "...",    # Custom vocabulary
    "beam_size": 1,             # Speed optimization
    "best_of": 1,               # Speed optimization
}
```

## Tech Stack

| Component | Technology |
|-----------|------------|
| Backend | Python 3.11+ with FastAPI |
| STT Engine | faster-whisper (CTranslate2) |
| Model | distil-whisper-large-v3 |
| Frontend | HTML/JS (vanilla or lightweight framework) |
| Audio | WebAudio API → WebSocket |
| IPC | WebSocket for real-time streaming |

## Implementation Phases

### Phase 1: Core MVP
- [ ] Basic web UI with record button
- [ ] faster-whisper integration
- [ ] Batch transcription mode
- [ ] French language configuration

### Phase 2: Enhanced Features
- [ ] Real-time streaming transcription
- [ ] Custom vocabulary configuration UI
- [ ] Keyboard shortcut (push-to-talk)
- [ ] Multiple model selection

### Phase 3: Optimization
- [ ] Model comparison benchmarks
- [ ] Fine-tuning pipeline (optional)
- [ ] whisper.cpp CoreML testing
- [ ] Memory/performance profiling

## Success Metrics

- Transcription latency: <2s for 10s audio clip
- Word accuracy: >90% on French speech
- Custom vocabulary recognition: >95% for configured terms

## Decisions Made

| Question | Decision |
|----------|----------|
| Fine-tuning approach | **Option A**: `initial_prompt` only (no training initially) |
| Push-to-talk trigger | **Control + Option** keys held together |
| VAD | **No** — manual push-to-release only |
| Initial vocabulary | **TEMPEST** (single term for testing) |

## Open Questions

1. **Starting model?** — Start with `distil-large-v3` (fastest) or test both?

## References

- [faster-whisper GitHub](https://github.com/SYSTRAN/faster-whisper)
- [distil-whisper HuggingFace](https://huggingface.co/distil-whisper/distil-large-v3)
- [Whisper Fine-tuning Guide](https://huggingface.co/blog/fine-tune-whisper)
- [French Whisper Models](https://huggingface.co/bofenghuang/whisper-medium-french)
