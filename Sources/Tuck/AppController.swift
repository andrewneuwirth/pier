import AppKit
import MacToolsKit
import SwiftUI

/// Two status items: the visible Tuck button, and an invisible divider to its
/// left. While hiding, the divider grows to 10,000 pt, which pushes every icon
/// left of it off the screen. ⌘-drag icons across the divider to choose.
final class AppController: NSObject, NSApplicationDelegate {
    private var button: NSStatusItem!
    private var divider: NSStatusItem!
    private let panel = TrayPanel()
    private let model = TrayModel()
    private lazy var hosting = NSHostingController(rootView: TrayView(model: model))
    private var outsideClick: Any?
    private var rehideTimer: Timer?

    private lazy var hiddenLength: CGFloat = systemOverflow ? shownLength : 10_000   // macOS 27: see fitHiddenLength
    private let shownLength: CGFloat = 14
    private var anchor = NSPoint.zero   // where the button was clicked; the panel hangs below it

    /// macOS 27 draws the whole menu bar in one window and moves items that don't fit into
    /// its own overflow (behind a « chevron), and drops a 10,000 pt item from the bar entirely.
    private let systemOverflow = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    private var hiding: Bool {
        get { !UserDefaults.standard.bool(forKey: "showAll") }
        set { UserDefaults.standard.set(!newValue, forKey: "showAll") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // First run: put the button rightmost and the divider just left of it.
        let d = UserDefaults.standard
        if d.object(forKey: "NSStatusItem Preferred Position tuck.button") == nil {
            d.set(0, forKey: "NSStatusItem Preferred Position tuck.button")
            d.set(1, forKey: "NSStatusItem Preferred Position tuck.divider")
        }

        button = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        button.autosaveName = "tuck.button"
        button.behavior = []
        if let b = button.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            b.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Tuck")?
                .withSymbolConfiguration(cfg)
            b.image?.isTemplate = true
            b.target = self
            b.action = #selector(buttonClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        divider = NSStatusBar.system.statusItem(withLength: shownLength)
        divider.autosaveName = "tuck.divider"
        divider.behavior = []
        if let b = divider.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 4, weight: .regular)
            b.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Tuck divider")?
                .withSymbolConfiguration(cfg)
            b.image?.isTemplate = true
            b.appearsDisabled = true
        }
        applyHiding()
        if systemOverflow {
            fitHiddenLength()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in self?.fitHiddenLength() }
        }

        panel.contentViewController = hosting
        panel.onEscape = { [weak self] in self?.closePanel() }
        model.onSelect = { [weak self] in self?.openItem($0) }
        model.onGrant = { [weak self] in
            _ = BarItems.trusted(prompt: true)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            self?.closePanel()
        }

        _ = BarItems.trusted(prompt: true)
    }

    // MARK: Hiding

    private func applyHiding() {
        divider.length = hiding ? hiddenLength : shownLength
        divider.button?.image?.isTemplate = true
        divider.button?.alphaValue = hiding ? 0 : 1
    }

    /// macOS 27: the divider fills the gap between the notch and the button. That's too wide
    /// to fit beside the other icons, so the divider and everything left of it go into the
    /// system overflow, yet narrow enough that macOS keeps it in the bar instead of dropping it.
    /// Without a notch there is no such width, so hiding is left to macOS.
    private func fitHiddenLength() {
        divider.length = shownLength   // measure with the divider back in the bar, beside Tuck
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {   // Tuck answers its own AX on main
            let tuck = BarItems.ownItemFrame("Tuck"), div = BarItems.ownItemFrame("Tuck divider")
            DispatchQueue.main.async {
                var length = self.shownLength
                if let tuck, let div, div.minX < tuck.minX,   // divider right of Tuck would tuck Tuck itself
                   let notch = NSScreen.screens.first(where: { $0.frame.minX <= tuck.midX && tuck.midX < $0.frame.maxX })?
                       .auxiliaryTopRightArea {
                    length = max(tuck.minX - notch.minX, self.shownLength)
                }
                self.hiddenLength = length
                self.applyHiding()
            }
        }
    }

    private func setTemporarilyShown(_ shown: Bool) {
        guard hiding else { return }
        divider.length = shown ? shownLength : hiddenLength
        divider.button?.alphaValue = 0
    }

    private var dividerMidX: CGFloat? {
        guard !systemOverflow, let w = divider.button?.window else { return nil }
        return w.frame.maxX   // anything left of the divider's right edge is tucked
    }

    // MARK: Button

    @objc private func buttonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        anchor = NSEvent.mouseLocation
        panel.isVisible ? closePanel() : showPanel()
    }

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Hidden Icons", action: #selector(toggleShowAll), keyEquivalent: "")
        show.state = hiding ? .off : .on
        show.target = self
        menu.addItem(show)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tuck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        button.menu = menu
        button.button?.performClick(nil)
        button.menu = nil
    }

    @objc private func toggleShowAll() {
        hiding.toggle()
        applyHiding()
        if systemOverflow && hiding { fitHiddenLength() }   // the divider may have been ⌘-dragged
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    // MARK: Panel

    private func showPanel() {
        rehideTimer?.invalidate()
        setTemporarilyShown(false)
        model.trusted = BarItems.trusted(prompt: false)
        model.loading = true
        if model.trusted {
            let divX = dividerMidX
            DispatchQueue.global(qos: .userInitiated).async {
                let items = BarItems.all(dividerX: divX)
                DispatchQueue.main.async {
                    self.model.items = items
                    self.model.loading = false
                    self.positionPanel()
                }
            }
        }
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func positionPanel() {
        // Not the button's window frame: on macOS 27 status items have no real window of their own.
        let size = hosting.sizeThatFits(in: CGSize(width: 260, height: 2000))
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var x = anchor.x - size.width / 2
        if let s = screen?.visibleFrame { x = min(max(x, s.minX + MT.Space.s8), s.maxX - size.width - MT.Space.s8) }
        let y = (screen?.visibleFrame.maxY ?? anchor.y) - size.height - MT.Space.s6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }

    // MARK: Opening an item

    private func openItem(_ item: BarItem) {
        closePanel()
        let reveal = item.hidden && hiding && !systemOverflow   // macOS 27 opens overflowed items in place
        if reveal { setTemporarilyShown(true) }
        let el = item.element
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait (up to ~1.5 s) for the icon to land on screen; a menu opened
            // while it is still off screen opens off screen too.
            if reveal {
                for _ in 0..<30 where !BarItems.isOnScreen(el) { Thread.sleep(forTimeInterval: 0.05) }
                Thread.sleep(forTimeInterval: 0.08)
            }
            DispatchQueue.main.async { if reveal { self.rehideWhenMenuCloses(pid: item.pid) } }
            BarItems.open(el)
        }
    }

    /// Keeps hidden icons on screen while the opened menu is up, then tucks them away.
    private func rehideWhenMenuCloses(pid: pid_t) {
        rehideTimer?.invalidate()
        let start = Date()
        var sawMenu = false
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            let open = MenuWatch.menuIsOpen(pid: pid)
            if open { sawMenu = true }
            let age = Date().timeIntervalSince(start)
            if (!open && (sawMenu || age > 2.5)) || age > 300 {
                t.invalidate()
                self?.setTemporarilyShown(false)
            }
        }
    }
}
