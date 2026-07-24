#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DMG_NAME="Darpan"
STAGING_DIR="$PROJECT_DIR/.dmg-staging"
DMG_OUTPUT="$PROJECT_DIR/$DMG_NAME.dmg"

echo "=== Creating SecondScreen DMG ==="
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

# 2. Create staging directory
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/$DMG_NAME"
echo "[OK] Created staging directory"

# 3. Copy files
cp "$BINARY" "$STAGING_DIR/$DMG_NAME/SecondScreenHost"
chmod +x "$STAGING_DIR/$DMG_NAME/SecondScreenHost"
cp "$SCRIPT_DIR/com.secondscreen.host.plist" "$STAGING_DIR/$DMG_NAME/"
cp "$SCRIPT_DIR/dmg-install.sh" "$STAGING_DIR/$DMG_NAME/install.sh"
chmod +x "$STAGING_DIR/$DMG_NAME/install.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$STAGING_DIR/$DMG_NAME/uninstall.sh"
chmod +x "$STAGING_DIR/$DMG_NAME/uninstall.sh"
echo "[OK] Copied files"

# 4. Create README
cat > "$STAGING_DIR/$DMG_NAME/README.txt" << 'EOF'
Darpan - macOS Host Service
===========================

Use your Android tablet as a second display for your Mac.

INSTALLATION
------------
1. Open Terminal
2. Drag install.sh into Terminal and press Enter
   (or run: bash /Volumes/Darpan/install.sh)
3. Grant permissions when prompted:
   - System Settings → Privacy & Security → Accessibility
   - System Settings → Privacy & Security → Screen Recording

REQUIREMENTS
------------
- macOS 14 (Sonoma) or later
- Android SDK platform-tools (adb) installed
- Android tablet with the SecondScreen Receiver app

UNINSTALL
---------
1. Open Terminal
2. Run: bash ~/.local/bin/../uninstall.sh
   Or drag uninstall.sh into Terminal and press Enter

HOW IT WORKS
------------
The service runs in the background and:
- Creates a virtual display matching your tablet's resolution
- Streams the display via H.264 over USB (ADB reverse)
- Receives touch, scroll, and gesture input from the tablet

LOGS
----
View logs: tail -f ~/Library/Logs/SecondScreen/host.log
Check status: launchctl list | grep secondscreen
EOF
echo "[OK] Created README"

# 5. Remove old DMG if exists
rm -f "$DMG_OUTPUT"

# 6. Create DMG
echo "Creating DMG..."
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING_DIR/$DMG_NAME" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT" 2>&1 | tail -5
echo "[OK] Created $DMG_OUTPUT"

# 7. Cleanup
rm -rf "$STAGING_DIR"
echo "[OK] Cleaned up staging directory"

# 8. Show result
DMG_SIZE=$(du -h "$DMG_OUTPUT" | cut -f1)
echo ""
echo "=== DMG created ==="
echo "  File: $DMG_OUTPUT"
echo "  Size: $DMG_SIZE"
