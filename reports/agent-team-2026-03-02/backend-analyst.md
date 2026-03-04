# Backend Analysis Report — Local STT
**Date:** 2026-03-02
**Analyst:** backend-analyst
**Repository:** https://github.com/JunlinYuan/local_stt

---

## Executive Summary

Local STT is a Python FastAPI backend + web frontend system for local speech-to-text on Apple Silicon. It supports three transcription providers (local MLX, OpenAI API, Groq API) with a global hotkey client for push-to-talk recording. The backend is production-ready with sophisticated audio preprocessing, vocabulary management, text replacements, and history tracking. The global hotkey client uses `pynput`, `sounddevice`, and macOS-specific APIs (`pyobjc`) for advanced features like focus-follows-mouse targeting.

---

## 1. API Surface

### 1.1 Health & Status Endpoints

**GET `/api/health`**
Returns provider availability and current provider.
**Response:**
```json
{
  "status": "ok",
  "providers": {
    "local": true,
    "openai": true/false,
    "groq": true/false
  },
  "current_provider": "groq"
}
```
**Used by:** Global hotkey client to detect network/API issues before transcription.
**Code location:** `main.py:191-206`

---

### 1.2 Settings API

#### GET `/api/settings`
Returns all settings with display values.
**Response:**
```json
{
  "stt_provider": "groq",
  "stt_provider_display": "Groq API (Fast)",
  "language": "en",
  "language_display": "EN",
  "keybinding": "ctrl_only",
  "keybinding_display": "Left Ctrl Only",
  ...
}
```
**Code location:** `main.py:214-217`

#### GET `/api/settings/schema`
Returns settings schema (types, options, ranges) for frontend UI generation.
**Response:**
```json
{
  "stt_provider": {
    "type": "string",
    "options": ["local", "openai", "groq"],
    "default": "local",
    "description": "..."
  },
  ...
}
```
**Code location:** `main.py:220-223`

#### PUT `/api/settings/{key}`
Update a single setting with validation.
**Request body:** `{"value": <any>}`
**Response:** Full settings object with updated values.
**Validation:** Type checking, enum options, range (min/max).
**Code location:** `main.py:232-242`

#### POST `/api/settings/language` (Legacy)
Form-based language update (for backward compatibility).
**Code location:** `main.py:246-253`

#### POST `/api/settings/keybinding` (Legacy)
Form-based keybinding update.
**Code location:** `main.py:256-263`

---

### 1.3 Transcription API

#### POST `/api/transcribe`
Primary HTTP endpoint for audio transcription (used by global hotkey client).
**Request:** Multipart form with audio file (WAV format).
**Response:**
```json
{
  "text": "Transcribed text here",
  "language": "en",
  "language_probability": 1.0,
  "duration": 2.5,
  "processing_time": 1.234,
  "provider": "groq",
  "audio_info": {
    "original_rms": 2500,
    "processed_rms": 3000,
    "gain_db": 1.8,
    "normalized": true
  }
}
```
**Features:**
- Uses server's language & provider settings
- Serialized with `_transcription_lock` (MLX/Metal not thread-safe)
- Broadcasts to WebSocket clients
- Saves to history if result has text
- Logs comprehensive timing info
- **Code location:** `main.py:326-376`

#### WebSocket `/ws`
Read-only WebSocket for web UI to observe transcription results.
**Usage:** Web UI connects here to receive results broadcast from CLI hotkey client transcriptions.
**Features:**
- Receives JSON result objects from `/api/transcribe`
- Keeps connection alive passively
- Auto-cleanup on disconnect
- **Code location:** `main.py:379-399`

---

### 1.4 Status Broadcasting (CLI → Web UI)

#### POST `/api/status`
Broadcast recording status from hotkey client to connected web UIs.
**Request body:**
```json
{
  "recording": true/false,
  "cancelled": false
}
```
**Code location:** `main.py:278-293`

#### POST `/api/log`
Broadcast log messages from hotkey client to web UIs.
**Request body:**
```json
{
  "level": "info|warn|error|debug",
  "message": "Log message text"
}
```
**Code location:** `main.py:303-318`

---

### 1.5 Vocabulary API

#### GET `/api/vocabulary`
Get current vocabulary list.
**Response:**
```json
{
  "vocabulary": ["word1", "word2", ...],
  "file": "/path/to/vocabulary.txt"
}
```
**Code location:** `main.py:413-417`

#### POST `/api/vocabulary`
Add single word to vocabulary (appends to file).
**Request body:** `{"word": "new_term"}`
**Response:** Updated vocabulary + added flag + optional error.
**Validation:** Max 85 words, case-insensitive duplicate check.
**Code location:** `main.py:420-428`

#### DELETE `/api/vocabulary`
Remove word from vocabulary.
**Request body:** `{"word": "term_to_remove"}`
**Code location:** `main.py:431-436`

