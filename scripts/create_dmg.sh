#!/usr/bin/env bash
set -euo pipefail

APP="dist/Miku Explains.app"

if [[ ! -d "$APP" ]]; then
  echo "Error: App bundle not found: $APP"
  exit 1
fi

OUT_DMG="dist/Install Miku Explains.dmg"

rm -f "$OUT_DMG"

create-dmg \
  --volname "Install Miku Explains" \
  --window-pos 200 120 \
  --window-size 800 450 \
  --icon-size 128 \
  --icon "Miku Explains.app" 200 220 \
  --hide-extension "Miku Explains.app" \
  --app-drop-link 600 220 \
  "$OUT_DMG" \
  "$APP"

echo "✓ Created: $OUT_DMG"