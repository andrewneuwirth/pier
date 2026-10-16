import AppKit
import ApplicationServices

/// Keeps windows above the bar, the way the macOS Dock does. With the real Dock auto-hidden, macOS
/// counts the bottom of the screen as free, so new windows, Fill and zoom run under Pier. A window
/// that opens or resizes into the bar's strip is trimmed (or, if it won't shrink, lifted) to end above it.
/// Dragging a window down by hand is left alone, as the real Dock allows.
@MainActor
final class DockClearance {
    /// The bar's top edge in AppKit coordinates, and its screen; nil while the bar isn't showing.
    var bar: () -> (top: CGFloat, screen: NSScreen)?
    private var observers: [pid_t: AXObserver] = [:]
    private var workspace: [NSObjectProtocol] = []
    private var pending: [WinID: DispatchWorkItem] = [:]

    init(bar: @escaping () -> (top: CGFloat, screen: NSScreen)?) { self.bar = bar }

    func start() {
        guard AXIsProcessTrusted() else { return }
        NSWorkspace.shared.runningApplications.forEach(observe)
        let center = NSWorkspace.shared.notificationCenter
        workspace = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { if let app { self?.observe(app) } }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let pid, let observer = self?.observers.removeValue(forKey: pid) else { return }
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                }
            },
        ]
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, clearanceCallback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Waits for the window to settle (a live resize sends a stream of these) before fixing it once.
    fileprivate func handle(_ element: AXUIElement) {
        guard let id = AXWin.id(element) else { return }
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending[id] = nil
                self?.clear(element)
            }
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clear(_ element: AXUIElement) {
        guard let bar = bar(), AXWin.isStandard(element),
              (AXWin.attribute(element, "AXFullScreen") as? Bool) != true,
              (AXWin.attribute(element, kAXMinimizedAttribute) as? Bool) != true,
              let frame = AXWin.frame(element) else { return }
        let screen = AXWin.flipped(bar.screen.frame)
        let line = AXWin.mainHeight - bar.top
        guard let wanted = Self.cleared(frame, line: line, screen: screen) else { return }
        AXWin.setFrame(element, wanted)
        // Some windows won't go shorter than a minimum: lift those instead, keeping the menu bar clear.
        if let now = AXWin.frame(element), now.maxY > line + 1 {
            let top = max(AXWin.mainHeight - bar.screen.visibleFrame.maxY, line - now.height)
            AXWin.setFrame(element, CGRect(x: now.minX, y: top, width: now.width, height: now.height))
        }
    }

    /// The frame (Accessibility coordinates, y down) that ends at `line`, or nil when the window
    /// doesn't reach into the bar's strip on that screen. A window whose top is already below the line
    /// (a parked tab, one dragged down by hand) is left where it is.
    nonisolated static func cleared(_ frame: CGRect, line: CGFloat, screen: CGRect) -> CGRect? {
        guard frame.maxY > line + 1, frame.minY < line, frame.minX < screen.maxX, frame.maxX > screen.minX,
              frame.minY >= screen.minY, frame.minY < screen.maxY else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: line - frame.minY)
    }
}

private let clearanceCallback: AXObserverCallback = { _, element, _, me in
    guard let me else { return }
    let clearance = Unmanaged<DockClearance>.fromOpaque(me).takeUnretainedValue()
    MainActor.assumeIsolated { clearance.handle(element) }
}
