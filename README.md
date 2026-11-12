# Tuck

One minimal button in the menu bar. Every icon to its left is tucked away;
click the button for a glass list of all menu bar icons and click one to open
its menu.

- **Left-click** the button: the list. A small dot marks icons still visible in the bar.
- **Right-click**: Show Hidden Icons, Open at Login, Quit.
- **Choose what stays visible:** turn on Show Hidden Icons, then ⌘-drag icons
  to the right of the faint divider dot (visible) or left of it (tucked).
- **macOS 27:** the menu bar is one window and icons that don't fit go behind its «
  chevron, per display. Tuck sizes the divider just too wide for the notch bar, so it and
  everything left of it land in that overflow (« stays visible there), and puts a second
  invisible spacer right beside it, about half a screen wide, for wider bars without a notch
  (on those the « goes too; use Tuck's list). Opening a tucked icon works in place.
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
