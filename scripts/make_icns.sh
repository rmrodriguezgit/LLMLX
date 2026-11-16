#!/usr/bin/env bash
# Renders assets/AppIcon-1024.png and builds assets/AppIcon.icns (all macOS sizes).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets
swift scripts/make_icon.swift assets/AppIcon-1024.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
sips -z 256 256 assets/AppIcon-1024.png --out assets/AppIcon-256.png >/dev/null
echo "assets/AppIcon.icns listo"
