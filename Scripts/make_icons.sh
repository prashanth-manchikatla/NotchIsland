#!/bin/bash
#
# Renders Hoverbird's app icon — the Midnight Glass hummingbird — into the macOS .icns file
# and the PNG the docs use.
#
#   Resources/Icon/AppIcon.svg   full-bleed square artwork: macOS 26 cuts app icons to its own
#                                squircle and adds the edge and shadow (an icon with transparent
#                                corners gets put on a grey plate instead)
#   docs/assets/icon.svg         the same icon as a rounded squircle, for the web
#
#   ./Scripts/make_icons.sh
#
# Writes:
#   Resources/AppIcon.icns     every size macOS needs (16 to 1024 px), from AppIcon.svg
#   docs/assets/icon.png       256 px rounded icon for the README and docs, from icon.svg
#
# Needs only the Command Line Tools (like the build): Scripts/render_svg.swift renders the SVG
# with macOS's own SVG support (transparent corners — Quick Look would paint them white),
# iconutil builds the .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/Resources/Icon/AppIcon.svg"
WEB_SVG="$ROOT/docs/assets/icon.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
swiftc -O ${SDK:+-sdk "$SDK"} "$ROOT/Scripts/render_svg.swift" -o "$WORK/render_svg" 2>/dev/null ||
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -O "$ROOT/Scripts/render_svg.swift" -o "$WORK/render_svg"

render() { # <pixels> <out.png> [svg]
  "$WORK/render_svg" "${3:-$SVG}" "$1" "$2"
}

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  render "$size" "$SET/icon_${size}x${size}.png"
  render "$((size * 2))" "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
render 256 "$ROOT/docs/assets/icon.png" "$WEB_SVG"
log "Resources/AppIcon.icns and docs/assets/icon.png"
