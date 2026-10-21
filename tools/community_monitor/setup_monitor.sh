#!/bin/bash
# Setup script for ExpressiveOS Community Review & Monitor
# Installs Python dependencies (Playwright) and verifies configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== ExpressiveOS Community Monitor Setup ==="

# Check Python 3
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 --version)
    echo "• Found Python: $PY_VER"
else
    echo "ERROR: python3 is required." >&2
    exit 1
fi

# Setup Virtual Environment if requested or install playwright
VENV_DIR="$SCRIPT_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "• Creating Python virtual environment in $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

echo "• Installing dependencies in virtual environment..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install playwright

echo "• Installing Playwright browser binaries (Chromium)..."
"$VENV_DIR/bin/playwright" install chromium

echo "• Verifying Telegram bot token configuration..."
TOKEN_FILE="$HOME/.telegram_triage_bot_token"
if [ -n "${TELEGRAM_TRIAGE_BOT_TOKEN:-}" ]; then
    echo "  [OK] Found TELEGRAM_TRIAGE_BOT_TOKEN in environment."
elif [ -f "$TOKEN_FILE" ]; then
    echo "  [OK] Found token file at $TOKEN_FILE."
else
    echo "  [NOTE] Telegram Bot token not configured yet."
    echo "  To configure Telegram ingestion:"
    echo "    1. Create a bot with @BotFather on Telegram."
    echo "    2. Add the bot to your feedback group (@ExpressiveLauncherFeedback)."
    echo "    3. Run: echo 'YOUR_BOT_TOKEN' > ~/.telegram_triage_bot_token"
fi

echo "• Running test suite..."
"$VENV_DIR/bin/python" -m unittest discover -s "$SCRIPT_DIR/tests"

echo "=== Setup Complete! ==="
echo "You can now run:"
echo "  $VENV_DIR/bin/python $SCRIPT_DIR/run_daily_review.py --dry-run --mock-feed"
