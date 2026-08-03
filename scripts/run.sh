#!/bin/bash
# Build and launch NotchAI, with stderr still visible.
#
# Launch through LaunchServices (`open`), never by executing the binary
# directly. TCC attributes a privacy request to the *responsible* process, and
# for a directly-executed binary that is the shell you started it from — so the
# first speech request aborts the app with "Info.plist must contain
# NSSpeechRecognitionUsageDescription" even though the bundle has the key.
# `open` makes the app responsible for itself; `--stderr` keeps the logs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/NotchAI.app"
LOG="$ROOT/build/NotchAI.log"

"$ROOT/scripts/build.sh" "${CONFIG:-debug}" >/dev/null

pkill -f 'NotchAI.app/Contents/MacOS/NotchAI' 2>/dev/null || true
: > "$LOG"

if [ $# -gt 0 ]; then
    open -a "$APP" --stdout "$LOG" --stderr "$LOG" --args "$@"
else
    open -a "$APP" --stdout "$LOG" --stderr "$LOG"
fi

echo "NotchAI running — log: $LOG  (ctrl-C stops tailing, not the app)"
tail -f "$LOG"