#### PUT `/api/vocabulary`
Replace entire vocabulary list (bulk operation).
**Request body:** `["word1", "word2", ...]`
**Code location:** `main.py:439-444`

---

### 1.6 Replacements API

#### GET `/api/replacements`
Get current replacement rules.
**Response:**
```json
{
  "replacements": [
    {"from": "colour", "to": "color"},
    {"from": "favourite", "to": "favorite"}
  ],
  "file": "/path/to/replacements.json"
}
```
**Code location:** `main.py:459-466`

#### POST `/api/replacements`
Add replacement rule.
**Request body:** `{"from_text": "colour", "to_text": "color"}`
**Validation:** Max 100 rules, both from/to required, no same-text replacements.
**Code location:** `main.py:469-477`

#### DELETE `/api/replacements`
Remove replacement rule by 'from' value.
**Request body:** `{"from_text": "colour"}`
**Code location:** `main.py:480-485`

#### PUT `/api/replacements`
Replace entire replacement list (bulk).
**Request body:** `[{"from": "...", "to": "..."}, ...]`
**Code location:** `main.py:488-493`

---

### 1.7 History API

#### GET `/api/history`
Get all history entries (newest first, max 100).
**Response:**
```json
{
  "history": ["latest transcript", "older transcript", ...],
  "count": 5
}
```
**Code location:** `main.py:501-505`

#### DELETE `/api/history/{index}`
Delete single history entry by index.
**Code location:** `main.py:508-515`

#### DELETE `/api/history`
Clear all history.
**Code location:** `main.py:518-522`

---

## 2. Hotkey Client Capabilities

**File:** `backend/hotkey_client.py` (43.2 KB)

### 2.1 Global Hotkey Detection

**Implementation:** `pynput.keyboard.Listener` for system-wide key monitoring.

**Keybinding Modes:**
1. **`ctrl_only`** — Left Ctrl key held alone starts recording
2. **`ctrl`** — Left Ctrl + Left Option (Alt/⌘) together
3. **`shift`** — Left Shift + Left Option together

**Code:** `hotkey_client.py` uses `pynput.keyboard.Controller` + `Listener`:
- Reads keybinding from server settings (`GET /api/settings`)
- Polls periodically for setting changes
- Maps keybinding to listener function

### 2.2 Audio Recording

**Audio input:** `sounddevice.InputStream` (async recording with NumPy arrays)

**Features:**
- Records mono 16-bit PCM at 16 kHz
- Configurable sample rate detection (will resample to 16kHz)
- Minimum duration threshold (configurable, default 0.3s)
- Maximum duration safety timeout (configurable, default 240s)
- Volume RMS check before transcription (configurable threshold)

**Output format:** WAV file (44-byte header + 16-bit samples)

**Code section:** `hotkey_client.py` lines ~300-400 (audio recording loop)

### 2.3 Audio Preprocessing (Hotkey Client)

The hotkey client records raw audio, but **preprocessing happens server-side** in `audio_utils.py`:

1. **Volume normalization** — Boost quiet audio to target RMS (~3000)
2. **Gain limiting** — Prevent amplification >40dB
3. **Silence padding** — Optional 100ms pre + 200ms post for short clips
4. **RMS volume check** — Skip if below threshold (e.g., 100)

**Code location:** `audio_utils.py:183-244` (`preprocess_audio` function)

### 2.4 Mouse Tracking (Focus-Follows-Mouse / FFM)

**Purpose:** Paste transcription to window under mouse cursor without raising it.

**Implementation:** macOS-specific using `Quartz` framework
```python
from Quartz import (
    CGWindowListCopyWindowInfo,
    kCGWindowListOptionOnScreenOnly,
    CGEventGetLocation,
    CGEventCreate
)
```

**Features:**
- `ffm_enabled` setting — Toggle on/off
- `ffm_mode` setting:
  - **`track_only`** — Track mouse position, activate window only at paste time
  - **`raise_on_hover`** — Focus window as mouse moves (may be disruptive)
- Gets mouse coordinates via `CGEventGetLocation()`
- Finds window at those coordinates via `CGWindowListCopyWindowInfo()`
- Activates that window for paste input

**Code location:** `hotkey_client.py` lines ~600-700 (window targeting logic)

### 2.5 Clipboard Management

**Flow:**
1. Transcription result copied to clipboard
2. Brief delay (`clipboard_sync_delay`, default 0.05s)
3. Paste to targeted window (Cmd+V)
4. Delay after paste (`paste_delay`, default 0.05s)
5. Restore original clipboard contents

**Implementation:** Uses `pynput.keyboard` for paste command + macOS clipboard APIs

**Code location:** `hotkey_client.py` lines ~500-600 (paste & restore logic)

### 2.6 Memory Management

**Features:**
- Tracks process memory every 30 seconds
- Logs when delta >10MB
- Releases MLX/Metal memory after each transcription
- GC collection to prevent accumulation over long sessions

