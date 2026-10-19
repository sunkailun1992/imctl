#!/usr/bin/env bash
# Renders AppIcon.icns from draw-icon.swift (all macOS iconset sizes). Run when the drawing changes.
set -euo pipefail
cd "$(dirname "$0")"
SET="$(mktemp -d /tmp/imctl-icon.XXXXXX)/AppIcon.iconset"
mkdir -p "$SET"
for spec in 16:16 32:16@2x 32:32 64:32@2x 128:128 256:128@2x 256:256 512:256@2x 512:512 1024:512@2x; do
  px="${spec%%:*}"; name="${spec##*:}"
  swift draw-icon.swift "$px" "$SET/icon_${name}.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
swift draw-icon.swift 256 preview.png
echo "wrote $(pwd)/AppIcon.icns"
