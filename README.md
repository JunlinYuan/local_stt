# Local STT

Speech-to-text application with push-to-talk interface, supporting both local processing (lightning-whisper-mlx on Apple Silicon) and cloud APIs (OpenAI, Groq).

## Features

### Core
- **Push-to-Talk**: Hold hotkey to record, release to transcribe
- **Multiple STT Providers**: Local (MLX), OpenAI API, or Groq API (fastest)
- **Multi-language**: Auto-detect or specify language (en, fr, zh, ja, etc.)
- **Custom Vocabulary**: Bias transcription toward domain-specific terms

### Global Hotkey Client
- **System-wide Recording**: Works in any app via configurable hotkey
- **Auto-paste**: Transcribed text automatically pasted to focused app
- **Focus-follows-mouse (FFM)**: Optional auto-focus window under cursor (toggleable)
- **Clipboard Preservation**: Original clipboard restored after paste

### Web UI
- **Real-time Waveform**: Visual feedback during recording
- **Day/Night Theme**: Toggle with localStorage persistence
- **Dictation History**: Full-page panel with copy/search
- **Settings Panel**: All configuration accessible via UI

### Audio Processing
- **Volume Normalization**: Boost quiet audio, limit loud audio
- **Minimum Duration Filter**: Skip accidental key taps
- **Volume Threshold**: Skip silent recordings
- **Content Filter**: Filter likely misrecognized words

## Quick Start

```bash
./start.sh
```

Opens http://127.0.0.1:8000 automatically.

### Granting Accessibility Permissions

The global hotkey client requires **Accessibility permissions** for your terminal app:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click the **+** button and add your terminal app (e.g., Terminal, iTerm2, Warp)
3. Restart the terminal after granting permission

Without this, the global hotkey won't detect key presses outside the browser.

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- Python 3.11+ (managed via uv)
- ~3GB disk space for local model

### For Cloud Providers (Optional)

Cloud APIs are faster than local processing. **Groq is recommended** (free tier, fastest).

```bash
cp .env.example .env
# Edit .env with your keys
```

- **Groq** (recommended): https://console.groq.com/keys - Free tier, ~200x real-time speed
- **OpenAI** (optional): https://platform.openai.com/api-keys - Paid only

If a provider is selected but its API key is missing, the app falls back to local processing.

## Configuration

All settings managed via web UI (click gear icon) or API (`/api/settings`):

| Setting | Description |
|---------|-------------|
| **STT Provider** | Local (MLX), OpenAI API, or Groq API |
| **Language** | Auto-detect or specific (en, fr, zh, ja) |
| **Keybinding** | Ctrl only, Ctrl+Option, or Shift+Option |
| **FFM** | Focus-follows-mouse on/off |
| **Max Duration** | Recording timeout (30s - 5min) |
| **Min Duration** | Skip accidental taps |
| **Volume Threshold** | Skip silent recordings |
| **Content Filter** | Filter misrecognized profanity |

### Custom Vocabulary

Edit via web UI (click "VOCAB" in the top bar) or directly in `backend/vocabulary.txt`. Changes auto-reload.

## Project Structure

```
local_stt/
├── backend/
│   ├── main.py              # FastAPI server, WebSocket handler
│   ├── stt_engine.py        # STT routing to providers
│   ├── openai_stt.py        # OpenAI Whisper API client
│   ├── groq_stt.py          # Groq Whisper API client
│   ├── settings.py          # Schema-driven settings system
│   ├── vocabulary.py        # Vocabulary manager with file watcher
│   └── hotkey_client.py     # Global hotkey daemon
├── frontend/
│   ├── index.html           # Web UI
│   ├── styles.css           # Styling with theme support
│   └── app.js               # Key detection, audio, WebSocket
├── docs/
│   ├── prd.md               # Product requirements
│   └── learnings.md         # Model research notes
├── start.sh                 # Launch server + client
└── .env.example             # API key template
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
     ├─ Focus-follows-mouse (optional)
     └─ Auto-paste + clipboard restore
```

## Development

```bash
# Lint
cd backend && uv run ruff check .

# Format
cd backend && uv run ruff format .
```

## License

MIT
