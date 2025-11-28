#!/bin/bash
# Start the Local STT application

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$PROJECT_DIR/backend"

echo "=========================================="
echo "  Local STT - Starting..."
echo "=========================================="

cd "$BACKEND_DIR"

# Kill any existing server on port 8000
if lsof -ti:8000 > /dev/null 2>&1; then
    echo "Stopping existing server..."
    lsof -ti:8000 | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# Check if uv is available
if ! command -v uv &> /dev/null; then
    echo "Error: uv is not installed. Please install it first:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Sync dependencies
echo "Installing dependencies..."
uv sync

# Download model on first run (will be cached)
echo ""
echo "Starting server..."
echo "First run will download the model (~1.5GB for distil-large-v3)"
echo ""
echo "Opening: http://127.0.0.1:8000"
echo "Press Ctrl+C to stop"
echo ""

# Open browser after a short delay (allows server to start)
(sleep 2 && open "http://127.0.0.1:8000") &

# Run the server
uv run uvicorn main:app --host 127.0.0.1 --port 8000 --reload
