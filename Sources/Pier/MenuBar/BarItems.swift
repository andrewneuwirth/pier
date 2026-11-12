import AppKit
import ApplicationServices

/// One icon in the menu bar, owned by some other app, reached through Accessibility.
struct BarItem: Identifiable {
    let id: String
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let icon: NSImage?
    let symbol: String?    // SF Symbol for Apple's built-in items
    let frame: CGRect      // global, top-left origin (same space as CGEvent)
    var hidden: Bool
}

enum BarItems {
    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Every menu bar extra of every running app except Tuck, left to right.
    /// `dividerX` is the divider's midpoint; items left of it are hidden. On macOS 27
    /// pass nil: the system's own overflow decides what is hidden.
    static func all(dividerX: CGFloat?) -> [BarItem] {
        var out: [BarItem] = []
        var chevron: CGRect?
        let me = getpid()
        let systemHosts: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            let isSystemHost = systemHosts.contains(app.bundleIdentifier ?? "")
            guard pid != me, app.activationPolicy != .prohibited || isSystemHost else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            guard let bar: AXUIElement = attr(axApp, "AXExtrasMenuBar"),
                  let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { continue }
            let appName = app.localizedName ?? "App"
            for (i, kid) in kids.enumerated() {
                // macOS 27: MenuBarAgent wraps each system item in a group, and its
                // "Show Hidden Menu Bar Items" chevron is a plain button.
                let el: AXUIElement = (attr(kid, kAXRoleAttribute) as String?) == "AXGroup"
                    ? (attr(kid, kAXChildrenAttribute) as [AXUIElement]?)?.first ?? kid : kid
                if app.bundleIdentifier == "com.apple.MenuBarAgent", (attr(el, kAXRoleAttribute) as String?) == "AXButton" {
                    chevron = Self.frame(of: el); continue
                }
                let frame = Self.frame(of: el)
                guard frame.width > 1 else { continue }   // unused Control Center slots
                let raw = [attr(el, kAXDescriptionAttribute), attr(el, kAXTitleAttribute), attr(el, kAXHelpAttribute)]
                    .compactMap { ($0 as String?)?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && $0.lowercased() != "status menu" }
                let title: String
                if kids.count > 1, let raw { title = raw }
                else if let raw, raw != appName, !raw.lowercased().hasPrefix(appName.lowercased()) { title = "\(appName) — \(raw)" }
                else { title = appName }
                let symbol = (app.bundleIdentifier ?? "").hasPrefix("com.apple.") ? Self.symbol(for: title) : nil
                out.append(BarItem(id: "\(pid)-\(i)", element: el, pid: pid, title: title,
                                   icon: app.icon, symbol: symbol, frame: frame, hidden: false))
            }
        }
        // macOS 27 hides items itself: everything under or left of the chevron is in its overflow.
        if let cut = dividerX ?? chevron?.maxX {
            for i in out.indices { out[i].hidden = out[i].frame.midX < cut }
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Frame of one of Tuck's own status items, by accessibility description.
    /// Call off the main thread. (On macOS 27 the items' window frames are meaningless.)
    static func ownItemFrame(_ description: String) -> CGRect? {
        let axApp = AXUIElementCreateApplication(getpid())
        guard let bar: AXUIElement = attr(axApp, "AXExtrasMenuBar"),
              let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute),
              let el = kids.first(where: { (attr($0, kAXDescriptionAttribute) as String?) == description }) else { return nil }
        return frame(of: el)
    }

    /// Opens the item's menu. AXPress first; a synthesized click only if the app
    /// doesn't support AXPress. (`.cannotComplete` usually means the menu opened
    /// and is tracking, so clicking again would close it.)
    static func open(_ el: AXUIElement) {
        let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
        guard result == .actionUnsupported || result == .attributeUnsupported else { return }
        let f = frame(of: el)
        guard f.width > 0, f.minX >= 0 else { return }
        let p = CGPoint(x: f.midX, y: f.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// True once the item has slid back into the visible menu bar.
    static func isOnScreen(_ el: AXUIElement) -> Bool {
        let f = frame(of: el)
        return f.width > 1 && f.minX >= 0
    }

    private static func symbol(for title: String) -> String? {
        let t = title.lowercased()
        let map: [(String, String)] = [
            ("wi", "wifi"), ("battery", "battery.75percent"), ("clock", "clock"),
            ("focus", "moon"), ("now playing", "play.fill"), ("audio and video", "video"),
            ("control center", "switch.2"), ("spotlight", "magnifyingglass"), ("bluetooth", "wave.3.right"),
            ("sound", "speaker.wave.2"), ("display", "sun.max"), ("user", "person.crop.circle"),
            ("input", "keyboard"), ("siri", "waveform"), ("screen mirroring", "rectangle.on.rectangle"),
        ]
        return map.first { t.hasPrefix($0.0) || t.contains($0.0 + " ") }?.1 ?? "circle.dashed"
    }

    static func frame(of el: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let v: AXValue = attr(el, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &origin) }
        if let v: AXValue = attr(el, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Whether some menu or popover is open on screen (used to re-hide icons afterwards).
enum MenuWatch {
    static func menuIsOpen(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) { return true }
            return owner == pid && layer > 0 && layer != Int(CGWindowLevelForKey(.statusWindow))
        }
    }
}
