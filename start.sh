#!/bin/bash
# Start Local STT - Server + Global Hotkey Client
# Both run in foreground with interleaved output

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$PROJECT_DIR/backend"
LOG_FILE="/tmp/local-stt-server.log"

echo "=========================================="
echo "  Local STT - Full Stack"
echo "=========================================="

cd "$BACKEND_DIR"

# Check if uv is available
if ! command -v uv &> /dev/null; then
    echo "Error: uv is not installed. Please install it first:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Install all dependencies
echo "Installing dependencies..."
uv sync --extra client

# Cleanup function
cleanup() {
    echo ""
    echo "Shutting down..."
    # Kill background processes
    kill $TAIL_PID 2>/dev/null || true
    pkill -f "uvicorn main:app" 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Check if server is already running
if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
    echo "Server already running at http://127.0.0.1:8000"
else
    echo "Starting server..."
    # Clear old log and start server with unbuffered Python output
    > "$LOG_FILE"
    PYTHONUNBUFFERED=1 uv run uvicorn main:app --host 127.0.0.1 --port 8000 >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!

    # Wait for server to be ready
    echo -n "Waiting for server"
    for i in {1..30}; do
        if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
            echo " ready!"
            break
        fi
        echo -n "."
        sleep 1
    done

    if ! curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
        echo " failed!"
        echo "Server log:"
        cat "$LOG_FILE"
        exit 1
    fi
fi

echo ""
echo "Server: http://127.0.0.1:8000"
echo ""
echo "────────────────────────────────────────────"
echo "  Logs from both server and client below"
echo "────────────────────────────────────────────"
echo ""

# Start tailing server log in background
tail -f "$LOG_FILE" &
TAIL_PID=$!

# Start global hotkey client (runs in foreground)
uv run python hotkey_client.py
