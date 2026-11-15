import AppKit
import MacToolsKit

// Pure-logic checks (the family's stand-in for a test target): nothing is started, the Dock is untouched.
if CommandLine.arguments.contains("--self-check") {
    SearchRank.selfCheck()
    FileRank.selfCheck()
    SiteIcon.selfCheck()
    MainActor.assumeIsolated { ScreenshotsModel.selfCheck() }
    Migration.selfCheck()
    DockImport.selfCheck()
    print("self-check ok")
    exit(0)
}

// `Pier --find "acme app store"`: the file results the search panel would show, as paths.
if let flag = CommandLine.arguments.firstIndex(of: "--find"), let query = CommandLine.arguments.dropFirst(flag + 1).first {
    Task {
        let ranked = await FileQuery.ranked(query, usage: SearchUsage())
        for hit in ranked?.rows.prefix(25) ?? [] { print(hit.path) }
        print("\(ranked?.total ?? 0) results")
        exit(0)
    }
    dispatchMain()
}

if let flag = CommandLine.arguments.firstIndex(of: "--customize-preview") {
    let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated { CustomizePreview.run(into: folder) }
    exit(0)
}

// The search panel for real: opens it, drives it with key events sent to Pier only, saves two pictures, quits.
if let flag = CommandLine.arguments.firstIndex(of: "--ui-check") {
    let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        SearchPanelController.uiCheck(shots: folder)
        NSApplication.shared.run()
    }
}

Migration.run()   // before anything reads settings (SystemDock.hide needs savedSystemDock)

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

    /// Parked tab windows are off screen; put every one back before Pier goes.
    func applicationWillTerminate(_ notification: Notification) {
        dock?.tabs.unparkAll()
    }

    /// A plain kill (build.sh, Activity Monitor's Quit) quits properly too, so parked tabs come back.
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }
        termination?.resume()
        SystemDock.hide()
        // A Dock replacement should start at login. Turn it on once; after that the toggle is the user's.
        if !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
        }
        // Read before DockController writes the starter groups.json: no file and never onboarded = a new user.
        let firstRun = !UserDefaults.standard.bool(forKey: "onboarded") && !FileManager.default.fileExists(atPath: GroupsFile.url.path)
        if !firstRun { DockBadges.requestAccessOnce() }   // unread badges and raising one exact window; new users get the walkthrough's page
        dock = DockController()
        if firstRun, let dock { CustomizeWindow.show(dock.model, walkthrough: true) }
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