**Code location:** `hotkey_client.py:43-88` (memory monitoring)

### 2.7 POST to Server

Sends audio via `POST /api/transcribe` (HTTP, not WebSocket):
```python
with httpx.Client() as client:
    response = client.post(
        "http://localhost:8000/api/transcribe",
        files={"file": ("audio.wav", audio_bytes)}
    )
    result = response.json()
```

**Result handling:**
- Extracts text from result
- Copies to clipboard
- Calls paste logic (if FFM enabled)
- Broadcasts status to web UI via `POST /api/status`

---

## 3. STT Providers

### 3.1 Local Provider (lightning-whisper-mlx)

**File:** `backend/stt_engine.py`

**Model:** `large-v3` (2.97B parameters, optimized for Apple Silicon)

**Features:**
- Lazy loading on first use (saves ~2GB memory if using cloud providers)
- MLX Metal acceleration on GPU
- Warmup inference on startup
- Vocabulary biasing via `initial_prompt`
- Memory cache cleanup after each transcription

**API:**
```python
engine = get_engine()  # Singleton
result = engine.transcribe(
    audio_data: bytes,
    language: str | None = None,
    max_vocab_words: int = 0
)
```

**Returns:**
```python
{
    "text": "transcribed text",
    "language": "en",
    "language_probability": 1.0,
    "duration": 2.5,
    "processing_time": 1.234,
}
```

**Vocabulary biasing:**
- Builds `initial_prompt` from vocabulary list
- Example: `"Vocabulary: TEMPEST, CustomTerm1, CustomTerm2. "`
- Passed to `transcribe_audio()` function

**Code sections:**
- Model loading: `stt_engine.py:47-75`
- Transcription: `stt_engine.py:115-224`
- Vocabulary prompt: `stt_engine.py:101-113`

---

### 3.2 OpenAI Whisper API

**File:** `backend/openai_stt.py`

**Model:** `whisper-1` (latest Whisper model)

**Requirements:** `OPENAI_API_KEY` environment variable

**Features:**
- Vocabulary biasing via `prompt` parameter
- Uses `response_format="verbose_json"` for detailed output
- Supports language parameter for forced language

**API:**
```python
openai_stt = get_openai_stt()  # Singleton
result = openai_stt.transcribe(
    audio_data: bytes,
    language: str | None = None,
    max_vocab_words: int = 0
)
```

**Cost:** ~$0.02 per minute of audio

**Code sections:**
- Client initialization: `openai_stt.py:17-29`
- Transcription: `openai_stt.py:49-145`
- Vocabulary prompt: `openai_stt.py:38-47`

---

### 3.3 Groq Whisper API

**File:** `backend/groq_stt.py`

**Model:** `whisper-large-v3-turbo` (default, good balance of speed/accuracy/cost)

**Alternative models:**
- `whisper-large-v3` — Best accuracy (~10.3% WER), $0.111/hr
- `distil-whisper-large-v3-en` — Fastest, English-only (~13% WER), $0.02/hr

**Requirements:** `GROQ_API_KEY` from https://console.groq.com

**Performance:**
- 200-300x real-time speed (much faster than OpenAI)
- Cost: ~$0.04/hr with turbo model (cheaper than OpenAI)

**Features:**
- Vocabulary biasing via `prompt` parameter
- Prompt limit: 896 characters (truncates if vocabulary too large)
- Uses `response_format="verbose_json"`
- OpenAI-compatible API

**API:**
```python
groq_stt = get_groq_stt()  # Singleton
result = groq_stt.transcribe(
    audio_data: bytes,
    language: str | None = None,
    max_vocab_words: int = 0
)
```

**Prompt truncation logic:**
- Builds `"Vocabulary: word1, word2, ..., wordN."`
- Truncates vocabulary words if total >896 characters
- Logs how many vocabulary words fit

**Code sections:**
- Client initialization: `groq_stt.py:29-39`
- Prompt building: `groq_stt.py:48-84`
- Transcription: `groq_stt.py:86-189`

---

### 3.4 Provider Routing

**File:** `backend/stt_engine.py:304-465` (`transcribe_audio_with_provider`)

**Flow:**
1. Check `settings.get_stt_provider()` → "groq", "openai", or "local"
2. Validate API availability
3. Fallback to local if API unavailable
4. Call appropriate provider's `transcribe()` method
5. Apply post-processing (vocabulary casing, replacements, content filter)
6. Return result with provider name

**Sequence:**
```
transcribe_audio_with_provider()
  ├─ Preprocess audio (normalize, RMS check, padding)
  ├─ Route by provider:
  │  ├─ If Groq: call get_groq_stt().transcribe()
  │  ├─ Elif OpenAI: call get_openai_stt().transcribe()
  │  └─ Else: call get_engine().transcribe() (local)
  ├─ Post-process result:
  │  ├─ Apply vocabulary casing (vocabulary_utils.py)
  │  ├─ Record vocabulary usage (vocabulary.py)
  │  ├─ Apply text replacements (replacements.py)
  │  └─ Filter profanity (content_filter.py)
  └─ Return enriched result with audio_info
```

