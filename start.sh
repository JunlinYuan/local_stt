#!/bin/bash
# Start Local STT - Server + Global Hotkey Client
# Server runs in background, client runs in foreground

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$PROJECT_DIR/backend"

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

# Check if server is already running
if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
    echo "Server already running at http://127.0.0.1:8000"
else
    echo "Starting server in background..."
    uv run uvicorn main:app --host 127.0.0.1 --port 8000 > /tmp/local-stt-server.log 2>&1 &
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
        echo "Server failed to start. Check /tmp/local-stt-server.log"
        exit 1
    fi
fi

echo ""
echo "Server: http://127.0.0.1:8000 (open in browser for debug UI)"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Shutting down..."
    pkill -f "uvicorn main:app" 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM

# Start global hotkey client
uv run python hotkey_client.py
