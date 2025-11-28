#!/bin/bash
# Start the Global Hotkey Client for Local STT
# Requires server to be running first (./scripts/start.sh)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="$PROJECT_DIR/backend"

echo "=========================================="
echo "  Local STT - Global Hotkey Client"
echo "=========================================="

cd "$BACKEND_DIR"

# Check if uv is available
if ! command -v uv &> /dev/null; then
    echo "Error: uv is not installed. Please install it first:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Install client dependencies
echo "Installing client dependencies..."
uv sync --extra client

echo ""
echo "NOTE: On macOS, you may need to grant Accessibility permissions"
echo "      Go to: System Preferences > Privacy & Security > Accessibility"
echo "      Add your terminal app (Terminal/iTerm2/etc)"
echo ""

# Run the client
uv run python hotkey_client.py
