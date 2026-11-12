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

/// A GlassPanel from the design system: opens 6pt above its anchor (to its left when the bar is on
/// the right edge), or without an anchor centred in the upper third of the main screen (Search); stays 8pt inside the screen,
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
    private var anchor: NSRect?
    /// Where an unanchored popup sits; chosen when it opens, so it never jumps screens while it grows.
    private var centredOn: NSScreen?
    private var edge = DockEdge.bottom
    private var monitors: [Any] = []
    private(set) var closedAt = Date.distantPast
    /// The app you were in when an interactive popup opened; focus goes back to it on close.
    var previous: NSRunningApplication?
    var isVisible: Bool { panel.isVisible }
    var window: NSWindow { panel }
    /// Whatever else has to go when the popup does (Search's Quick Look).
    var onClose: (() -> Void)?

    init(interactive: Bool) {
        self.interactive = interactive
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Said out loud, this turns off a see-through window's habit of letting clicks on its clear pixels
        // fall to the app behind. Glass is clear to the window server everywhere but its text and icons, so a
        // click on an empty part of a popup went to the other app, which counted as a click outside and closed it.
        panel.ignoresMouseEvents = false
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.acceptDrops()
    }

    func show(_ view: some View, from anchor: NSRect?, edge: DockEdge, drop: FirstClickHostingView<AnyView>.DropRouter? = nil) {
        self.anchor = anchor
        // The screen the pointer is on (Spotlight does the same), so it opens on the monitor in use.
        let pointer = NSEvent.mouseLocation
        centredOn = anchor == nil
            ? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
            : nil
        self.edge = edge
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
            Pier.takeFront { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.panel.makeKeyAndOrderFront(nil)
                self.focusTextField()
            }
            monitors = [
                // By position here too: no click inside the popup closes it, whoever the click was delivered to.
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if let self, !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
                    }
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

    /// `restoreFocus: false` when closing because something was just opened: handing the keyboard back to the
    /// previous app then fought the app being launched for the front.
    func close(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        closedAt = Date()
        onClose?()
        if restoreFocus, let previous, NSApp.isActive { previous.activate() }
        previous = nil
    }

    /// Puts the cursor in the popup's text field, if it has one. SwiftUI's own focus request runs in onAppear,
    /// before the panel is key, and is dropped whenever the panel becomes key late (every open after the first).
    private func focusTextField() {
        func field(in view: NSView) -> NSTextField? {
            if let f = view as? NSTextField, f.isEditable { return f }
            for sub in view.subviews { if let f = field(in: sub) { return f } }
            return nil
        }
        if let f = field(in: hosting) { panel.makeFirstResponder(f) }
    }

    private func place(_ size: CGSize) {
        guard size.width > 0 else { return }
        guard let anchor else {
            // Like Spotlight: the top edge stays put in the upper third and the results grow downward.
            guard let area = centredOn?.frame else { return }
            panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.maxY - area.height * 0.22 - size.height).rounded(),
                                  width: size.width, height: size.height), display: true)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: min(max(anchor.midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - 8 - size.width),
                             y: anchor.maxY + 6)
        case .right:
            origin = CGPoint(x: max(anchor.minX - 6 - size.width, screen.frame.minX + 8),
                             y: max(min(anchor.midY - size.height / 2, screen.visibleFrame.maxY - 8 - size.height), screen.frame.minY + 8))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
