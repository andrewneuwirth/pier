# Pier

A replacement for the macOS Dock. Your apps in named groups, a search panel for apps, settings, files and screenshots,
your downloads, and live memory and AI-usage readings, in one bar you can rearrange. SwiftUI and AppKit, macOS 26, no
server.

From [newi tools](https://newitools.app/pier/).

## Features

- **App groups**: pinned apps in named groups. Drag apps on to pin, off to unpin, along the bar to reorder.
- **Widgets you choose**: Recent Apps, Search, Memory & AI Usage, Minimized Windows, Quick Links, Projects, Downloads,
  Trash and more. Show, hide and reorder them in **Customize Pier…** (right-click the bar).
- **Search** (⌥Space, or ⌘Space once Spotlight's shortcut is off): apps, System Settings panes, files from Spotlight,
  links, and your newest screenshots with ⌘C to copy.
- **Hover previews** of an app's windows, a window list and tab groups on right-click, unread badges.
- **Downloads** newest first, with a drop zone for sending files.
- **Memory, heat and AI limits** (Claude, ChatGPT) at a glance.
- Bottom or right edge, on the display you pick. Quitting Pier puts your macOS Dock back exactly as it was.
- A short **first-launch walkthrough**: import your Dock's apps, pick widgets, grant permissions, set up search.

## Screenshots

_Coming soon._

## Build from source

Needs Xcode 26 or later (Swift 6.2 tools) on macOS 26.

```sh
git clone <this repo> Pier && cd Pier
swift build && .build/debug/Pier --self-check   # should print "self-check ok"
./build.sh                                      # makes build/Pier.app
open build/Pier.app
```

Pier uses MacToolsKit from [mac-tools-kit](https://github.com/andrewneuwirth/mac-tools-kit); SwiftPM fetches it, or uses a checkout at
`../Kit` if you have one. `build.sh` signs with your Apple Development identity if you have one (a stable signature keeps
the Accessibility and Screen Recording grants across rebuilds), otherwise ad hoc. To use your own bundle id or signing
identity, copy `config.example.env` to `config.local.env` and edit it.

## Permissions

Pier works without any, with fewer features. **Accessibility** adds window menus, tab groups, unread badges, keeping
windows clear of the bar and pasting screenshots. **Screen Recording** adds window previews. The walkthrough and
Customize Pier… › Permissions show what's on.

## Automation

Other tools (Hammerspoon, a mouse utility) can post these distributed notifications:

- `app.newitools.pier.search`: open or close search
- `app.newitools.pier.pasteScreenshot`: paste the newest screenshot from the last 10 minutes into the front app

## Privacy

Pier runs entirely on your Mac and collects nothing. The only requests it makes are for website icons and, if you're
signed in to Claude Code or Codex, your plan usage from those services. Full policy: [PRIVACY.md](PRIVACY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
