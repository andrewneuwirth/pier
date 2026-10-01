#!/bin/zsh
# Rasterises Resources/Icon.svg into Resources/UsageRings.icns.
#
# Quick Look is the only SVG renderer macOS ships, so it draws the master at
# 1024 and sips downsamples the rest of the iconset from that.
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/Icon.svg"
WORK="$(mktemp -d)"
SET="$WORK/UsageRings.iconset"
mkdir -p "$SET"

qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SVG").png"
[[ -f "$MASTER" ]] || { echo "Quick Look could not render $SVG" >&2; exit 1; }

for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
            256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$MASTER" --out "$SET/icon_${spec##*:}.png" >/dev/null
done

iconutil -c icns "$SET" -o "Resources/UsageRings.icns"
rm -rf "$WORK"
echo "wrote Resources/UsageRings.icns"
