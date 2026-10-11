#!/usr/bin/env bash
# Build and install ServitorAI.app: a menu-bar quick-chat (Warhammer Servitor theme)
# backed by a warm `pi --mode rpc` process.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ServitorAI.app"
EXEC="$APP/Contents/MacOS/ServitorAI"
PLIST_SRC="$HERE/com.johanneswitt.servitorai.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.johanneswitt.servitorai.plist"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/servitorai"
CONFIG="$CONFIG_DIR/config.json"

echo "==> Building release binary"
(cd "$HERE" && swift build -c release)

echo "==> Installing ServitorAI.app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/.build/out/Products/Release/QuickAI" "$EXEC"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$HERE/Assets/servitor-skull.png" "$APP/Contents/Resources/servitor-skull.png"

echo "==> Installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

if [[ ! -f "$CONFIG" ]]; then
  echo "==> Creating default config at $CONFIG"
  mkdir -p "$CONFIG_DIR"
  cp "$HERE/config.example.json" "$CONFIG"
fi

echo
echo "Done. To finish setup:"
echo "  1. Rotate any leaked API keys (recommended)."
echo "  2. Put your Ollama Cloud key in:"
echo "       $CONFIG"
echo "     under \"env\" -> \"OLLAMA_API_KEY\" (needed when auto-starting at login)."
echo "  3. Load the launch agent:"
echo "       launchctl load \"$PLIST_DST\""
echo
echo "   Or launch it now (Finder/Spotlight: 'ServitorAI', or):"
echo "       open \"$APP\""
echo
echo "   Hotkey: ⌘⇧A toggle · ⌘M model · ⌘⇧C copy · ⌘N new · ⌘[ ⌘] history"
