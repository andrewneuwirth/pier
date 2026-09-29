import AppKit
import ServiceManagement
import SwiftUI

private let panelSize = NSSize(
    width: ringDiameter * 2 + ringGap + ringPadding * 2,
    height: ringDiameter + ringPadding * 2)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var dragOrigin: NSPoint?
    private var detailPanel: NSPanel?
    private var detailService: Service?
    private var dismissMonitor: Any?

    private let defaults = UserDefaults.standard
    /// The floating rings on the desktop. Off by default now that there's a
    /// real widget (Edit Widgets › Usage Rings).
    private var showDesktopRings: Bool {
        get { defaults.bool(forKey: "showDesktopRings") }
        set { defaults.set(newValue, forKey: "showDesktopRings"); newValue ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    }

    private var keepInFront: Bool {
        get { defaults.bool(forKey: "keepInFront") }
        set { defaults.set(newValue, forKey: "keepInFront"); applyLevel() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
    }

    // MARK: - Panel

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false   // handled by the drag gesture
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = RingsView(store: store,
                             onDrag: { [weak self] in self?.drag(by: $0) },
                             onDragEnded: { [weak self] in self?.endDrag() },
                             onInspect: { [weak self] in self?.inspect($0) })
        panel.contentView = NSHostingView(rootView: view)

        applyLevel()
        panel.setFrameOrigin(savedOrigin())
        if showDesktopRings { panel.orderFrontRegardless() }
    }

    /// By default the rings live on the desktop — visible when you look at it,
    /// out of the way when you are working. "Keep in Front" lifts them above
    /// normal windows for anyone who would rather always see the numbers.
    private func applyLevel() {
        let desktop = CGWindowLevelForKey(.desktopIconWindow) + 1
        panel?.level = keepInFront ? .floating : NSWindow.Level(rawValue: Int(desktop))
    }

    /// Parks the rings in the bottom-right corner on first launch. This uses
    /// the screen's full frame rather than its visible frame, so they sit down
    /// level with the Dock instead of floating above where it ends.
    private func savedOrigin() -> NSPoint {
        if let stored = defaults.string(forKey: "origin") {
            let point = NSPointFromString(stored)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(point) }) {
                return point
            }
        }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - panelSize.width, y: screen.minY + 16)
    }

    private func drag(by translation: CGSize) {
        hideDetail()
        let start = dragOrigin ?? panel.frame.origin
        dragOrigin = start
        panel.setFrameOrigin(NSPoint(x: start.x + translation.width,
                                     y: start.y - translation.height))
    }

    private func endDrag() {
        dragOrigin = nil
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    // MARK: - Detail card

    /// Double-clicking the ring you are already looking at puts the card away,
    /// so the same gesture both opens and closes it.
    private func inspect(_ service: Service) {
        guard detailService != service else { hideDetail(); return }
        hideDetail()
        detailService = service

        let content = NSHostingView(rootView: DetailHost(store: store, service: service))
        let size = content.fittingSize

        let card = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true
        // The rings live at desktop level, but the card is a transient reply to
        // a click: it goes above other floating desktop widgets so nothing can
        // sit on top of the numbers it was opened to show.
        card.level = .popUpMenu
        card.collectionBehavior = panel.collectionBehavior
        card.contentView = content
        card.setContentSize(size)
        card.setFrameOrigin(detailOrigin(for: service))
        card.orderFrontRegardless()
        detailPanel = card

        // A click anywhere outside this app dismisses it. Clicks on the rings
        // themselves stay with the app, so switching services still works.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideDetail() }
        }

        store.refresh()
    }

    private func hideDetail() {
        detailPanel?.orderOut(nil)
        detailPanel = nil
        detailService = nil
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
    }

    /// Centred over the ring that was clicked and sat just above the panel,
    /// then pulled back onto the screen if that would hang it off the edge.
    private func detailOrigin(for service: Service) -> NSPoint {
        let index = CGFloat(Service.allCases.firstIndex(of: service) ?? 0)
        let centre = panel.frame.minX + ringPadding + index * (ringDiameter + ringGap) + ringDiameter / 2
        let screen = (NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(centre - detailCardWidth / 2, screen.minX + 8),
                    screen.maxX - detailCardWidth - 8)
        return NSPoint(x: x, y: panel.frame.maxY + 6)
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle",
                                           accessibilityDescription: "Usage Rings")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        for service in Service.allCases {
            let usage = store.readings[service] ?? .empty
            let item = NSMenuItem(title: summary(service, usage), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh Now", #selector(refreshNow), key: "r"))

        let desk = item("Show Desktop Rings", #selector(toggleDesktopRings))
        desk.state = showDesktopRings ? .on : .off
        menu.addItem(desk)

        let front = item("Keep in Front", #selector(toggleKeepInFront))
        front.state = keepInFront ? .on : .off
        menu.addItem(front)

        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Usage Rings", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        return menuItem
    }

    private func summary(_ service: Service, _ usage: Usage) -> String {
        if usage.failed { return "\(service.title): \(usage.note ?? "unavailable")" }
        let parts = [usage.short.map { "session \(Int($0.percent.rounded()))%" },
                     usage.long.map { "week \(Int($0.percent.rounded()))%" }].compactMap { $0 }
        if parts.isEmpty { return "\(service.title): —" }
        let held = usage.stale ? "  ⚠ \(usage.holdReason ?? "refresh failed")" : ""
        return "\(service.title): \(parts.joined(separator: ", "))\(held)"
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func toggleKeepInFront() { keepInFront.toggle() }

    @objc private func toggleDesktopRings() { showDesktopRings.toggle() }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }
}

@MainActor
extension AppDelegate: NSMenuDelegate {
    /// The readings are only worth rendering into the menu when it opens.
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

// `UsageRings --dump` prints what the rings would draw, through the very same
// fetch path, so a wrong number can be diagnosed without squinting at a circle.
if CommandLine.arguments.contains("--dump") {
    let done = DispatchSemaphore(value: 0)
    Task {
        for service in Service.allCases {
            let usage = service == .claude ? await ClaudeSource.load() : await ChatGPTSource.load()
            var line = service.title.padding(toLength: 8, withPad: " ", startingAt: 0)
            if usage.failed {
                line += "· \(usage.note ?? "unavailable")"
            } else {
                let parts = [usage.short.map { "session \(Int($0.percent.rounded()))%" },
                             usage.long.map { "week \(Int($0.percent.rounded()))%" },
                             usage.short?.resetLabel.map { "resets in \($0)" }
                                ?? usage.long?.resetLabel.map { "resets in \($0)" }].compactMap { $0 }
                line += parts.isEmpty ? "· no windows reported" : "· " + parts.joined(separator: "  ")
            }
            print(line)
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Top-level code is not main-actor isolated, but every line of this bootstrap
// touches AppKit, which is — and at this point nothing else is running.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Held for the process lifetime; NSApplication only keeps a weak delegate.
    objc_setAssociatedObject(app, "UsageRingsDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
