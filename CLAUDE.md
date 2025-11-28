# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Local speech-to-text web application optimized for Apple Silicon. Uses faster-whisper with distil-large-v3 model for fast French transcription with custom vocabulary support. Push-to-talk interface (Ctrl+Option) with real-time waveform visualization.

## Commands

```bash
# Start the application (installs deps, runs server at http://127.0.0.1:8000)
./scripts/start.sh

# Or manually:
cd backend && uv sync && uv run uvicorn main:app --host 127.0.0.1 --port 8000 --reload

# Lint
cd backend && uv run ruff check .

# Format
cd backend && uv run ruff format .
```

## Architecture

```
Frontend (vanilla JS) ──WebSocket──▶ FastAPI Backend ──▶ faster-whisper STT Engine
     │                                    │
     ├─ Key chord detection (Ctrl+Opt)    ├─ /ws - Audio streaming endpoint
     ├─ WebAudio recording → WAV          ├─ /api/vocabulary - GET/POST vocabulary
     └─ Waveform visualization            └─ Serves static frontend from /static
```

**Key Flow:**
1. User holds Ctrl+Option → browser records audio via MediaRecorder
2. On release, webm audio is converted to WAV client-side using AudioContext
3. WAV sent over WebSocket to `/ws` endpoint
4. `STTEngine.transcribe()` runs in thread pool (non-blocking)
5. Result JSON returned with text, language, duration, processing_time

**STT Engine (`stt_engine.py`):**
- Singleton pattern via `get_engine()`
- Model loads on FastAPI lifespan startup
- Custom vocabulary passed via `initial_prompt` (currently disabled for testing)
- Speed optimizations: `beam_size=1`, `best_of=1`, `vad_filter=True`

## Key Files

| File | Purpose |
|------|---------|
| `backend/main.py` | FastAPI app, WebSocket handler, vocabulary API |
| `backend/stt_engine.py` | Whisper model wrapper, transcription logic |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |

## Configuration

- **Model**: `large-v3` (configurable in `STTEngine.__init__`)
- **Language**: French (`fr`) by default
- **Vocabulary**: `["TEMPEST"]` - extend via API or `stt_engine.py`
- **Push-to-talk**: Ctrl+Option chord (browser focus required)