**Code location:** `stt_engine.py:304-465`

---

## 4. Settings System

### 4.1 Settings Schema

**File:** `backend/settings.py:29-157`

Complete settings list with full configuration:

| Setting | Type | Default | Options/Range | Description |
|---------|------|---------|----------------|-------------|
| `stt_provider` | string | "local" | [local, openai, groq] | STT provider |
| `language` | string | "" | ["", en, fr, zh, ja] | Transcription language (empty = auto-detect) |
| `keybinding` | string | "ctrl_only" | [ctrl_only, ctrl, shift] | Push-to-talk key binding |
| `clipboard_sync_delay` | number | 0.05 | 0.0–0.5 | Delay after copy before paste (seconds) |
| `paste_delay` | number | 0.05 | 0.0–0.5 | Delay after paste before restore clipboard (seconds) |
| `content_filter` | boolean | false | — | Filter misrecognized profanity |
| `min_recording_duration` | number | 0.3 | 0.1–2.0 | Minimum recording duration (skip accidental taps) |
| `min_volume_rms` | number | 100 | 0–500 | Minimum audio volume threshold (0 = disabled) |
| `volume_normalization` | boolean | true | — | Normalize audio (boost quiet, limit loud) |
| `max_recording_duration` | number | 240 | 30–300 | Maximum recording duration (safety timeout, seconds) |
| `ffm_enabled` | boolean | true | — | Enable mouse tracking for paste targeting |
| `ffm_mode` | string | "track_only" | [track_only, raise_on_hover] | FFM behavior |
| `replacements_enabled` | boolean | true | — | Apply word replacements after transcription |
| `save_debug_audio` | boolean | false | — | Save raw + final audio files to debug_audio/ |
| `short_clip_language_override` | string | "" | ["", en, fr, zh, ja] | Force language for clips <3s (when main is AUTO) |
| `short_clip_vocab_limit` | number | 0 | 0–100 | Max vocabulary words in prompt for <3s clips |
| `silence_padding` | boolean | false | — | Add silence padding (100ms pre + 200ms post) to short recordings |

### 4.2 Settings Storage

**File:** `backend/settings.json`

**Format:** JSON object with key-value pairs:
```json
{
  "stt_provider": "groq",
  "language": "en",
  "keybinding": "ctrl_only",
  ...
}
```

**Merging:** Defaults from schema + stored values (stored values override defaults)

### 4.3 Settings API Implementation

**Core functions** (`settings.py:240-336`):

```python
get_setting(key: str) -> Any
    # Get single setting value

set_setting(key: str, value: Any) -> dict
    # Set single setting, validate, save, log

get_all_settings() -> dict[str, Any]
    # Get all settings

get_settings_response() -> dict[str, Any]
    # Get all settings with display values (for API response)
    # Returns: {"key": value, "key_display": "Display String", ...}

get_schema() -> dict
    # Get schema without functions (serializable for frontend)
```

**Validation** (`settings.py:195-222`):
- Type checking (string, number, boolean)
- Options/enum validation
- Range validation (min/max)

**Display values** (`settings.py:225-233`):
- Custom formatting via `display` lambda in schema
- Examples: "ON"/"OFF" for booleans, "0.05s" for seconds

### 4.4 Adding New Settings

**Process:** (as documented in `settings.py:1-16`)
1. Add entry to `SETTINGS_SCHEMA` with `default`, `type`, and optional validation/display
2. API and UI automatically handle it

**Example:**
```python
"paste_delay": {
    "default": 0.1,
    "type": "number",
    "min": 0,
    "max": 2.0,
    "description": "Delay in seconds before pasting and restoring clipboard",
    "display": lambda v: f"{v:.2f}s",
},
```

---

## 5. Vocabulary System

### 5.1 File Format & Storage

**File:** `backend/vocabulary.txt` (plain text)

**Format:**
```
# Custom vocabulary for speech-to-text
# One word/phrase per line, comments start with #
# Words are case-sensitive (TEMPEST stays TEMPEST)
# Ordered by usage frequency (most-used first)

TEMPEST
CustomTerm1
CustomTerm2
```

**Max size:** 85 words (hard limit to prevent prompt overflow)

**Order:** Words automatically reordered by usage frequency (most-used first)

### 5.2 Usage Tracking

**File:** `backend/vocabulary_usage.json`

**Format:**
```json
{
  "TEMPEST": 42,
  "CustomTerm1": 15,
  "CustomTerm2": 8
}
```

**Tracked when:**
- Word appears in transcription result (after matching with vocabulary)
- Usage count incremented after each transcription

