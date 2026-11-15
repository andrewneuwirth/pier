# AGENTS.md: Pier

the owner's replacement for the macOS Dock, the first app built on the Mac Tools design system (the design system; read its `project/README.md` before UI changes). It replaced Docky, which was too buggy: keep this small and solid.

## Stack

- Swift 6.2 tools, Swift 5 language mode, SwiftPM, macOS 26. AppKit windows hosting SwiftUI. Depends on `../Kit` (MacToolsKit: tokens, usage file, login item).
- `main.swift`: app start, and `SystemDock`, which hides the macOS Dock (auto-hide plus a 1000s delay) and restores the user's own values only on Quit Pier.
- `DockModel.swift`: groups file, the shared Projects list, running apps, memory and thermal stats, the usage reading.
- `Usage/`: fetches the Claude and ChatGPT usage (moved from Usage Rings, history merged in) and writes `~/Library/Application Support/UsageRings/usage.json` through Kit's `UsageSnapshot.write`. Every 5 min, 30 in Low Power Mode, nothing while the display sleeps; per-service cooldowns (60 s, 5 min after a 429). Claude: `api.anthropic.com/api/oauth/usage` with the token from the login keychain item `Claude Code-credentials` (read through `/usr/bin/security` at request time). ChatGPT: `chatgpt.com/backend-api/wham/usage` with `~/.codex/auth.json`. Tokens are never written, logged or cached. Never use `claude -p` to read usage (costs money, no limits in output).
- `Downloads.swift`: ~/Downloads, newest first, watched live.
- `WindowPreviews.swift`: ScreenCaptureKit thumbnails (Screen Recording) and raising one window (Accessibility).
- `Panels.swift`: the bar's panel and the GlassPanel popup.
- `DockClearance.swift`: trims windows that open or resize under the bar (the auto-hidden Dock no longer reserves that strip).
- `DockController.swift`: hover card timing, Downloads toggle, placement.
- `AppSearch.swift`: Search's ranking for apps, settings and links (`SearchRank`) and for files (`FileRank`), pure Foundation, checked by `--self-check`.
- `Screenshots.swift`: Search's Screenshots tab: the newest captures from the `com.apple.screencapture location` folder (else the Desktop), watched only while the panel is open, cached Quick Look thumbnails, ⌘C copies the image. Also always watches `$TMPDIR/TemporaryItems/NSIRD_screencaptureui_*` (FSEvents): a capture dragged out of the floating preview is never saved by macOS, so ~10 s after its preview closes Pier copies it into the screenshot folder (never when a file of that name is already there). The distributed notification `com.example.pier.pasteScreenshot` puts the newest capture of the last 10 minutes on the clipboard and sends ⌘V (needs Accessibility); nothing that recent beeps.
- `FileSearch.swift`: files by name from the Spotlight index (`FileQuery`, cancellable, off the main thread) and Quick Look for the selected file.
- `AppSearchIndex.swift`: the index of apps and System Settings panes (built off the main thread, rebuilt when an Applications folder changes), scopes and grouped sections, launch counts in UserDefaults, the Spotlight-style panel's controller and keys, and the Option-Space and Command-Space hot keys (Command-Space only fires once Spotlight's own shortcut is turned off in System Settings; Pier reads that setting, never writes it).
- `DockView.swift`: all SwiftUI.

## Commands

```sh
swift build              # compile check
swift run Pier --self-check   # ranking checks, prints "self-check ok"; starts nothing
swift run Pier --ui-check DIR # opens the real search panel (no bar), drives it with keys sent to Pier only, saves two screenshots to DIR; takes the keyboard for ~5 s
./build.sh               # build/Pier.app
./build.sh --install     # replace /Applications/Pier.app and relaunch: only when the owner asks
```

## Where data lives

- `~/Library/Application Support/Pier/groups.json`: app groups, hand-edited (right-click the bar › Edit Groups…). Reloaded on save.
- UserDefaults `savedSystemDock`: the macOS Dock settings from before Pier, put back by Quit Pier.
- `~/Library/Application Support/Projects/projects.json`: the Projects list (title, url, path, start), shared with the Projects app through Kit's `ProjectLinks`; either app adding or editing a project updates it, and Pier watches its folder. Moved out of groups.json's `projectLinks` on first launch.
- `~/Library/Application Support/UsageRings/usage.json`: written by `Usage/` (the folder keeps Usage Rings' name so Kit's reader is unchanged).

## Rules

- Never kill or replace the Dock process beyond `killall Dock` to reload settings: Mission Control, ⌘Tab and Spaces live in it.
- The bundle id `com.example.pier` never changes.
- Colours, radii, spacing and motion come from MacToolsKit, never literals.
