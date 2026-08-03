#!/bin/bash
# Build NotchAI and assemble a runnable .app bundle.
#
# SwiftPM produces a bare executable; macOS needs a bundle for LSUIElement,
# window levels and (later) microphone/speech permission strings to apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/NotchAI.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchAI"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchAI"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The icon is drawn from code rather than checked in as a binary, so it stays
# editable and reviewable in the diff.
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/NotchAI.iconset" >/dev/null
iconutil -c icns "$ROOT/build/NotchAI.iconset" -o "$APP/Contents/Resources/NotchAI.icns"

# Ad-hoc signature. Fine for local runs; once we add the microphone (phase 4)
# this needs a stable identity or macOS will re-prompt for TCC on every build.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "built: $APP"
