#!/usr/bin/env bash
# Builds Pier into build/Pier.app, signed with the Apple Development identity (a stable signature
# keeps the Screen Recording and Accessibility grants across rebuilds). --install puts it in
# /Applications and relaunches it. --release ignores config.local.env and signs with Developer ID
# (hardened runtime + secure timestamp) for notarization: see ../Kit/tools/release-app.sh.
set -euo pipefail
cd "$(dirname "$0")"

# Optional, gitignored: BUNDLE_ID, SIGN_IDENTITY and PREVIOUS_BUNDLE_ID (settings are copied once from it), see config.example.env.
BUNDLE_ID=app.newitools.Pier
SIGN_IDENTITY=""
PREVIOUS_BUNDLE_ID=""
RELEASE=0; [[ "${1:-}" == "--release" ]] && RELEASE=1
# A public release never reads the local file: no previous id or personal settings in the shipped app.
[ "$RELEASE" = 0 ] && [ -f config.local.env ] && source ./config.local.env

echo "==> Building (release)…"
swift build -c release

APP="build/Pier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pier "$APP/Contents/MacOS/Pier"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
[ -z "$PREVIOUS_BUNDLE_ID" ] || /usr/libexec/PlistBuddy -c "Add :PierPreviousBundleID string $PREVIOUS_BUNDLE_ID" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # drawn once with Kit's tools/icon-tile.swift (8e9bc4, dock.rectangle)
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY=${SIGN_IDENTITY:-}
if [ "$RELEASE" = 1 ]; then
  [ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain" >&2; exit 1; }
  echo "==> Signing for release with $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "Built $APP (release)"; exit 0
fi
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
