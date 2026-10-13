import AppKit
import ApplicationServices

/// A window's CGWindowID: stable for the window's life, shared by Accessibility and CGWindowList.
typealias WinID = UInt32

/// The window id behind an Accessibility window (private but long-stable; window managers rely on it).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Reading and moving other apps' windows through Accessibility.
enum AXWin {
    static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(e, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func id(_ e: AXUIElement) -> WinID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        return pid
    }

    static func title(_ e: AXUIElement) -> String { attribute(e, kAXTitleAttribute) as? String ?? "" }

    static func isStandard(_ e: AXUIElement) -> Bool {
        attribute(e, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Position, size, then position again: an app may refuse a size that doesn't fit where it is.
    static func setFrame(_ e: AXUIElement, _ r: CGRect) {
        var origin = r.origin, size = r.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        return element(app, kAXFocusedWindowAttribute)
    }

    static func bringForward(_ e: AXUIElement) {
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid(e))?.activate()
    }

    // Accessibility measures from the top-left of the main display, AppKit from its bottom-left.
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
    static func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }
}
