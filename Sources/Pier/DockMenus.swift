import AppKit
import ApplicationServices

/// An app's open windows and a New Window action, read straight from the app through Accessibility.
/// (Reading the macOS Dock's own menu flashed it on screen and made right-clicks slow and flaky.)
enum DockMenus {
    /// The app's ordinary windows, minimized ones included.
    static func windows(of app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        guard AXIsProcessTrusted() else { return [] }
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(app.processIdentifier), 0.3)   // a busy app can't stall it
        return AXWin.windows(of: app.processIdentifier).compactMap { window in
            let title = AXWin.title(window)
            guard !title.isEmpty, AXWin.isStandard(window) else { return nil }
            return (title, window)
        }
    }

    static func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        app.activate()
        if (AXWin.attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// ⌘N in the app: New Window in Terminal, Finder, browsers and most others.
    static func newWindow(_ app: NSRunningApplication) {
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for down in [true, false] {
                let key = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: down)   // 45 = N
                key?.flags = .maskCommand
                key?.postToPid(app.processIdentifier)
            }
        }
    }
}
