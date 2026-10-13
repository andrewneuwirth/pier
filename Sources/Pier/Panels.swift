import AppKit
import ApplicationServices
import SwiftUI

/// The bar itself: borderless, never takes focus, on every Space, at the Dock's own window level.
/// It is left out of full-screen Spaces, the way the real Dock stays out of a full-screen game.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the glass draws its own edge
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        isMovable = false
    }
    override var canBecomeKey: Bool { false }
}

/// A GlassPanel from the design system: opens 6pt above its anchor, stays 8pt inside the screen,
/// and (when `interactive`) closes on an outside click or Escape.
@MainActor
final class Popup {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    // An ordinary (activating) window: a click inside gives Pier the keyboard for real, which code can't.
    private let panel = Panel(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
    private let interactive: Bool
    private var anchor: NSRect = .zero
    private var monitors: [Any] = []
    private(set) var closedAt = Date.distantPast
    /// The app you were in when an interactive popup opened; focus goes back to it on close.
    var previous: NSRunningApplication?
    var isVisible: Bool { panel.isVisible }

    init(interactive: Bool) {
        self.interactive = interactive
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.acceptDrops()
    }

    func show(_ view: some View, above anchor: NSRect, drop: FirstClickHostingView<AnyView>.DropRouter? = nil) {
        self.anchor = anchor
        hosting.dropRouter = drop
        // A fresh identity per show: the hosting view is reused, and without this SwiftUI keeps the
        // previous card's @State (and skips its .task), so every card showed the first app's memory.
        hosting.rootView = AnyView(view.fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            self?.place(size)
        }.id(UUID()))
        place(hosting.fittingSize)
        panel.orderFrontRegardless()
        if interactive && monitors.isEmpty {
            // Remember the app you were in; Pier takes the keyboard while the popup is open and gives it back.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                previous = NSWorkspace.shared.frontmostApplication
            }
            Pier.takeFront { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                } as Any,
                // By position, not event.window: the click that activates Pier can arrive without one.
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self, !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
                    }
                    return event
                } as Any,
                // Esc: Pier holds the keyboard while the popup is open (takeFront below).
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53 else { return event }   // Escape
                    MainActor.assumeIsolated { self?.close() }
                    return nil
                } as Any,
            ]
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        closedAt = Date()
        if let previous, NSApp.isActive { previous.activate() }
        previous = nil
    }

    private func place(_ size: CGSize) {
        guard size.width > 0, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        let x = min(max(anchor.midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - 8 - size.width)
        panel.setFrame(NSRect(x: x, y: anchor.maxY + 6, width: size.width, height: size.height), display: true)
    }
}

/// Without this, the first click on a panel that isn't key only makes it key, and a preview
/// or tile needs a second click to act.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI's dropDestination never fired in these panels, so drops are taken here, in AppKit, and
    /// handed to whoever owns the window, with the point in SwiftUI's global (top-left) coordinates.
    struct DropRouter {
        var over: (CGPoint?) -> Bool          // nil when the drag leaves; true when that spot takes a drop
        var drop: ([URL], CGPoint) -> Bool
    }
    var dropRouter: DropRouter?
    /// Right-click at a point (SwiftUI global coordinates): the owner's menu for it, or nil for SwiftUI's.
    var rightClick: ((CGPoint) -> NSMenu?)?

    /// AppKit asks the view for its context menu on every right-click, even in a panel that never
    /// takes focus (an event monitor there missed them). The owner gets first say; otherwise
    /// SwiftUI's .contextMenu as usual.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        // Returned, not popped up: AppKit then runs it as a real context menu, so Esc and outside
        // clicks close it even though Pier is never the frontmost app.
        return rightClick?(point) ?? super.menu(for: event)
    }

    func acceptDrops() { registerForDraggedTypes([.fileURL, .URL]) }

    private func point(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSLog("Pier: drag entered (router: \(dropRouter != nil))")
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropRouter else { return super.draggingUpdated(sender) }
        return dropRouter.over(point(sender)) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let dropRouter else { return super.draggingExited(sender) }
        _ = dropRouter.over(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropRouter else { return super.performDragOperation(sender) }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        NSLog("Pier: drop of \(urls.count) item(s)")
        let taken = dropRouter.drop(urls, point(sender))
        _ = dropRouter.over(nil)
        return taken
    }
}

@MainActor
enum Pier {
    /// Makes Pier the frontmost app for real, so a popup gets the keyboard (Esc, typing) at once.
    /// NSApp.activate is refused for a background app that never takes focus: it reports success
    /// while keys keep going to the previous app. Setting AXFrontmost through Accessibility (which
    /// Pier has) is honoured. It's asked off the main thread, which has to answer the request.
    static func takeFront(then done: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            if AXIsProcessTrusted() {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}
