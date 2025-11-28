"""FastAPI server for local speech-to-text."""

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import (
    FastAPI,
    File,
    Form,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import settings
import vocabulary
from stt_engine import get_engine


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model and vocabulary on startup."""
    engine = get_engine()

    # Initialize vocabulary with callback to update engine
    def on_vocab_change(words: list[str]):
        engine.set_vocabulary(words)

    vocab_manager = vocabulary.init_manager(on_change=on_vocab_change)
    engine.set_vocabulary(vocab_manager.words)  # Initial load
    vocab_manager.start_watcher()  # Auto-reload on file changes

    # Load model
    engine.load_model()

    # Log current settings
    current = settings.get_settings_response()
    print(
        f"Settings: Language={current['language_display']}, "
        f"Keybinding={current['keybinding_display']}, "
        f"Vocabulary={len(vocab_manager.words)} words",
        flush=True,
    )
    yield

    # Cleanup
    vocab_manager.stop_watcher()


app = FastAPI(title="Local STT", lifespan=lifespan)

# Lock to serialize transcription requests (MLX/Metal is not thread-safe)
_transcription_lock = asyncio.Lock()
# Connected WebSocket clients for broadcasting results
_ws_clients: set[WebSocket] = set()

# Serve frontend
FRONTEND_DIR = Path(__file__).parent.parent / "frontend"
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")


@app.get("/")
async def index():
    """Serve the main page."""
    return FileResponse(FRONTEND_DIR / "index.html")


# =============================================================================
# Settings API
# =============================================================================


@app.get("/api/settings")
async def get_settings() -> dict[str, Any]:
    """Get all settings with display values."""
    return settings.get_settings_response()


@app.get("/api/settings/schema")
async def get_settings_schema() -> dict[str, Any]:
    """Get settings schema for frontend (types, options, ranges)."""
    return settings.get_schema()


class SettingUpdate(BaseModel):
    """Request body for updating a single setting."""

    value: Any


@app.put("/api/settings/{key}")
async def update_setting(key: str, update: SettingUpdate) -> dict[str, Any]:
    """
    Update a single setting by key.
    Returns all settings with updated values.
    """
    try:
        settings.set_setting(key, update.value)
        return settings.get_settings_response()
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


# Legacy form-based endpoints (for backward compatibility with hotkey client)
@app.post("/api/settings/language")
async def update_language(language: str = Form("")):
    """Update language setting (legacy form endpoint)."""
    try:
        settings.set_setting("language", language)
        return settings.get_settings_response()
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/settings/keybinding")
async def update_keybinding(keybinding: str = Form("ctrl")):
    """Update keybinding setting (legacy form endpoint)."""
    try:
        settings.set_setting("keybinding", keybinding)
        return settings.get_settings_response()
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


# =============================================================================
# Status API (for CLI to broadcast state to web UI)
# =============================================================================


class StatusUpdate(BaseModel):
    """Status update from CLI client."""

    recording: bool


@app.post("/api/status")
async def update_status(status: StatusUpdate):
    """Broadcast recording status to connected web UI clients."""
    message = {"type": "status", "recording": status.recording}

    for ws in list(_ws_clients):
        try:
            await ws.send_json(message)
        except Exception:
            _ws_clients.discard(ws)

    return {"ok": True}


# =============================================================================
# Transcription API
# =============================================================================


@app.post("/api/transcribe")
async def transcribe_audio(file: UploadFile = File(...)):
    """HTTP endpoint for audio transcription (used by global hotkey client).

    Uses the server's language setting.
    """
    engine = get_engine()
    audio_data = await file.read()

    lang = settings.get_language()
    response = settings.get_settings_response()
    lang_display = response["language_display"]

    print(f"→ [HTTP] Transcribing with language={lang_display}...", flush=True)

    # Serialize access to MLX/Metal (not thread-safe)
    async with _transcription_lock:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            None,
            lambda: engine.transcribe(audio_data, language=lang),
        )

    detected = result.get("language", "?").upper()
    proc_time = result.get("processing_time", 0)
    text_preview = result.get("text", "")[:50]
    print(
        f'← [HTTP] Done in {proc_time:.2f}s [Detected: {detected}] "{text_preview}..."',
        flush=True,
    )

    # Broadcast result to all connected web UI clients
    if _ws_clients:
        for ws in list(_ws_clients):
            try:
                await ws.send_json(result)
            except Exception:
                _ws_clients.discard(ws)

    return result


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for observing transcription results (read-only).

    Web UI connects here to receive results broadcast from CLI transcriptions.
    """
    await websocket.accept()
    _ws_clients.add(websocket)

    print("✓ [WS] Web UI connected (observer mode)", flush=True)

    try:
        # Keep connection alive, wait for disconnect
        while True:
            # Just receive and ignore any messages (keeps connection alive)
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        _ws_clients.discard(websocket)
        print("✗ [WS] Web UI disconnected", flush=True)


# =============================================================================
# Vocabulary API
# =============================================================================


class VocabularyWord(BaseModel):
    """Request body for adding a single word."""

    word: str


@app.get("/api/vocabulary")
async def get_vocabulary():
    """Get current vocabulary list."""
    manager = vocabulary.get_manager()
    return {"vocabulary": manager.words, "file": str(vocabulary.VOCABULARY_FILE)}


@app.post("/api/vocabulary")
async def add_vocabulary_word(body: VocabularyWord):
    """Add a single word to vocabulary (appends to file)."""
    manager = vocabulary.get_manager()
    added = manager.add_word(body.word)
    return {"vocabulary": manager.words, "added": added, "word": body.word}


@app.delete("/api/vocabulary")
async def remove_vocabulary_word(body: VocabularyWord):
    """Remove a word from vocabulary."""
    manager = vocabulary.get_manager()
    removed = manager.remove_word(body.word)
    return {"vocabulary": manager.words, "removed": removed, "word": body.word}


@app.put("/api/vocabulary")
async def replace_vocabulary(words: list[str]):
    """Replace entire vocabulary list (for bulk operations)."""
    manager = vocabulary.get_manager()
    manager.set_words(words)
    return {"vocabulary": manager.words}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)
