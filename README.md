# Local STT

Local speech-to-text application using lightning-whisper-mlx, optimized for Apple Silicon with Metal GPU acceleration.

## Features

- **Push-to-Talk**: Hold `Shift + Option` (or `Ctrl + Option`) to record
- **Offline**: All processing happens locally
- **Fast**: Uses MLX with Metal GPU (~1.5-2s for short phrases)
- **Multi-language**: Auto-detect or specify language (en, fr, zh, ja)
- **Global Hotkey**: System-wide recording with auto-clipboard

## Quick Start

```bash
./start.sh
```

Then open http://127.0.0.1:8000

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- Python 3.11-3.13 (via uv)
- ~3GB disk space for model

## Project Structure

```
local_stt/
├── backend/
│   ├── main.py           # FastAPI server
│   ├── stt_engine.py     # MLX Whisper wrapper
│   ├── settings.py       # Settings schema
│   └── hotkey_client.py  # Global hotkey daemon
├── frontend/
│   ├── index.html        # Web UI
│   ├── styles.css        # Styling
│   └── app.js            # Key detection + audio
├── scripts/
│   ├── start.sh          # Server startup
│   └── start-client.sh   # Client startup
└── docs/
    ├── prd.md            # Requirements
    └── learnings.md      # Research notes
```

## Usage

### Web UI
1. Open http://127.0.0.1:8000
2. Allow microphone access
3. Hold **Shift + Option** to record
4. Release to transcribe

### Global Hotkey Client
With `./start.sh`, the global client runs alongside the server:
- Hold hotkey anywhere in macOS to record
- Release to transcribe and copy to clipboard
- Requires Accessibility permissions for terminal app

## Configuration

Settings managed via web UI or API (`/api/settings`):
- **Language**: Auto-detect or specific (en, fr, zh, ja)
- **Keybinding**: Ctrl+Option or Shift+Option

## License

MIT
