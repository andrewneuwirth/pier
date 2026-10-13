# Tuck

One minimal button in the menu bar. Every icon to its left is tucked away;
click the button for a glass list of all menu bar icons and click one to open
its menu.

- **Left-click** the button: the list. A small dot marks icons still visible in the bar.
- **Right-click**: Show Hidden Icons, Open at Login, Quit.
- **Choose what stays visible:** turn on Show Hidden Icons, then ⌘-drag icons
  to the right of the faint divider dot (visible) or left of it (tucked).
- Needs Accessibility (System Settings → Privacy & Security → Accessibility).

How it works: a second, invisible status item sits left of the button and
grows to 10,000 pt, pushing everything left of it off screen. Opening a tucked
icon shrinks it for a moment, presses the icon through Accessibility, and
tucks again once the menu closes.

Build and install: `./build.sh` (signs with the Apple Development identity so
the Accessibility grant survives rebuilds).

Icon: `Assets/AppIcon.svg` is the source; `Assets/AppIcon.icns` is rendered from it.

Part of the Mac Tools family: colours, spacing, radii and Open at Login come from
`../Kit` (MacToolsKit), so build it with Kit checked out beside it.
