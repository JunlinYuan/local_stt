"""FastAPI server for local speech-to-text."""

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from stt_engine import get_engine


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load model on startup."""
    engine = get_engine()
    engine.load_model()
    yield


app = FastAPI(title="Local STT", lifespan=lifespan)

# Serve frontend
FRONTEND_DIR = Path(__file__).parent.parent / "frontend"
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")


@app.get("/")
async def index():
    """Serve the main page."""
    return FileResponse(FRONTEND_DIR / "index.html")


@app.post("/api/transcribe")
async def transcribe_audio(file: UploadFile = File(...)):
    """HTTP endpoint for audio transcription (used by global hotkey client)."""
    engine = get_engine()
    audio_data = await file.read()

    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(
        None,
        lambda: engine.transcribe(audio_data),
    )
    return result


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for audio streaming and transcription."""
    await websocket.accept()
    engine = get_engine()

    try:
        while True:
            # Receive audio data as bytes
            data = await websocket.receive_bytes()

            # Transcribe in a thread pool to not block
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: engine.transcribe(data),
            )

            # Send back the transcription
            await websocket.send_json(result)

    except WebSocketDisconnect:
        print("Client disconnected")
    except Exception as e:
        print(f"WebSocket error: {e}")
        await websocket.close()


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
