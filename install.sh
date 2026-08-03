#!/bin/bash
# Xinori Notch AI — installer
#
#   curl -fsSL https://sicparvisventures.github.io/xinori-notch-ai/install.sh | bash
#
# Why this exists: the app is ad-hoc signed (no paid Apple Developer account),
# and macOS quarantines anything downloaded from a browser. Gatekeeper then
# refuses to open it, and since macOS 15 the old right-click → Open bypass no
# longer works for unsigned apps — you have to dig through System Settings.
#
# A file fetched with curl is never quarantined in the first place, so
# installing this way is simply the path that doesn't create the problem. The
# script still strips the attribute explicitly in case the zip came from a
# browser.
set -euo pipefail

REPO="sicparvisventures/xinori-notch-ai"
APP_NAME="NotchAI.app"
DEST="/Applications"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

bold "Xinori Notch AI"

# ── Preflight ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || fail "Dit werkt alleen op macOS."

major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 26 ]; then
    fail "macOS 26 of nieuwer is vereist (je hebt $(sw_vers -productVersion))."
fi

# ── Download ─────────────────────────────────────────────────────────────────
info "Nieuwste versie zoeken…"
asset_url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -1 | cut -d'"' -f4)"
[ -n "$asset_url" ] || fail "Kon geen release vinden. Check https://github.com/$REPO/releases"

version="$(basename "$(dirname "$asset_url")")"
info "Versie $version downloaden…"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$asset_url" -o "$tmp/app.zip" || fail "Download mislukt."

# ditto, not unzip: it round-trips the bundle's symlinks and metadata the way
# the release script packed them.
ditto -x -k "$tmp/app.zip" "$tmp/unpacked" || fail "Uitpakken mislukt."
[ -d "$tmp/unpacked/$APP_NAME" ] || fail "Het archief bevat geen $APP_NAME."

# ── Install ──────────────────────────────────────────────────────────────────
if pgrep -f "$DEST/$APP_NAME/Contents/MacOS/NotchAI" >/dev/null 2>&1; then
    info "Draaiende versie afsluiten…"
    pkill -f "$DEST/$APP_NAME/Contents/MacOS/NotchAI" || true
    sleep 1
fi

if [ -d "$DEST/$APP_NAME" ]; then
    info "Vorige versie vervangen…"
    rm -rf "$DEST/$APP_NAME" 2>/dev/null || sudo rm -rf "$DEST/$APP_NAME"
fi

mv "$tmp/unpacked/$APP_NAME" "$DEST/" 2>/dev/null || sudo mv "$tmp/unpacked/$APP_NAME" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

# ── Ollama ───────────────────────────────────────────────────────────────────
if ! [ -d "/Applications/Ollama.app" ] \
   && ! [ -x "/usr/local/bin/ollama" ] \
   && ! [ -x "/opt/homebrew/bin/ollama" ]; then
    printf '\n'
    info "Ollama is nog niet geïnstalleerd — dat draait het model lokaal."
    info "De app helpt je er bij de eerste start doorheen, of haal het nu:"
    info "  https://ollama.com/download"
fi

printf '\n'
bold "Geïnstalleerd in $DEST/$APP_NAME"
info "Starten: open -a NotchAI"
info "Daarna: klik op de notch bovenaan je scherm."
printf '\n'

open -a "$DEST/$APP_NAME" 2>/dev/null || true
