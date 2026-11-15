#!/usr/bin/env bash
# Builds Pier into build/Pier.app, signed with the Apple Development identity (a stable signature
# keeps the Screen Recording and Accessibility grants across rebuilds). --install puts it in
# /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

# Optional, gitignored: BUNDLE_ID, SIGN_IDENTITY and PREVIOUS_BUNDLE_ID (settings are copied once from it), see config.example.env.
BUNDLE_ID=app.newitools.Pier
SIGN_IDENTITY=""
PREVIOUS_BUNDLE_ID=""
[ -f config.local.env ] && source ./config.local.env

echo "==> Building (release)…"
swift build -c release

APP="build/Pier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pier "$APP/Contents/MacOS/Pier"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
[ -z "$PREVIOUS_BUNDLE_ID" ] || /usr/libexec/PlistBuddy -c "Add :PierPreviousBundleID string $PREVIOUS_BUNDLE_ID" "$APP/Contents/Info.plist"
[ -f build/AppIcon.icns ] || swift ../Kit/tools/icon-tile.swift 8e9bc4 dock.rectangle build/AppIcon.icns   # the Dispatch-style tile
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY=${SIGN_IDENTITY:-}
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  echo "==> No Apple Development identity; ad-hoc signing (permissions must be re-granted after each build)"
  codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pier 2>/dev/null || true
  while pgrep -x Pier >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Pier.app
  cp -R "$APP" /Applications/Pier.app
  open /Applications/Pier.app
  echo "Installed and launched /Applications/Pier.app"
else
  echo "Built $APP"
fi
