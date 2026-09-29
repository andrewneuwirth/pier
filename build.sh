#!/bin/zsh
# Builds Usage Rings (app + desktop widget) and, with --install, puts it in
# /Applications. The widget is an app extension, which SwiftPM can't build,
# so this goes through the XcodeGen project (project.yml): built unsigned,
# then signed inside-out with the Apple Development identity and each
# target's entitlements (Xcode's automatic signing has no account here).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="<signing identity>"   # Apple Development: the developer
APP="build/dd/Build/Products/Release/UsageRings.app"

xcodegen generate --quiet
xcodebuild -project UsageRings.xcodeproj -scheme UsageRings -configuration Release \
    -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build -quiet

codesign --force --sign "$IDENTITY" --entitlements Widget/Widget.entitlements --timestamp=none \
    "$APP/Contents/PlugIns/UsageRingsWidget.appex"
codesign --force --sign "$IDENTITY" --entitlements Resources/UsageRings.entitlements --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
    killall UsageRings 2>/dev/null || true
    while pgrep -x UsageRings >/dev/null; do sleep 0.2; done
    rm -rf /Applications/UsageRings.app
    cp -R "$APP" /Applications/UsageRings.app
    open /Applications/UsageRings.app
    echo "installed and launched /Applications/UsageRings.app"
else
    echo "built $APP"
fi
