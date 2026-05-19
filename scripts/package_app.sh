#!/usr/bin/env bash
set -euo pipefail

swift build

APP_ROOT="${APP_ROOT:-dist/Denebula.app}"
CONTENTS="$APP_ROOT/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP_ROOT"
mkdir -p "$MACOS"

cp ".build/debug/Denebula" "$MACOS/Denebula"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Denebula</string>
    <key>CFBundleIdentifier</key>
    <string>app.denebula.prototype</string>
    <key>CFBundleName</key>
    <string>Denebula</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_ROOT"

echo "Packaged $APP_ROOT"
