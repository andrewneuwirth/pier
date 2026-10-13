import AppKit
import ApplicationServices

/// An app's own Dock menu items (Terminal's New Window, its open windows, Chrome's New Incognito
/// Window), read from the macOS Dock: it keeps running hidden under Pier, and opening a tile's menu
/// through Accessibility lists them. Choosing one presses the same item in the Dock's menu, so it
/// behaves exactly as in the Dock. Needs Accessibility; without it Pier shows only its own items.
enum DockMenus {
    struct Entry {
        var title: String          // "" is a separator
        var enabled = true
        var children: [Entry] = []
    }

    /// The Dock's own items: Pier has its own versions, or they make no sense from Pier.
    private static let dockItems: Set<String> = ["Options", "Show All Windows", "Hide", "Hide Others", "Quit", "Force Quit",
                                                 "Show Recents", "Open", "Show in Finder", "Keep in Dock", "Remove from Dock",
                                                 "Open at Login", "Assign To", "Unhide"]

    /// The app's actions (New Window, New Window with Profile ▸ …), without its window list. Reading
    /// them opens the Dock's own menu for an instant, so it happens once per app and is remembered.
    @MainActor private static var cache: [String: [Entry]] = [:]

    /// Synchronous: a context menu must be ready when AppKit asks. Only the first read per app waits
    /// (≈0.2 s) on the Dock; after that it's the remembered copy.
    @MainActor
    static func actions(_ item: AppItem, windowTitles: Set<String>) -> [Entry] {
        if let cached = cache[item.url.path] { return cached }
        let read = withMenu(of: item) { menu in entries(of: menu) } ?? []
        // The window list changes all the time and Pier reads it directly, so keep only the actions.
        let actions = tidy(read.filter { !windowTitles.contains($0.title) })
        if !read.isEmpty { cache[item.url.path] = actions }
        return actions
    }

    /// The app's open windows, straight from Accessibility (no Dock menu involved).
    static func windows(of app: NSRunningApplication) -> [(title: String, element: AXUIElement)] {
        guard AXIsProcessTrusted() else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return children(of: element, attribute: kAXWindowsAttribute).compactMap { window in
            guard let title = string(window, kAXTitleAttribute), !title.isEmpty,
                  string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { return nil }
            return (title, window)
        }
    }

    static func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        app.activate()
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Presses the item at `path` (titles from the top level down) in the app's Dock menu.
    static func press(_ path: [String], of item: AppItem) {
        Task.detached(priority: .userInitiated) {
            _ = withMenu(of: item, close: false) { menu -> Bool in
                var level = menu
                for (depth, title) in path.enumerated() {
                    guard let element = children(of: level).first(where: { string($0, kAXTitleAttribute) == title }) else {
                        cancel(menu); return false
                    }
                    if depth == path.count - 1 {
                        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                    }
                    guard let submenu = children(of: element).first(where: { string($0, kAXRoleAttribute) == "AXMenu" }) else {
                        cancel(menu); return false
                    }
                    level = submenu
                }
                cancel(menu)
                return false
            }
        }
    }

    // MARK: Accessibility

    private static func withMenu<T>(of item: AppItem, close: Bool = true, _ body: (AXUIElement) -> T) -> T? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let tiles = children(of: app).flatMap { children(of: $0) }
        let path = item.url.standardizedFileURL.path
        guard let tile = tiles.first(where: { ($0.url)?.standardizedFileURL.path == path })
                ?? tiles.first(where: { string($0, kAXTitleAttribute) == item.name }) else { return nil }
        guard AXUIElementPerformAction(tile, "AXShowMenu" as CFString) == .success else { return nil }
        // The menu appears on the Dock app, not under the tile; wait for it, up to 0.6 s.
        for _ in 0..<30 {
            if let menu = firstMenu(in: app) {
                let result = body(menu)
                if close { cancel(menu) }
                return result
            }
            usleep(20_000)
        }
        return nil
    }

    private static func entries(of menu: AXUIElement) -> [Entry] {
        children(of: menu).map { element in
            let submenu = children(of: element).first { string($0, kAXRoleAttribute) == "AXMenu" }
            return Entry(title: string(element, kAXTitleAttribute) ?? "",
                         enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
                         children: submenu.map(entries(of:)) ?? [])
        }
    }

    /// Drops the Dock's own items and the separators they leave behind.
    private static func tidy(_ entries: [Entry]) -> [Entry] {
        var out: [Entry] = []
        for entry in entries where !dockItems.contains(entry.title) {
            if entry.title.isEmpty && (out.isEmpty || out.last?.title.isEmpty == true) { continue }
            out.append(entry)
        }
        while out.last?.title.isEmpty == true { out.removeLast() }
        return out
    }

    private static func firstMenu(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == "AXMenu" { return element }
        guard depth < 4 else { return nil }
        for child in children(of: element) { if let menu = firstMenu(in: child, depth: depth + 1) { return menu } }
        return nil
    }

    private static func cancel(_ menu: AXUIElement) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    private static func children(of element: AXUIElement, attribute name: String = kAXChildrenAttribute) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }
}

private extension AXUIElement {
    var url: URL? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, kAXURLAttribute as CFString, &value) == .success ? value as? URL : nil
    }
}
