import AppKit
import MacToolsKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dock: DockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemDock.hide()
        // A Dock replacement should start at login. Turn it on once; after that the toggle is the user's.
        if !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
        }
        DockBadges.requestAccessOnce()   // unread badges and raising one exact window
        dock = DockController()
    }
}

/// Keeps the macOS Dock out of sight while Pier runs: auto-hide with a delay long enough that it
/// never slides in. The Dock process itself must stay alive (Mission Control, ⌘Tab and Spaces
/// live in it), so this is the only safe way to replace it.
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedKey = "savedSystemDock"

    static func hide() {
        // Remember the user's own settings once, so a crash and relaunch never saves Pier's values.
        if UserDefaults.standard.dictionary(forKey: savedKey) == nil {
            var saved: [String: Any] = [:]
            if let v = CFPreferencesCopyAppValue("autohide" as CFString, domain) { saved["autohide"] = v }
            if let v = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) { saved["autohide-delay"] = v }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        set(autohide: true as CFBoolean, delay: 1000 as CFNumber)
    }

    /// Puts back what the user had. Called only by Quit Pier, not on logout, so the macOS Dock
    /// doesn't flash up at every login before Pier starts.
    static func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(autohide: saved["autohide"] as CFPropertyList?, delay: saved["autohide-delay"] as CFPropertyList?)
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func set(autohide: CFPropertyList?, delay: CFPropertyList?) {
        CFPreferencesSetAppValue("autohide" as CFString, autohide, domain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, delay, domain)
        CFPreferencesAppSynchronize(domain)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]   // relaunches by itself and rereads its settings
        try? p.run()
        p.waitUntilExit()
    }
}
