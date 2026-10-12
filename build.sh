#!/usr/bin/env bash
# Builds Tuck into /Applications/Tuck.app, signs it with the Apple Development
# identity (a stable signature keeps the Accessibility grant across rebuilds),
# and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)…"
swift build -c release

APP="/Applications/Tuck.app"
pkill -f "Tuck.app/Contents/MacOS/Tuck" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tuck "$APP/Contents/MacOS/Tuck"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  echo "==> No Apple Development identity; ad-hoc signing (Accessibility must be re-granted after each build)"
  codesign --force --sign - "$APP"
fi

sleep 0.3
open "$APP"
echo "Installed: $APP"
