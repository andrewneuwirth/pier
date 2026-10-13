import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

struct WindowShot: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect   // global, top-left origin: the same space as AX positions
    let image: NSImage
}

/// Thumbnails of one app's open windows, for the hover card. Needs Screen Recording;
/// raising one exact window (not just the app) needs Accessibility.
@MainActor @Observable
final class WindowPreviews {
    enum State { case loading, needsPermission, none, shots([WindowShot]) }
    private(set) var state: State = .loading

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    func load(pid: pid_t) async {
        guard Self.canCapture else { state = .needsPermission; return }
        state = .loading
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
                    && $0.frame.width > 80 && $0.frame.height > 60
            }
            var shots: [WindowShot] = []
            for window in windows.prefix(6) {
                let config = SCStreamConfiguration()
                let scale = 360 / max(window.frame.width, window.frame.height)   // 180pt card at 2x
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                else { continue }
                shots.append(WindowShot(id: window.windowID, title: window.title ?? "", frame: window.frame,
                                        image: NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))))
            }
            state = shots.isEmpty ? .none : .shots(shots)
        } catch {
            state = .none
        }
    }

    static func requestCapture() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func remove(_ shot: WindowShot) {
        guard case .shots(let shots) = state else { return }
        let rest = shots.filter { $0.id != shot.id }
        state = rest.isEmpty ? .none : .shots(rest)
    }

    /// Brings the app forward, then that one window above its siblings.
    static func raise(_ shot: WindowShot, of app: NSRunningApplication) {
        app.activate()
        guard let window = axWindow(for: shot, of: app) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Presses the window's own close button, exactly like clicking its red dot, so the app
    /// still gets to ask about unsaved changes.
    @discardableResult
    static func close(_ shot: WindowShot, of app: NSRunningApplication) -> Bool {
        guard let window = axWindow(for: shot, of: app) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// The Accessibility window for a captured one: matched by position and size, since several
    /// windows (four Terminals) can share a title; title only as a fallback.
    private static func axWindow(for shot: WindowShot, of app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        func frame(_ w: AXUIElement) -> CGRect? {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
        if let match = windows.first(where: { w in
            frame(w).map { abs($0.minX - shot.frame.minX) < 2 && abs($0.minY - shot.frame.minY) < 2
                && abs($0.width - shot.frame.width) < 2 && abs($0.height - shot.frame.height) < 2 } ?? false
        }) { return match }
        return windows.first { w in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            return (title as? String) == shot.title
        }
    }
}
