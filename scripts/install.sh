#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LABEL="com.secondscreen.host"
PLIST_SRC="$SCRIPT_DIR/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY_DST="$HOME/.local/bin/SecondScreenHost"
LOG_DIR="$HOME/Library/Logs/SecondScreen"

echo "=== SecondScreen Install ==="
echo ""

# 1. Build release binary
echo "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -10

BINARY="$PROJECT_DIR/.build/release/SecondScreenHost"
if [ ! -f "$BINARY" ]; then
    echo "[Error] Build failed"
    exit 1
fi
echo "[OK] Build complete"

# 2. Install binary
mkdir -p "$(dirname "$BINARY_DST")"
cp "$BINARY" "$BINARY_DST"
chmod +x "$BINARY_DST"
echo "[OK] Installed binary to $BINARY_DST"

# 2b. Sign with a stable identity so TCC grants (Screen Recording,
# Accessibility) survive rebuilds. Unsigned binaries lose them every install.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    if codesign --force --sign "Apple Development" --identifier "$LABEL" "$BINARY_DST" 2>/dev/null; then
        echo "[OK] Signed binary (permissions will persist across rebuilds)"
    else
        echo "[Warning] Codesign failed — permissions will reset on each rebuild"
    fi
else
    echo "[Warning] No signing identity — permissions will reset on each rebuild"
fi

# 3. Create log directory
mkdir -p "$LOG_DIR"
echo "[OK] Log directory: $LOG_DIR"

# 4. Unload existing service if present
if launchctl list | grep -q "$LABEL" 2>/dev/null; then
    echo "[Info] Unloading existing service..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# 5. Install plist (substitute __HOME__ with actual home directory)
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
echo "[OK] Installed plist to $PLIST_DST"

# 6. Load service
launchctl load "$PLIST_DST"
echo "[OK] Service loaded"

echo ""
echo "=== Installation complete ==="
echo "The service is now running in the background."
echo ""
echo "Useful commands:"
echo "  Check status:  launchctl list | grep secondscreen"
echo "  View logs:     tail -f $LOG_DIR/host.log"
echo "  Uninstall:     $SCRIPT_DIR/uninstall.sh"
