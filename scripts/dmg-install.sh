#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.secondscreen.host"
PLIST_SRC="$SCRIPT_DIR/$LABEL.plist"
BINARY_SRC="$SCRIPT_DIR/SecondScreenHost"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY_DST="$HOME/.local/bin/SecondScreenHost"
LOG_DIR="$HOME/Library/Logs/SecondScreen"

echo "=== SecondScreen Install ==="
echo ""

# 1. Verify binary exists
if [ ! -f "$BINARY_SRC" ]; then
    echo "[Error] SecondScreenHost binary not found at $BINARY_SRC"
    exit 1
fi

if [ ! -f "$PLIST_SRC" ]; then
    echo "[Error] Plist not found at $PLIST_SRC"
    exit 1
fi

# 1b. Check for adb (required at runtime)
if ! command -v adb >/dev/null 2>&1 && [ ! -x "$HOME/Library/Android/sdk/platform-tools/adb" ] && [ ! -x /opt/homebrew/bin/adb ] && [ ! -x /usr/local/bin/adb ]; then
    echo "[Warning] adb not found. The service needs it to talk to the tablet."
    echo "          Install with: brew install android-platform-tools"
fi

# 2. Install binary
mkdir -p "$(dirname "$BINARY_DST")"
cp "$BINARY_SRC" "$BINARY_DST"
chmod +x "$BINARY_DST"
# Clear the quarantine flag the DMG download attaches — launchd refuses to
# start quarantined binaries signed without a Developer ID.
xattr -c "$BINARY_DST" 2>/dev/null || true
echo "[OK] Installed binary to $BINARY_DST"

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
echo "Required macOS permissions (grant when prompted):"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  System Settings → Privacy & Security → Screen Recording"
echo ""
echo "Useful commands:"
echo "  Check status:  launchctl list | grep secondscreen"
echo "  View logs:     tail -f $LOG_DIR/host.log"
echo "  Uninstall:     Run uninstall.sh from this folder"
