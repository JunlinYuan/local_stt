# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Repository:** https://github.com/JunlinYuan/local_stt

## Project Overview

Speech-to-text application with push-to-talk interface. Supports local processing (lightning-whisper-mlx on Apple Silicon) and cloud APIs (OpenAI, Groq). Features global hotkey recording, auto-paste to window under mouse cursor.

## Commands

```bash
# Start (server + global hotkey client)
./start.sh

# Lint
cd backend && uv run ruff check .

# Format
cd backend && uv run ruff format .
```

## Architecture

```
Frontend (vanilla JS) ──WebSocket──▶  FastAPI Backend ──▶ STT Provider
     │                                     │                   │
     ├─ Hotkey detection                   ├─ /ws endpoint     ├─ Local (MLX)
     ├─ WebAudio → WAV                     ├─ /api/transcribe  ├─ OpenAI API
     └─ Waveform viz                       └─ /api/settings    └─ Groq API
                                                  ▲
Global Hotkey Client ─────────HTTP POST───────────┘
     │
     ├─ System-wide pynput hotkey
     ├─ sounddevice recording
     ├─ Mouse tracking for targeted paste (toggleable)
     └─ Auto-paste to window under cursor + clipboard restore
```

**Key Flow:**
1. User holds hotkey (Ctrl, Ctrl+Cmd, or Shift+Cmd) → records audio
2. On release, audio converted to WAV and sent to backend
3. Backend routes to configured STT provider (local/OpenAI/Groq)
4. Result JSON returned with text, language, duration, processing_time
5. Global client: auto-pastes to window under mouse (without raising it), restores clipboard

## Key Files

| File | Purpose |
|------|---------|
| `backend/main.py` | FastAPI app, WebSocket handler, HTTP transcribe API |
| `backend/stt_engine.py` | Local Whisper model wrapper, transcription routing |
| `backend/openai_stt.py` | OpenAI Whisper API client |
| `backend/groq_stt.py` | Groq Whisper API client (fast, cheap) |
| `backend/settings.py` | Schema-driven settings system (add new settings here) |
| `backend/vocabulary.py` | Vocabulary manager with file watcher |
| `backend/vocabulary.txt` | Custom vocabulary words (auto-reloads) |
| `backend/hotkey_client.py` | Global hotkey daemon, audio recording, clipboard |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |
| `.env.example` | Template for API keys (copy to `.env`) |

## Configuration

Settings stored in `backend/settings.json`, managed via web UI or API.

**To add a new setting:** Add entry to `SETTINGS_SCHEMA` in `settings.py` with `default`, `type`, and optional `options`/`min`/`max`. API and UI handle it automatically.

**Current settings:** (see `SETTINGS_SCHEMA` in `settings.py` for full list)
- `stt_provider`: `"local"`, `"openai"`, or `"groq"` (fastest)
- `language`: `""` (auto-detect), `"en"`, `"fr"`, `"zh"`, `"ja"`
- `keybinding`: `"ctrl_only"`, `"ctrl"` (+Cmd), or `"shift"` (+Cmd)
- `ffm_enabled`: Mouse tracking for targeted paste (default: true)
- `max_recording_duration`: Safety timeout in seconds (default: 240)
- `min_recording_duration`: Skip accidental taps (default: 0.3s)
- `min_volume_rms`: Skip silent recordings (default: 100, 0=disabled)
- `volume_normalization`: Boost quiet / limit loud audio (default: true)
- `content_filter`: Filter misrecognized profanity (default: true)

**Fixed config (in code):**
- Local model: `large-v3`
- Groq model: `whisper-large-v3-turbo`
- Vocabulary: Edit `backend/vocabulary.txt` (auto-reloads) or use web UI

**Environment:**
- `OPENAI_API_KEY`: Required for OpenAI provider (from .env or shell)
- `GROQ_API_KEY`: Required for Groq provider (get from https://console.groq.com)

## Usage

Run `./start.sh` to start both server and global hotkey client. Opens web UI automatically.

Note: Global hotkey requires macOS Accessibility permissions for your terminal app.
