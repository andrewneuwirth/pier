# AGENTS.md: Usage Rings

A macOS 26 app plus WidgetKit widget showing how much of the Claude and ChatGPT allowance is used (short window = thick outer arc, weekly = thin inner arc) and when it resets.

## Stack

- SwiftUI + WidgetKit, Liquid Glass. Built through **XcodeGen** (`project.yml`) and `xcodebuild`, not SwiftPM: the widget is an app extension SwiftPM can't build. There is no `Package.swift`.
- Targets: `UsageRings` (app, `Sources/UsageRings` + `Shared`) and `UsageRingsWidget` (app extension, `Widget` + `Shared`). Bundle ids `com.example.UsageRings` and `.Widget`.
- `UsageRings.xcodeproj/` is generated and gitignored; edit `project.yml`, never the project file.

## Commands

```sh
./build.sh               # xcodegen generate + xcodebuild Release (unsigned), then codesign inside-out
./build.sh --install     # kill, replace /Applications/UsageRings.app, launch
./scripts/makeicon.sh    # re-render Resources/UsageRings.icns from Resources/Icon.svg
/Applications/UsageRings.app/Contents/MacOS/UsageRings --dump   # print what the rings would draw
```

- `build.sh` signs with a pinned Apple Development identity hash and each target's entitlements (`Widget/Widget.entitlements`, `Resources/UsageRings.entitlements`), because Xcode's automatic signing has no account here. Don't switch it to automatic signing.
- Only install when the owner asks.

## Data and credentials

- Claude: `api.anthropic.com/api/oauth/usage` with the token from the login keychain item `Claude Code-credentials`. ChatGPT: `chatgpt.com/backend-api/wham/usage` with `~/.codex/auth.json`.
- Tokens are read at request time and never written anywhere. Never log, cache or commit them.
- The app writes readings to `~/Library/Application Support/UsageRings/usage.json`; the sandboxed widget reads it via a read-only sandbox exception (an app group would need a provisioning profile). Shared model in `Shared/SharedUsage.swift`.
- Window position and menu toggles live in UserDefaults.

## Rules

- Don't use `claude -p` or launch Claude Code to read usage: rejected (costs money, no limits in output).
- Polls every 5 min, 30 in Low Power Mode, and stops entirely while the display sleeps. Keep refreshes cheap.
- Colour thresholds (amber past 50%, red past 80%) match the Claude Code status line; keep them in sync.
