# AGENTS.md: Pier

the owner's replacement for the macOS Dock, the first app built on the Mac Tools design system (the design system; read its `project/README.md` before UI changes). It replaced Docky, which was too buggy: keep this small and solid.

## Stack

- Swift 6.2 tools, Swift 5 language mode, SwiftPM, macOS 26. AppKit windows hosting SwiftUI. Depends on `../Kit` (MacToolsKit: tokens, usage file, login item).
- `main.swift`: app start, and `SystemDock`, which hides the macOS Dock (auto-hide plus a 1000s delay) and restores the user's own values only on Quit Pier.
- `DockModel.swift`: groups file, running apps, memory and thermal stats, the Usage Rings reading.
- `Downloads.swift`: ~/Downloads, newest first, watched live.
- `WindowPreviews.swift`: ScreenCaptureKit thumbnails (Screen Recording) and raising one window (Accessibility).
- `Panels.swift`: the bar's panel and the GlassPanel popup.
- `DockController.swift`: hover card timing, Downloads toggle, placement.
- `DockView.swift`: all SwiftUI.

## Commands

```sh
swift build              # compile check
./build.sh               # build/Pier.app
./build.sh --install     # replace /Applications/Pier.app and relaunch: only when the owner asks
```

## Where data lives

- `~/Library/Application Support/Pier/groups.json`: app groups, hand-edited (right-click the bar › Edit Groups…). Reloaded on save.
- UserDefaults `savedSystemDock`: the macOS Dock settings from before Pier, put back by Quit Pier.
- Reads `~/Library/Application Support/UsageRings/usage.json` (written by Usage Rings).

## Rules

- Never kill or replace the Dock process beyond `killall Dock` to reload settings: Mission Control, ⌘Tab and Spaces live in it.
- The bundle id `com.example.pier` never changes.
- Colours, radii, spacing and motion come from MacToolsKit, never literals.