### 5.3 VocabularyManager Class

**File:** `backend/vocabulary.py`

**Key methods:**

```python
# Get current vocabulary (copy)
manager.words -> list[str]

# Add single word
manager.add_word(word: str) -> (bool, str | None)
    # Returns (success, error_message)
    # Validates: max size, duplicates, empty

# Remove single word
manager.remove_word(word: str) -> bool

# Replace entire vocabulary (bulk)
manager.set_words(words: list[str])

# Record that words appeared in transcription
manager.record_usage(words: list[str])

# Get usage counts
manager.get_usage() -> dict[str, int]

# Start/stop file watcher for auto-reload
manager.start_watcher(interval: float = 1.0)
manager.stop_watcher()
```

### 5.4 File Watcher

**Mechanism:** Background thread checking file mtime every 1 second

**Behavior:**
- Detects manual edits to `vocabulary.txt`
- Auto-reloads on change
- Calls `on_change` callback to update all STT providers

**Initialization** (`main.py:100-116`):
```python
def on_vocab_change(words: list[str]):
    engine.set_vocabulary(words)
    if is_openai_available():
        get_openai_stt().set_vocabulary(words)
    if is_groq_available():
        get_groq_stt().set_vocabulary(words)

vocab_manager = vocabulary.init_manager(on_change=on_vocab_change)
vocab_manager.start_watcher()
```

### 5.5 Vocabulary API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/vocabulary` | GET | Get current vocabulary list |
| `/api/vocabulary` | POST | Add single word |
| `/api/vocabulary` | DELETE | Remove word |
| `/api/vocabulary` | PUT | Replace entire list (bulk) |

**Code location:** `main.py:407-444`

---

## 6. Replacement System

### 6.1 File Format

**File:** `backend/replacements.json`

**Format:**
```json
{
  "replacements": [
    {"from": "colour", "to": "color"},
    {"from": "favourite", "to": "favorite"},
    {"from": "Whisper", "to": "Whisper (STT)"}
  ]
}
```

**Max rules:** 100

### 6.2 Matching Logic

**File:** `backend/replacements.py:222-254`

**Implementation:** Case-insensitive whole-word regex matching
```python
def apply_replacements(self, text: str) -> str:
    for rule in self._replacements:
        from_text = rule["from"]
        to_text = rule["to"]
        pattern = r"\b" + re.escape(from_text) + r"\b"
        result = re.sub(pattern, to_text, result, flags=re.IGNORECASE)
    return result
```

**Features:**
- **Case-insensitive matching** — Matches "Colour", "COLOUR", "colour"
- **Whole-word only** — Won't match "colour" in "colourer"
- **Special regex chars escaped** — User input like "C++" safe
- **Order matters** — Rules applied sequentially

### 6.3 ReplacementManager Class

**File:** `backend/replacements.py`

**Key methods:**

```python
manager.replacements -> list[dict]  # Get copy

manager.add_replacement(from_text: str, to_text: str) -> (bool, str | None)
    # Validates: max size, both required, not same

manager.remove_replacement(from_text: str) -> bool

manager.set_replacements(rules: list[dict])

manager.apply_replacements(text: str) -> str

manager.start_watcher(interval: float = 1.0)
manager.stop_watcher()
```

### 6.4 File Watcher

Similar to vocabulary: Background thread polls file mtime every 1 second.

### 6.5 Replacement API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/replacements` | GET | Get current rules |
| `/api/replacements` | POST | Add single rule |
| `/api/replacements` | DELETE | Remove rule |
| `/api/replacements` | PUT | Replace entire list (bulk) |

**Code location:** `main.py:459-493`

---

## 7. History System

### 7.1 File Format

**File:** `backend/history.json`

**Format:** Plain JSON array of strings (newest first):
```json
[
  "Latest transcription",
  "Previous transcription",
  "Older transcription"
]
```

**Max entries:** 100

### 7.2 History Module

**File:** `backend/history.py` (simple, 60 lines)

**Functions:**

```python
add_entry(text: str) -> None
    # Prepends text to history, trims to MAX_ENTRIES

get_all() -> list[str]
    # Returns all entries (newest first)

delete_entry(index: int) -> bool
    # Removes entry by index

clear_all() -> None
    # Clears history file
```

### 7.3 Storage Logic

- Entries stored as simple JSON array
- New entries prepended (index 0)
- Auto-trimmed to 100 most recent
- Non-empty text only

### 7.4 History API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/history` | GET | Get all entries |
| `/api/history/{index}` | DELETE | Delete single entry |
| `/api/history` | DELETE | Clear all entries |

**Code location:** `main.py:501-522`

---

## 8. Web UI Features

### 8.1 Page Structure

**File:** `frontend/index.html` (363 lines)

