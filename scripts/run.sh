#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== SecondScreen Build & Run ==="
echo ""

# Check for adb
ADB=$(which adb 2>/dev/null || echo "$HOME/Library/Android/sdk/platform-tools/adb")
if [ ! -x "$ADB" ]; then
    echo "[Error] adb not found. Install Android SDK platform-tools."
    echo "        brew install android-platform-tools"
    echo "   or   Install via Android Studio"
    exit 1
fi
echo "[OK] adb: $ADB"

# Check device
if ! $ADB devices | grep -q "device$"; then
    echo "[Error] No Android device connected."
    echo "        1. Connect tablet via USB-C"
    echo "        2. Enable USB debugging in Developer Options"
    exit 1
fi
echo "[OK] Device connected"

# Build Mac host
echo ""
echo "Building Mac host..."
cd "$PROJECT_DIR"
swift build 2>&1 | tail -5

BINARY="$PROJECT_DIR/.build/debug/SecondScreenHost"
if [ ! -f "$BINARY" ]; then
    echo "[Error] Build failed"
    exit 1
fi
echo "[OK] Build complete"

# Run
echo ""
echo "Starting SecondScreen host..."
echo "Press Ctrl+C to stop"
echo ""
exec "$BINARY"
