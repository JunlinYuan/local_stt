# Local STT

Speech-to-text application with push-to-talk interface. Supports local processing (lightning-whisper-mlx on Apple Silicon) and cloud APIs (OpenAI, Groq). Works on **macOS** and **Windows 10+**.

## Features

### Core
- **Push-to-Talk**: Hold hotkey to record, release to transcribe
- **Multiple STT Providers**: Local (MLX, macOS only — offline but slower), OpenAI API, or Groq API (recommended — fastest and most accurate)
- **Multi-language**: Auto-detect or specify language (en, fr, zh, ja, etc.)
- **Custom Vocabulary**: Bias transcription toward domain-specific terms
- **Cross-platform**: macOS and Windows 10+ support

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

### macOS

```bash
./start.sh
```

### Windows

Double-click `start.bat`, or in PowerShell:

```powershell
.\start.ps1
```

Opens http://127.0.0.1:8000 automatically on both platforms.

### Granting Permissions

**macOS**: The global hotkey client requires **Accessibility permissions** for your terminal app:

1. Open **System Settings** -> **Privacy & Security** -> **Accessibility**
2. Click the **+** button and add your terminal app (e.g., Terminal, iTerm2, Warp)
3. Restart the terminal after granting permission

**Windows**: No special permissions required. If your antivirus flags the keyboard listener, add an exception for the Python process.

## Requirements

### macOS
- macOS with Apple Silicon (M1/M2/M3/M4) for local MLX provider
- Python 3.11+ (managed via uv)
- ~3GB disk space for local model (optional, not needed with cloud providers)

### Windows 10+
- Python 3.11+ (managed via uv)
- A Groq API key (free) or OpenAI API key
- No local MLX model (use Groq or OpenAI cloud providers)

### Installing uv (package manager)

**macOS**:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Windows** (PowerShell):
```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

### Setting Up API Keys

Cloud APIs are significantly faster and more accurate than local processing. **Groq is recommended** (free tier, ~200x real-time speed, best accuracy).

```bash
cp .env.example .env
# Edit .env with your API keys
```

- **Groq** (recommended): https://console.groq.com/keys - Free tier, ~200x real-time speed
- **OpenAI** (optional): https://platform.openai.com/api-keys - Paid only

On macOS, if a cloud provider key is missing, the app falls back to local MLX processing (offline, but slower and less accurate than cloud APIs).
On Windows, a cloud provider API key is **required** (local MLX is not available).

## Configuration

All settings managed via web UI (click gear icon) or API (`/api/settings`):

| Setting | Description |
|---------|-------------|
| **STT Provider** | Local MLX (macOS only, offline but slower), OpenAI API, or Groq API (recommended) |
| **Language** | Auto-detect or specific (en, fr, zh, ja) |
| **Keybinding** | Ctrl only, Ctrl+Alt (Win) / Ctrl+Cmd (Mac), Shift+Alt (Win) / Shift+Cmd (Mac) |
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
│   ├── platform_utils.py    # Cross-platform abstraction (clipboard, paste, mouse, etc.)
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
├── start.sh                 # Launch server + client (macOS/Linux)
├── start.ps1                # Launch server + client (Windows PowerShell)
├── start.bat                # Launch server + client (Windows double-click)
└── .env.example             # API key template
```

## Architecture

```
Frontend (vanilla JS) ──WebSocket──▶  FastAPI Backend ──▶ STT Provider
     │                                     │                   │
     ├─ Hotkey detection                   ├─ /ws endpoint     ├─ Local (MLX, macOS)
     ├─ WebAudio -> WAV                    ├─ /api/transcribe  ├─ OpenAI API
     └─ Waveform viz                       └─ /api/settings    └─ Groq API
                                                  ^
Global Hotkey Client ─────────HTTP POST───────────┘
     │
     ├─ System-wide pynput hotkey
     ├─ sounddevice recording
     ├─ Focus-follows-mouse (optional)
     └─ Auto-paste + clipboard restore
```

### Platform Differences

| Feature | macOS | Windows |
|---------|-------|---------|
| Local MLX provider | Yes (Apple Silicon) | No |
| Cloud providers (Groq/OpenAI) | Yes | Yes |
| Global hotkey | pynput + Quartz | pynput + win32 |
| Clipboard | pbcopy/pbpaste | pyperclip |
| Paste simulation | AppleScript (Cmd+V) | pyautogui (Ctrl+V) |
| Window detection | Quartz CGWindowList | ctypes WindowFromPoint |
| Secondary modifier | Command | Alt |

## Development

```bash
# Lint
cd backend && uv run ruff check .

# Format
cd backend && uv run ruff format .
```

## Troubleshooting

### Windows
- **"uv not found"**: Install uv with `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`, then restart your terminal.
- **No audio input**: Check Settings -> Sound -> Input and ensure a microphone is selected.
- **Keyboard listener not working**: Some antivirus software blocks keyboard hooks. Add an exception for the Python process.
- **"Local MLX provider not available"**: This is expected on Windows. Switch to Groq (free) or OpenAI in Settings.

### macOS
- **Hotkey not working**: Grant Accessibility permissions (System Settings -> Privacy & Security -> Accessibility).
- **Audio device error**: Close other apps using the microphone, or check System Settings -> Sound -> Input.

## License

MIT
