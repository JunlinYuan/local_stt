# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Repository:** https://github.com/JunlinYuan/local_stt

## Project Overview

Multi-platform speech-to-text application with three implementations:
- **Web** — Vanilla JS frontend + Python FastAPI backend (local/OpenAI/Groq/Gemini STT)
- **macOS** — Native SwiftUI menu bar app, calls Groq API directly via LocalSTTCore
- **iOS** — Native SwiftUI app, calls Groq API directly via LocalSTTCore

The web version supports local processing (Gemma 4 E4B via mlx-vlm, with lightning-whisper-mlx as fallback) and multiple cloud APIs. The native apps are pure SwiftUI and require no backend — they share code via the LocalSTTCore Swift package.

## Commands

```bash
# Web: Start server + global hotkey client
./start.sh

# Web: Lint / Format
cd backend && uv run ruff check .
cd backend && uv run ruff format .

# macOS app: Build
cd macos && xcodegen generate && xcodebuild -scheme LocalSTTMac build

# macOS app: Install to /Applications
cp -R ~/Library/Developer/Xcode/DerivedData/LocalSTTMac-*/Build/Products/Debug/LocalSTTMac.app /Applications/

# iOS app: Build
cd ios && xcodegen generate && xcodebuild -scheme LocalSTT build
```

## Architecture