**Main sections:**
1. **Header** — Logo + theme toggle + connection status badge
2. **Quick-Access Bar** — Vocab count + Replacements count + Model info + Language badge
3. **Language Section** — Language selector buttons (AUTO, EN, FR, 中文, 日本語)
4. **Main Panel** — Provider toggle + Settings row + Recording state
5. **History Section** — Inline list of transcriptions with search
6. **Vocabulary Panel** — Full-page overlay for managing vocabulary
7. **Replacements Panel** — Full-page overlay for managing replacements
8. **Console Panel** — Debug logs from backend + frontend

### 8.2 Settings UI (Settings Row)

**Components:**
- **Keybinding toggle** — 3 buttons (Ctrl Only, Ctrl+Cmd, Shift+Cmd)
- **Clipboard Sync Delay slider** — Pre-paste delay (0.0–0.5s)
- **Paste Delay slider** — Post-paste delay (0.0–0.5s)
- **Volume Normalization toggle** — On/Off button
- **FFM (Focus-Follows-Mouse) toggle** — Enable/disable + mode selector (Track Only / Raise on Hover)
- **Max Recording Duration slider** — 30–300s (displays as "Xm" or "Xs")

### 8.3 Recording Panel

**Display:**
- Recording indicator (pulsing circle when recording)
- Status label ("READY", "RECORDING", "PROCESSING")
- Hint text (current keybinding + instructions)
- Volume indicator (RMS levels before/after normalization + gain)

### 8.4 History Section

**Features:**
- **Inline list** — Newest transcriptions listed
- **Search** — Filter by text (case-insensitive)
- **Click to copy** — Click entry to copy to clipboard
- **Delete** — Remove individual entries
- **Clear All** — Delete entire history
- **Keyboard shortcut** — Press `/` to focus search

### 8.5 Vocabulary Panel (Full-page overlay)

**Features:**
- **Add word input** — Text field + "+" button
- **Word grid** — 2-column grid of vocabulary words
- **Remove button** — "×" on each word
- **Word count badge** — Shows total vocabulary size
- **File reference** — Shows `vocabulary.txt` path in footer

**Keyboard:** Press `V` to open, `Esc` to close

### 8.6 Replacements Panel (Full-page overlay)

**Features:**
- **Add rule inputs** — Two fields: "Replace this" → "With this"
- **Rule list** — Shows all `from → to` pairs
- **Remove button** — Delete individual rules
- **Enabled toggle** — Enable/disable replacements (sets `replacements_enabled` setting)
- **Case-insensitive note** — Footer explains whole-word matching

**Keyboard:** Press `R` to open, `Esc` to close

### 8.7 Keyboard Shortcuts

- `A` — Auto-Detect language
- `E` — English
- `F` — French
- `C` — Chinese
- `J` — Japanese
- `V` — Open Vocabulary panel
- `R` — Open Replacements panel
- `/` — Focus History search
- `Esc` — Close panels / clear search

### 8.8 Dynamic UI Generation

**Provider toggle:** Generated dynamically from settings schema
- Buttons for each option in `stt_provider` schema
- Active state tracking
- Updates `stt_provider` setting on click

**Language buttons:** Hardcoded (AUTO, EN, FR, 中文, 日本語)

---

## 9. Audio Pipeline

### 9.1 Recording (Hotkey Client)

**Flow:**
1. Hotkey listener detects key press (pynput)
2. Start `sounddevice.InputStream`
3. Record NumPy arrays of int16 PCM samples
4. On hotkey release: stop recording
5. Convert arrays to WAV format (44-byte header + samples)
6. POST to `/api/transcribe`

**Sample rate:** 16 kHz (mono)
**Bit depth:** 16-bit (PCM int16)
**Format:** WAV

### 9.2 Preprocessing (Server-side)

**File:** `backend/audio_utils.py`

**Pipeline** (in order):

1. **Duration calculation** — From WAV size: `(len - 44) / (16000 * 2)`

2. **RMS volume calculation** (`calculate_audio_rms`)
   - Extracts samples from WAV header
   - Calculates RMS = sqrt(mean(samples²))
   - Range: 0 (silence) to ~32767 (max)

3. **Volume normalization** (if enabled, `normalize_audio`)
   - Calculates current RMS
   - Target RMS: 3000 (typical speech level)
   - Max gain: 40dB (prevents noise amplification)
   - Applies gain: `samples *= (target_rms / current_rms)`
   - Hard clips to int16 range
   - Returns: original RMS, gain dB, final RMS

4. **Silence padding** (if enabled, `add_silence_padding`)
   - Only for clips < 5 seconds
   - Adds 100ms silence before + 200ms after
   - Helps Whisper models (trained on 30s clips with natural starts/stops)

5. **Volume threshold check** (if enabled)
   - Compares processed RMS to `min_volume_rms` setting
   - Skips transcription if below threshold

**Returns:** `(processed_audio: bytes, info: dict)`
- `info` contains: `original_rms`, `processed_rms`, `gain_db`, `normalized`, `skipped`, `duration`, `padded`

