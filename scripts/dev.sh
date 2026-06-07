#!/usr/bin/env bash
# dev.sh — kill, wipe companion state, reset accessibility, rebuild, repackage, relaunch
set -euo pipefail

APP="dist/Miku Explains.app"
BUNDLE_ID="app.miku-explains.prototype"
APP_SUPPORT="${MIKU_APP_SUPPORT:-$HOME/Library/Application Support/MikuExplains}"
LEGACY_APP_SUPPORT="${MIKU_LEGACY_APP_SUPPORT:-$HOME/Library/Application Support/Denebula}"
MODELS_DIR="$APP_SUPPORT/Models"
LLAMA_PID_FILE="$MODELS_DIR/llama-server.pid"

terminate_pid() {
  local pid="$1"

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  echo "  stopping PID $pid"
  kill "$pid" 2>/dev/null || true

  for _ in {1..15}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done

  kill -9 "$pid" 2>/dev/null || true
}

stop_managed_llama_server() {
  echo "→ Stopping managed llama.cpp server..."

  if [[ -f "$LLAMA_PID_FILE" ]]; then
    local pid
    pid="$(tr -dc '0-9' < "$LLAMA_PID_FILE" || true)"
    if [[ -n "$pid" ]]; then
      terminate_pid "$pid"
    fi
  fi

  if command -v pgrep >/dev/null 2>&1; then
    local pattern pid
    for pattern in \
      "$MODELS_DIR/llama-server-runtime/llama-server" \
      "$MODELS_DIR/llama-server" \
      "$MODELS_DIR/.*/model\\.gguf"
    do
      while IFS= read -r pid; do
        terminate_pid "$pid"
      done < <(pgrep -f "$pattern" 2>/dev/null || true)
    done
  fi
}

remove_path() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    echo "  removing $path"
    rm -rf "$path"
  fi
}

echo "→ Killing running instance..."
pkill -x "MikuExplains" 2>/dev/null || true
sleep 0.5

stop_managed_llama_server

echo "→ Removing companion app state..."
remove_path "$APP_SUPPORT"
remove_path "$LEGACY_APP_SUPPORT"

echo "→ Resetting saved defaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "→ Resetting Accessibility permission..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

echo "→ Building..."
swift build

echo "→ Packaging..."
bash scripts/package_app.sh

echo "→ Creating DMG..."
bash scripts/create_dmg.sh

echo "→ Launching $APP..."
open "$APP"

echo "✓ Done. Grant Accessibility permission when prompted."
