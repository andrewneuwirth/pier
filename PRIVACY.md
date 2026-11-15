# Pier Privacy Policy

_Last updated: November 2026_

Pier is an open-source Dock replacement that runs on your Mac. This policy covers the Pier app built from this repository.

## The short version

Pier has no server and collects nothing: no analytics, tracking, crash reporting or advertising. The authors never receive
your data. Everything Pier reads stays on your Mac, except the two usage requests described below.

## What Pier reads on your Mac

- **Apps and windows**: which apps are running, and (with Accessibility) their windows, menus and unread badges, to draw
  the bar. With Screen Recording, window thumbnails for hover previews. Thumbnails are kept in memory only.
- **Files**: your Downloads folder and screenshot folder, and file names from the Spotlight index when you search.
- **Claude Code sessions**: the small status files in `~/.claude/sessions`, to show when a session needs you.
- **Your Dock**: the macOS Dock's pinned apps, once, if you choose "Use My Dock's Apps" during setup. Pier hides the Dock
  while it runs and restores your own Dock settings when you quit it.

## AI usage (Memory & AI Usage widget)

To show your Claude and ChatGPT plan limits, Pier asks those services for your current usage: `api.anthropic.com` with the
Claude Code sign-in already in your login Keychain, and `chatgpt.com` with the Codex sign-in in `~/.codex/auth.json`. Each
token is sent only to the service it belongs to, and is never written, logged or cached by Pier. Without those sign-ins
nothing is requested. Remove the widget in Customize Pier… › Widgets and Pier stops making these requests.

## Website icons

For Quick Links and search, Pier fetches each link's own icon from that website (its homepage or `/favicon.ico`) and
caches it in `~/Library/Caches/app.newitools.Pier`.

## Where your settings live

- `~/Library/Application Support/Pier` (groups, widgets, links, tab groups)
- `~/Library/Application Support/UsageRings/usage.json` (the last usage reading)
- macOS user defaults: `defaults delete app.newitools.Pier` (or your own bundle id) removes them.

## Changes and contact

Changes to this policy are made in this file and visible in the repository history. Questions: hello@newitools.app or open
an issue.
