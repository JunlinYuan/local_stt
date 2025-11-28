# Local STT

Local speech-to-text application using faster-whisper, optimized for French transcription on Apple Silicon.

## Features

- **Push-to-Talk**: Hold `Ctrl + Option` to record
- **Offline**: All processing happens locally
- **Fast**: Uses faster-whisper with large-v3 model
- **French-first**: Configured for French with English mixed in

## Quick Start

```bash
cd backend
./scripts/start.sh
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
│   ├── main.py          # FastAPI server
│   ├── stt_engine.py    # Whisper wrapper
│   └── pyproject.toml   # Dependencies
├── frontend/
│   ├── index.html       # Web UI
│   ├── styles.css       # Styling
│   └── app.js           # Key detection + audio
├── scripts/
│   └── start.sh         # Startup script
└── docs/
    ├── prd.md           # Requirements
    └── learnings.md     # Research notes
```

## Usage

1. Open the web UI
2. Allow microphone access
3. Hold **Ctrl + Option** together to start recording
4. Release to transcribe
5. View transcription result

## Configuration

Edit `backend/stt_engine.py` to change:
- Model: `large-v3` (default), `distil-large-v3` (faster, English-only)
- Language: `fr` (default)
- Custom vocabulary via `initial_prompt`

## License

MIT
