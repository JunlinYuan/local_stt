# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Local speech-to-text web application optimized for Apple Silicon. Uses lightning-whisper-mlx with large-v3 model for GPU-accelerated multi-language transcription. Push-to-talk interface with real-time waveform visualization.

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
     │                                │  /api/transcribe - HTTP POST (client)    │ ──▶ lightning-whisper-mlx
     ├─ Key chord detection           │  /api/settings/* - Settings API          │      (Metal GPU)
     ├─ WebAudio recording → WAV      │  Serves static frontend from /static     │
     └─ Waveform visualization        └──────────────────────────────────────────┘
                                                           ▲
Global Hotkey Client (hotkey_client.py) ───HTTP POST───────┘
     │
     ├─ System-wide hotkey detection (pynput)
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
- Model loads + warmup on FastAPI lifespan startup
- Uses Metal GPU via MLX framework
- Language auto-detection when `language=None` (default)

## Key Files

| File | Purpose |
|------|---------|
| `backend/main.py` | FastAPI app, WebSocket handler, HTTP transcribe API |
| `backend/stt_engine.py` | Whisper model wrapper, transcription logic |
| `backend/settings.py` | Schema-driven settings system (add new settings here) |
| `backend/vocabulary.py` | Vocabulary manager with file watcher |
| `backend/vocabulary.txt` | Custom vocabulary words (auto-reloads) |
| `backend/hotkey_client.py` | Global hotkey daemon, audio recording, clipboard |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |

## Configuration

Settings stored in `backend/settings.json`, managed via web UI or API.

**To add a new setting:** Add entry to `SETTINGS_SCHEMA` in `settings.py` with `default`, `type`, and optional `options`/`min`/`max`. API and UI handle it automatically.

**Current settings:**
- `language`: `""` (auto-detect), `"en"`, `"fr"`, `"zh"`, `"ja"`
- `keybinding`: `"ctrl"` or `"shift"` (+ Option)

**Fixed config (in code):**
- Model: `large-v3`
- Vocabulary: Edit `backend/vocabulary.txt` (auto-reloads) or use web UI

## Usage Modes

| Mode | What | When to Use |
|------|------|-------------|
| **Web UI** | `./scripts/start.sh` then open browser | Debug, see waveform, view transcription history |
| **Global Client** | Both scripts running | System-wide hotkey, auto-clipboard, headless use |

Note: Global client requires macOS Accessibility permissions for your terminal app.
