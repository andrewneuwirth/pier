import AppKit
import ApplicationServices

/// Unread counts, read from the macOS Dock. It keeps running (hidden) under Pier, and every
/// app's badge still lands on its Dock item as the AXStatusLabel attribute. Needs Accessibility.
enum DockBadges {
    @MainActor
    static func read(matching items: [AppItem]) -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let byPath = Dictionary(items.map { ($0.url.standardizedFileURL.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(items.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })

        var result: [String: String] = [:]
        for list in children(of: AXUIElementCreateApplication(dock.processIdentifier)) {
            for tile in children(of: list) {
                guard let label = attribute(tile, "AXStatusLabel") as? String, !label.isEmpty else { continue }
                // Match on the app's path; Safari's lives in a cryptex, so fall back to its name.
                let path = (attribute(tile, kAXURLAttribute) as? URL)?.standardizedFileURL.path
                if let id = path.flatMap({ byPath[$0] }) ?? (attribute(tile, kAXTitleAttribute) as? String).flatMap({ byName[$0] }) {
                    result[id] = label
                }
            }
        }
        return result
    }

    /// Asks once, at first launch; macOS remembers the answer.
    static func requestAccessOnce() {
        guard !UserDefaults.standard.bool(forKey: "askedAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
