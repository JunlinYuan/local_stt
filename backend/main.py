"""FastAPI server for local speech-to-text."""

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import settings
from stt_engine import get_engine


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model on startup."""
    engine = get_engine()
    engine.load_model()
    # Log current settings
    print(f"Settings: Language={settings.get_language_display()}, Keybinding={settings.get_keybinding_display()}", flush=True)
    yield


app = FastAPI(title="Local STT", lifespan=lifespan)

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


class SettingsResponse(BaseModel):
    language: str
    language_display: str
    keybinding: str
    keybinding_display: str


@app.get("/api/settings")
async def get_settings() -> SettingsResponse:
    """Get all settings."""
    return SettingsResponse(
        language=settings.get_setting("language"),
        language_display=settings.get_language_display(),
        keybinding=settings.get_keybinding(),
        keybinding_display=settings.get_keybinding_display(),
    )


@app.post("/api/settings/language")
async def update_language(language: str = Form("")):
    """Update language setting."""
    settings.set_language(language)
    return await get_settings()


@app.post("/api/settings/keybinding")
async def update_keybinding(keybinding: str = Form("ctrl")):
    """Update keybinding setting."""
    settings.set_keybinding(keybinding)
    return await get_settings()


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
    lang_display = settings.get_language_display()

    print(f"→ [HTTP] Transcribing with language={lang_display}...", flush=True)

    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(
        None,
        lambda: engine.transcribe(audio_data, language=lang),
    )

    detected = result.get("language", "?").upper()
    proc_time = result.get("processing_time", 0)
    text_preview = result.get("text", "")[:50]
    print(f"← [HTTP] Done in {proc_time:.2f}s [Detected: {detected}] \"{text_preview}...\"", flush=True)

    return result


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time status updates."""
    await websocket.accept()
    engine = get_engine()

    print("✓ [WS] Web UI connected", flush=True)

    try:
        while True:
            # Receive audio data as bytes
            data = await websocket.receive_bytes()

            # Use current server settings
            lang = settings.get_language()
            lang_display = settings.get_language_display()

            print(f"→ [WS] Transcribing with language={lang_display}...", flush=True)

            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda d=data, lg=lang: engine.transcribe(d, language=lg),
            )

            detected = result.get("language", "?").upper()
            proc_time = result.get("processing_time", 0)
            print(f"← [WS] Done in {proc_time:.2f}s [Detected: {detected}]", flush=True)

            await websocket.send_json(result)

    except WebSocketDisconnect:
        print("✗ [WS] Web UI disconnected", flush=True)
    except Exception as e:
        print(f"[WS] Error: {e}", flush=True)
        await websocket.close()


# =============================================================================
# Vocabulary API
# =============================================================================


@app.get("/api/vocabulary")
async def get_vocabulary():
    """Get current vocabulary list."""
    engine = get_engine()
    return {"vocabulary": engine.vocabulary}


@app.post("/api/vocabulary")
async def set_vocabulary(words: list[str]):
    """Set vocabulary list."""
    engine = get_engine()
    engine.set_vocabulary(words)
    return {"vocabulary": engine.vocabulary}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)
