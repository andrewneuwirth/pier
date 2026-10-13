import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

/// Minimized windows, shown in their own section of the bar as the macOS Dock does: a picture of the
/// window with its app's icon in the corner. Click one to bring it back. Kept current by Accessibility
/// notifications from every app, so nothing is polled.
@MainActor @Observable
final class MinimizedWindows {
    struct Window: Identifiable {
        let id: WinID
        let element: AXUIElement
        let app: NSRunningApplication
        var title: String
        var picture: NSImage?
    }

    private(set) var windows: [Window] = []
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var workspace: [NSObjectProtocol] = []

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
                    guard let self, let pid else { return }
                    if let observer = self.observers.removeValue(forKey: pid) {
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                    }
                    self.windows.removeAll { $0.app.processIdentifier == pid }
                }
            },
        ]
        rescan()
    }

    /// Back on screen, its app in front.
    func restore(_ window: Window) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        window.app.activate()
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        windows.removeAll { $0.id == window.id }
    }

    // MARK: Watching

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, minimizedCallback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    fileprivate func handle(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXWindowMiniaturizedNotification:
            guard let id = AXWin.id(element), !windows.contains(where: { $0.id == id }),
                  let app = NSRunningApplication(processIdentifier: AXWin.pid(element)) else { return }
            windows.append(Window(id: id, element: element, app: app, title: AXWin.title(element)))
            snapshot(id)
        case kAXWindowDeminiaturizedNotification:
            guard let id = AXWin.id(element) else { return }
            windows.removeAll { $0.id == id }
        default:
            // Something closed; drop any minimized window that no longer exists.
            let before = windows.count
            windows.removeAll { window in !AXWin.windows(of: window.app.processIdentifier).contains { AXWin.id($0) == window.id } }
            if windows.count != before { return }
        }
    }

    /// Windows already minimized when Pier starts.
    private func rescan() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            for element in AXWin.windows(of: app.processIdentifier)
            where AXWin.isStandard(element) && (AXWin.attribute(element, kAXMinimizedAttribute) as? Bool) == true {
                guard let id = AXWin.id(element), !windows.contains(where: { $0.id == id }) else { continue }
                windows.append(Window(id: id, element: element, app: app, title: AXWin.title(element)))
                snapshot(id)
            }
        }
    }

    /// The window's last picture, when macOS still has one (needs Screen Recording); else the app icon shows.
    private func snapshot(_ id: WinID) {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let window = content.windows.first(where: { $0.windowID == id }) else { return }
            let config = SCStreamConfiguration()
            let scale = 240 / max(window.frame.width, window.frame.height, 1)
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                         configuration: config),
                  let i = windows.firstIndex(where: { $0.id == id }) else { return }
            windows[i].picture = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        }
    }
}

private let minimizedCallback: AXObserverCallback = { _, element, notification, me in
    guard let me else { return }
    let minimized = Unmanaged<MinimizedWindows>.fromOpaque(me).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { minimized.handle(name, element) }
}