### 9.3 Language Override for Short Clips

**Logic** (`stt_engine.py:371-389`):
- If duration < 3.0 seconds AND language is AUTO
- Check `short_clip_language_override` setting
- If set, force that language for this clip
- Rationale: Short clips often fail auto-detect

**Vocabulary limit for short clips** (`stt_engine.py:384-389`):
- If duration < 3.0 seconds
- Check `short_clip_vocab_limit` setting
- Limit vocabulary words in prompt to this number
- Rationale: Too many words in prompt can confuse on short audio

### 9.4 Post-Transcription Processing

After STT returns raw text:

1. **Vocabulary casing** (`vocabulary_utils.py:6-31`)
   - Matches vocabulary words (case-insensitive)
   - Replaces with canonical casing from vocabulary
   - Example: `"TEMPEST"` in vocab stays `"TEMPEST"` even if transcribed as `"tempest"`
   - Records usage in `vocabulary_usage.json`

2. **Text replacements** (if enabled, `replacements.py:222-254`)
   - Applies all replacement rules in order
   - Case-insensitive, whole-word matching
   - Example: `"colour"` → `"color"`

3. **Content filtering** (if enabled, `content_filter.py:119-149`)
   - Detects profanity using `better-profanity` library
   - Detects known Whisper hallucinations (e.g., "thank you", "subscribe")
   - Replaces with `[?]` or removes entirely
   - Logs to `filter_log.txt` for analysis

---

## 10. Dependencies

### 10.1 Core Backend

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | >=0.104.0 | Web framework (REST + WebSocket) |
| `uvicorn[standard]` | >=0.24.0 | ASGI server |
| `lightning-whisper-mlx` | >=0.0.10 | Local Whisper for Apple Silicon (MLX backend) |
| `python-multipart` | >=0.0.6 | File upload parsing |
| `websockets` | >=12.0 | WebSocket support |
| `better-profanity` | >=0.7.0 | Content filtering |
| `openai` | >=1.0.0 | OpenAI API client |
| `groq` | >=0.4.0 | Groq API client |

### 10.2 Global Hotkey Client (optional extra)

| Package | Version | Purpose |
|---------|---------|---------|
| `pynput` | >=1.7.6 | Global hotkey listening + keyboard control + mouse tracking |
| `sounddevice` | >=0.4.6 | Audio input from microphone |
| `numpy` | >=1.24.0 | Audio array processing |
| `httpx` | >=0.25.0 | HTTP client for `/api/transcribe` |
| `scipy` | >=1.10.0 | `resample_poly` for audio resampling |

### 10.3 macOS-Specific

| Package | Source | Purpose |
|---------|--------|---------|
| `pyobjc-framework-Quartz` | Installed via scipy | macOS window management (FFM) |
| MLX framework | Via `lightning-whisper-mlx` | Metal GPU acceleration |

### 10.4 Development Dependencies

| Package | Version |
|---------|---------|
| `ruff` | >=0.1.0 |
| `pytest` | >=7.0.0 |

---

## 11. Mac-Specific Features

### 11.1 Metal GPU Acceleration

