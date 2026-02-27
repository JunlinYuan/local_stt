# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Repository:** https://github.com/JunlinYuan/local_stt

## Project Overview

Speech-to-text application with push-to-talk interface. Supports local processing (lightning-whisper-mlx on Apple Silicon, macOS only) and cloud APIs (OpenAI, Groq). Features global hotkey recording, auto-paste to window under mouse cursor. Cross-platform: macOS and Windows 10+.

## Commands

```bash
# Start - macOS (server + global hotkey client)
./start.sh

# Start - Windows (double-click start.bat or in PowerShell)
.\start.ps1

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
1. User holds hotkey (Ctrl, Ctrl+Cmd/Alt, or Shift+Cmd/Alt) → records audio
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
| `backend/platform_utils.py` | Cross-platform abstraction (clipboard, paste, mouse, memory) |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |
| `.env.example` | Template for API keys (copy to `.env`) |

## Configuration

Settings stored in `backend/settings.json`, managed via web UI or API.

**To add a new setting:** Add entry to `SETTINGS_SCHEMA` in `settings.py` with `default`, `type`, and optional `options`/`min`/`max`. API and UI handle it automatically.

**Current settings:** (see `SETTINGS_SCHEMA` in `settings.py` for full list)
- `stt_provider`: `"local"` (macOS only), `"openai"`, or `"groq"` (fastest)
- `language`: `""` (auto-detect), `"en"`, `"fr"`, `"zh"`, `"ja"`
- `keybinding`: `"ctrl_only"`, `"ctrl"` (+Cmd/Alt), or `"shift"` (+Cmd/Alt)
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

## Platform Notes

- **All platform-specific code** lives in `backend/platform_utils.py`. Do not add macOS/Windows-specific imports elsewhere.
- **macOS**: Uses Quartz, objc, pbcopy/pbpaste, AppleScript for paste/focus. Command key as secondary modifier.
- **Windows**: Uses ctypes/win32, pyperclip, pyautogui. Alt key as secondary modifier. No local MLX provider.
- **Settings defaults** are platform-aware (e.g., default provider is 'groq' on Windows, 'local' on macOS).
- **pynput Key.cmd_l** does not exist on Windows — the code uses `_SECONDARY_MOD_KEY` which is `cmd_l` on macOS, `alt_l` on Windows.

## Usage

**macOS**: Run `./start.sh` to start both server and global hotkey client. Opens web UI automatically. Global hotkey requires Accessibility permissions for your terminal app.

**Windows**: Double-click `start.bat` or run `.\start.ps1` in PowerShell. Requires a Groq or OpenAI API key in `.env`.
