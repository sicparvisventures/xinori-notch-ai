#!/bin/bash
# Build a release .app and zip it for a GitHub Release.
#
# Usage: ./scripts/release.sh v0.1.0
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   e.g. $0 v0.1.0" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/NotchAI.app"
DIST="$ROOT/dist"
ZIP="$DIST/NotchAI-$VERSION.zip"

"$ROOT/scripts/build.sh" release

# ── Notarisation (disabled) ───────────────────────────────────────────────
# The build is ad-hoc signed, so Gatekeeper quarantines it on first launch and
# users have to right-click → Open. To ship a double-clickable build you need a
# paid Apple Developer account; then set DEVELOPER_ID and NOTARY_PROFILE and
# drop the `false &&` below.
#
# if false && [ -n "${DEVELOPER_ID:-}" ]; then
#     codesign --force --deep --options runtime --timestamp \
#              --sign "$DEVELOPER_ID" "$APP"
#     ditto -c -k --keepParent "$APP" "$ZIP"
#     xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
#     xcrun stapler staple "$APP"
# fi
# ──────────────────────────────────────────────────────────────────────────

rm -rf "$DIST"
mkdir -p "$DIST"

# ditto, not zip: it preserves the bundle's symlinks and resource forks, which
# a plain `zip -r` mangles into an app macOS refuses to launch.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "built:  $APP"
echo "zipped: $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo
echo "next:"
echo "  gh release create $VERSION \"$ZIP\" --title \"NotchAI $VERSION\" --notes-file <notes>"