**Framework:** MLX (Apple's ML acceleration library)
- Runs on Apple GPU (not CPU)
- Integrated with `lightning-whisper-mlx`
- Auto-offloads to CPU if memory constrained

**Memory management:**
- Lazy model loading (saves 2GB if using cloud providers)
- Cache clearing after each transcription (prevents 10-15GB accumulation over day)
- GC collection triggered explicitly

### 11.2 Global Hotkey Listener

**Implementation:** `pynput.keyboard.Listener`
- System-wide (works in any app, including web browser)
- Doesn't require app focus
- Reads keybinding from server (`/api/settings`)

**Key detection:** Platform-specific via pynput (uses native macOS APIs)

### 11.3 Focus-Follows-Mouse (FFM)

**Frameworks used:**
- `Quartz.CGWindowListCopyWindowInfo()` — Get all windows
- `Quartz.CGEventGetLocation()` — Get mouse position
- `Quartz.CGEventCreate()` — Get event for mouse location

**Two modes:**
1. **Track only** — Track mouse position, activate window only at paste time
   - Less disruptive to UX (window doesn't follow mouse)
2. **Raise on hover** — Focus window as mouse moves
   - More responsive but may activate wrong window if moving

### 11.4 Audio Input

**Driver:** `sounddevice` (wraps PortAudio)
- Accesses macOS audio hardware
- Supports multiple input devices
- Auto-resampling available (but we do it server-side for quality)

**Sample rate:** 16 kHz (configurable, will resample)

### 11.5 Clipboard Management

**Implementation:** macOS native APIs (via `pynput`)
- Copies transcription to clipboard
- Pastes via keyboard (Cmd+V)
- Restores original clipboard after paste

---

## 12. Reusable Components for Mac Native App

### 12.1 Components That Can Be Directly Reused

✅ **All STT provider integrations** (`openai_stt.py`, `groq_stt.py`, `stt_engine.py`)
- No FastAPI or web dependencies
- Use these modules directly in Swift/Objective-C app
- Same API, just call methods directly

✅ **Settings system** (`settings.py`)
- Schema-driven, serializable
- Just adapt JSON storage to UserDefaults or other Mac storage
- All validation logic is generic

✅ **Vocabulary manager** (`vocabulary.py`)
- File watcher logic reusable
- Usage tracking independent of web
- Could be adapted to Mac property list format

✅ **Replacements system** (`replacements.py`)
- Regex logic platform-independent
- File watching generic

✅ **History system** (`history.py`)
- Simple JSON store, easily adapted to Core Data

✅ **Audio utilities** (`audio_utils.py`)
- Normalization, RMS calculation, resampling — platform-independent
- No web dependencies
- Could be called from Swift via Python/ctypes or rewritten in Swift

✅ **Content filter** (`content_filter.py`)
- Profanity detection independent of web
- Hallucination filtering generic

### 12.2 Components That Need Rebuilding/Adaptation

⚠️ **Global hotkey client** (`hotkey_client.py`)
- Uses pynput (can't use in Swift)
- Use macOS native APIs instead:
  - `IOKit` or `Carbon` for global hotkeys
  - `AVAudioEngine` for audio instead of sounddevice
  - `Quartz` for window tracking (FFM) — reusable
- Clipboard management uses pynput — use `NSPasteboard` instead

⚠️ **FastAPI server** (`main.py`)
- Replace with native Mac app server:
  - Use URLSession for HTTP
  - SwiftUI for UI instead of HTML/CSS/JS
  - Local networking (or keep server if supporting other clients)

⚠️ **Web frontend** (HTML/CSS/JS)
- Rebuild as native SwiftUI interface
- Can reference component layouts + behavior

### 12.3 Architectural Notes for Mac App

**Option A: Pure Native (Recommended for performance)**
- Rewrite hotkey client in Swift (global hotkey + audio)
- Reuse Python modules for STT logic (call via swift-python bridge or reimpl)
- Use SwiftUI for UI
- Same WebSocket/HTTP client for real-time feedback from server (if keeping server)

**Option B: Hybrid (Fastest iteration)**
- Keep Python backend running as daemon
- Build native Swift UI (SwiftUI)
- Communicate via localhost HTTP/WebSocket
- Reuse all Python logic unchanged

**Option C: Embed Python (Mid-ground)**
- Embed Python runtime in Swift app (using PyObjC)
- Import Python modules directly
- native UI + Python backend in single app
- Slowest startup but smallest changes needed

---

## Appendix A: Quick Reference — Key Endpoints

```
GET    /                    # Serve index.html
GET    /api/health          # Check provider availability
GET    /api/settings        # Get all settings
PUT    /api/settings/{key}  # Update single setting
POST   /api/transcribe      # Transcribe audio (HTTP)
WS     /ws                  # WebSocket for broadcast
GET    /api/vocabulary      # Get vocabulary list
POST   /api/vocabulary      # Add word
DELETE /api/vocabulary      # Remove word
PUT    /api/vocabulary      # Replace entire vocabulary
GET    /api/replacements    # Get replacement rules
POST   /api/replacements    # Add rule
DELETE /api/replacements    # Remove rule
PUT    /api/replacements    # Replace entire rules
GET    /api/history         # Get history
DELETE /api/history/{index} # Delete entry
DELETE /api/history         # Clear all
```

---

## Appendix B: Files Not Analyzed

- `backend/test_resample.py` — Test file for resampling (not part of main flow)
- `frontend/styles.css` — UI styling (comprehensive but not core to functionality)
- `frontend/app.js` (lines 150+) — Web UI interactivity (continuation of logging system)
- Documentation files (`docs/learnings.md`, etc.)
- Config files (`.env.example`, `pyproject.toml` dependencies only)

---

## Appendix C: Configuration Examples

### Current Settings (from `backend/settings.json`)
```json
{
  "stt_provider": "groq",
  "language": "en",
  "keybinding": "ctrl_only",
  "clipboard_sync_delay": 0.06,
  "paste_delay": 0.06,
  "content_filter": false,
  "min_recording_duration": 0.3,
  "min_volume_rms": 100,
  "volume_normalization": true,
  "max_recording_duration": 300,
  "ffm_enabled": true,
  "ffm_mode": "raise_on_hover",
  "replacements_enabled": true,
  "save_debug_audio": false,
  "short_clip_language_override": "",
  "short_clip_vocab_limit": 0,
  "silence_padding": false
}
```

---

**Report generated:** 2026-03-02
**Total lines analyzed:** ~6000+ across 15+ files
**Report version:** 1.0