```
┌── Web (Python backend) ──────────────────┬── Native Apps (SwiftUI) ──────────────┐
│                                          │                                       │
│ Frontend (vanilla JS)                    │  LocalSTTCore (shared Swift package)   │
│   ├─ Hotkey detection                    │    ├─ GroqService                      │
│   ├─ WebAudio → WAV                      │    ├─ VocabularyManager                │
│   └─ Waveform viz                        │    ├─ ReplacementManager               │
│         │ WebSocket                      │    ├─ HallucinationFilter              │
│         ▼                                │    ├─ WAVEncoder                        │
│ FastAPI Backend ──▶ STT Provider         │    ├─ KeychainHelper                   │
│                                          │    ├─ AudioNormalizer                  │
│                                          │    └─ SilencePadder                    │
│   ├─ /ws, /api/transcribe               │         │                              │
│   └─ /api/settings                       │    ┌────┴────┐                         │
│         ▲                                │    │         │                         │
│ Global Hotkey Client (Python)            │  iOS App  macOS App                    │
│   ├─ pynput hotkey                       │  SwiftUI  SwiftUI + MenuBarExtra       │
│   ├─ sounddevice recording               │           + GlobalHotkeyManager        │
│   └─ Auto-paste (FFM)                    │           + AutoPasteManager (FFM)     │
└──────────────────────────────────────────┴───────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| **Web Backend** | |
| `backend/main.py` | FastAPI app, WebSocket handler, HTTP transcribe API |
| `backend/stt_engine.py` | STT provider routing, audio preprocessing |
| `backend/openai_stt.py` | OpenAI Whisper API client |
| `backend/groq_stt.py` | Groq Whisper API client (fast, cheap) |
| `backend/gemini_stt.py` | Gemini 3.1 Flash-Lite STT (vocab+replacements in prompt) |
| `backend/gemma4_stt.py` | Gemma 4 E4B local STT via mlx-vlm (offline, ~2s latency) |
| `backend/audio_utils.py` | Audio preprocessing (resampling, WAV parsing, noise padding) |
| `backend/settings.py` | Schema-driven settings system (17 settings) |
| `backend/vocabulary.py` | Vocabulary manager with file watcher |
| `backend/hotkey_client.py` | Global hotkey daemon, audio recording, clipboard |
| `frontend/app.js` | Key detection, audio recording, WebSocket client |
| **Shared Swift Package** | |
| `ios/Package.swift` | LocalSTTCore package definition (macOS 14+, iOS 17+) |
| `ios/Sources/LocalSTTCore/` | 10 shared modules: GroqService, VocabularyManager, ReplacementManager, HallucinationFilter, WAVEncoder, KeychainHelper, TranscriptionResult, ReplacementRule, AudioNormalizer, SilencePadder |
| **macOS App** | |
| `macos/project.yml` | xcodegen config (references `../ios` for LocalSTTCore) |
| `macos/Sources/LocalSTTMac/MacAppState.swift` | State manager, recording lifecycle, bulk export/import |
| `macos/Sources/LocalSTTMac/Views/MainWindowView.swift` | Main window with keyboard shortcuts (NSEvent local monitor) |
| `macos/Sources/LocalSTTMac/Services/AutoPasteManager.swift` | FFM: mouse tracking, window detection, CGEvent paste |
| `macos/Sources/LocalSTTMac/Services/GlobalHotkeyManager.swift` | NSEvent global/local monitors, Left Control (keyCode 59) |
| **iOS App** | |
| `ios/project.yml` | xcodegen config for iOS app |
| `ios/Sources/LocalSTT/` | iOS SwiftUI views, AppState, AudioRecorder |
| **Docs** | |
| `docs/prd.md` | Full requirements and technical decisions |
| `docs/learnings.md` | Model comparison research, optimization notes |

## Configuration

### Web Backend Settings

Stored in `backend/settings.json`, managed via web UI or API. **To add a setting:** add to `SETTINGS_SCHEMA` in `settings.py`.

**Current settings** (see `SETTINGS_SCHEMA` for full list of 17):
- `stt_provider`: `"local"` (Gemma 4 E4B, offline), `"openai"`, `"groq"` (fastest), or `"gemini"`
- `language`: `""` (auto-detect), `"en"`, `"fr"`, `"zh"`, `"ja"`
- `keybinding`: `"ctrl_only"`, `"ctrl"` (+Cmd), or `"shift"` (+Cmd)
- `ffm_enabled` / `ffm_mode`: Mouse tracking + raise mode (`track_only`, `raise_on_hover`)
- `clipboard_sync_delay` / `paste_delay`: Timing for clipboard operations (default: 0.05s)
- `replacements_enabled`: Apply word replacement rules (default: true)
- `max_recording_duration` / `min_recording_duration` / `min_volume_rms`
- `volume_normalization` / `content_filter` / `silence_padding`
- `save_debug_audio` / `short_clip_language_override` / `short_clip_vocab_limit`

### Native App Settings

macOS/iOS settings stored in UserDefaults (language, FFM mode, timing delays). API key in shared Keychain (`com.localSTT.app`).

### Environment Variables

- `OPENAI_API_KEY`: Required for OpenAI provider (from .env or shell)
- `GROQ_API_KEY`: Required for Groq provider (get from https://console.groq.com)
- `GEMINI_API_KEY`: Required for Gemini provider (get from https://aistudio.google.com)

## macOS App Notes

- **Build system:** xcodegen → Xcode project. Always run `xcodegen generate` before building.
- **Hardened Runtime:** DISABLED (`ENABLE_HARDENED_RUNTIME: NO`) — required for CGEvent.post()
- **Code signing:** `CODE_SIGN_IDENTITY: "Apple Development"` (not ad-hoc) for stable TCC hash
- **FFM excluded apps:** Self-excluded to prevent focus trap in raise_on_hover mode. Finder allowed via `kCGWindowLayer` desktop filter.
- **Keyboard shortcuts:** `/` (search), `Esc` (close/clear), `A/E/F/C/J` (language), `V` (vocab), `R` (replace). Only active when no text field focused.
- **Bulk export/import:** Settings > Data section. JSON format with `vocabulary` and `replacements` arrays.
- **Logging:** `log stream --predicate 'subsystem == "com.localSTT.mac"' --level debug`

## Usage

**Web:** Run `./start.sh` to start both server and global hotkey client. Opens web UI automatically. Global hotkey requires macOS Accessibility permissions for your terminal app.

**macOS App:** Install to /Applications and launch. Grant Accessibility + Input Monitoring permissions in System Settings. Hold Left Control to record.

**iOS App:** Build and install via Xcode. Add Groq API key in settings. Hold the record button to transcribe.
