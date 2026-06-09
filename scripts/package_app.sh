#!/usr/bin/env bash
set -euo pipefail

swift build

APP_ROOT="${APP_ROOT:-dist/Miku Explains.app}"
CONTENTS="$APP_ROOT/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_ROOT"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/debug/MikuExplains" "$MACOS/MikuExplains"
cp "Resources/miku.png" "$RESOURCES/miku.png"
cp "Resources/miku_crop.png" "$RESOURCES/miku_crop.png"
cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp -R "Resources/WebUI" "$RESOURCES/WebUI"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MikuExplains</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikuexplains.app</string>
    <key>CFBundleName</key>
    <string>Miku Explains</string>
    <key>CFBundleDisplayName</key>
    <string>Miku Explains</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>NSCalendarsUsageDescription</key>
    <string>Miku Explains needs Calendar access only when you accept an AI-suggested calendar action.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Miku Explains needs Calendar access only when you accept an AI-suggested calendar action.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Miku Explains needs Reminders access only when you accept an AI-suggested reminder action.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Miku Explains needs Reminders access only when you accept an AI-suggested reminder action.</string>
</dict>
</plist>
PLIST

# Note: llama-server is downloaded at runtime into
# ~/Library/Application Support/MikuExplains/Models/llama-server
# on first local-model pull. No binary is bundled in the .app.

codesign --force --deep --sign - "$APP_ROOT"

echo "Packaged $APP_ROOT"
