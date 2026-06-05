#!/usr/bin/env bash
# dev.sh — kill, reset accessibility, rebuild, repackage, relaunch
set -e

APP="dist/Miku Explains.app"
BUNDLE_ID="app.miku-explains.prototype"

echo "→ Killing running instance..."
pkill -x "MikuExplains" 2>/dev/null || true
sleep 0.5

echo "→ Resetting Accessibility permission..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

echo "→ Building..."
swift build

echo "→ Packaging..."
bash scripts/package_app.sh

echo "→ Launching $APP..."
open "$APP"

echo "✓ Done. Grant Accessibility permission when prompted."
