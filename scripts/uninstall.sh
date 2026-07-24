#!/bin/bash
set -e

LABEL="com.secondscreen.host"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY_DST="$HOME/.local/bin/SecondScreenHost"

echo "=== SecondScreen Uninstall ==="
echo ""

# 1. Unload service
if launchctl list | grep -q "$LABEL" 2>/dev/null; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "[OK] Service unloaded"
else
    echo "[Info] Service was not loaded"
fi

# 2. Remove plist
if [ -f "$PLIST_DST" ]; then
    rm "$PLIST_DST"
    echo "[OK] Removed $PLIST_DST"
fi

# 3. Remove binary
if [ -f "$BINARY_DST" ]; then
    rm "$BINARY_DST"
    echo "[OK] Removed $BINARY_DST"
fi

echo ""
echo "=== Uninstall complete ==="
