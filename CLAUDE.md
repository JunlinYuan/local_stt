# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Local speech-to-text web application optimized for Apple Silicon. Uses faster-whisper with large-v3 model for multi-language transcription with auto-detection and custom vocabulary support. Push-to-talk interface (Ctrl+Option) with real-time waveform visualization and debug console.

## Commands

```bash
# Start everything (server + global hotkey client)
./start.sh

# Or start components separately:
./scripts/start.sh         # Server only (with web UI)
./scripts/start-client.sh  # Client only (requires server running)

# Lint
cd backend && uv run ruff check .

# Format
cd backend && uv run ruff format .
```

## Architecture

```
                                      ┌──────────────────────────────────────────┐
                                      │        FastAPI Backend (main.py)          │
                                      │                                           │
Frontend (vanilla JS) ──WebSocket──▶  │  /ws - Audio streaming (browser)         │
     │                                │  /api/transcribe - HTTP POST (client)    │ ──▶ faster-whisper
     ├─ Key chord detection           │  /api/vocabulary - GET/POST vocabulary   │      STT Engine
     ├─ WebAudio recording → WAV      │  Serves static frontend from /static     │
     └─ Waveform visualization        └──────────────────────────────────────────┘
                                                           ▲
Global Hotkey Client (hotkey_client.py) ───HTTP POST───────┘
     │
     ├─ System-wide Ctrl+Opt detection (pynput)
     ├─ Audio recording (sounddevice)
     └─ Auto-copy to clipboard (pbcopy)
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
- Custom vocabulary passed via `initial_prompt` for better term recognition
- Language auto-detection when `language=None` (default)
- Speed optimizations: `beam_size=1`, `best_of=1`, `vad_filter=True`

## Key Files

| File | Purpose |
|------|---------|
| `backend/main.py` | FastAPI app, WebSocket handler, HTTP transcribe API |
| `backend/stt_engine.py` | Whisper model wrapper, transcription logic |
| `backend/hotkey_client.py` | Global hotkey daemon, audio recording, clipboard |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |

## Configuration

- **Model**: `large-v3` (configurable in `STTEngine.__init__`)
- **Language**: Auto-detect (default), or specify code like `"en"`, `"fr"`
- **Vocabulary**: `["TEMPEST"]` - extend via API or `stt_engine.py`
- **Push-to-talk**: Ctrl+Option chord
- **Console panel**: Collapsible debug panel shows console.log/warn/error with timestamps

## Usage Modes

| Mode | What | When to Use |
|------|------|-------------|
| **Web UI** | `./scripts/start.sh` then open browser | Debug, see waveform, view transcription history |
| **Global Client** | Both scripts running | System-wide hotkey, auto-clipboard, headless use |

Note: Global client requires macOS Accessibility permissions for your terminal app.
