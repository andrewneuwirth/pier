import AppKit
import CoreAudio
import Observation

/// What's making sound, and how to get back to it. Core Audio says which process is playing
/// (event-driven, no polling); AppleScript then names the track or finds the browser tab.
@MainActor @Observable
final class NowPlaying {
    enum Source: Equatable {
        case music(app: String)                                   // "Music", "Spotify"
        case chromeTab(app: String, window: String, tab: Int)     // Chrome-family dictionary
        case safariTab(window: String, tab: Int)
        case browser(app: String)                                 // no media-site tab matched
    }

    struct Item: Equatable {
        var source: Source
        var bundleID: String
        var title: String
        var subtitle: String
        var playing: Bool
    }

    private(set) var item: Item?

    // Core Audio bundle ids (often a helper's) → the app that owns the sound.
    private static let players: [(prefix: String, app: String, bundleID: String)] = [
        ("com.apple.Music", "Music", "com.apple.Music"),
        ("com.spotify.client", "Spotify", "com.spotify.client"),
        ("com.google.Chrome", "Google Chrome", "com.google.Chrome"),
        ("com.brave.Browser", "Brave Browser", "com.brave.Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge", "com.microsoft.edgemac"),
        ("com.apple.Safari", "Safari", "com.apple.Safari"),
        ("com.apple.WebKit", "Safari", "com.apple.Safari"),   // Safari plays through WebKit's GPU process
    ]

    @ObservationIgnored private var watched = Set<AudioObjectID>()
    @ObservationIgnored private var lookup: Task<Void, Never>?

    init() {
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        }
        audioChanged()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { if self?.item?.bundleID == id { self?.item = nil } }
            }
    }

    // MARK: Core Audio

    private func audioChanged() {
        let processes = Self.processes()
        // A process's "is playing" flag changes without the list changing: listen to each one.
        for process in processes where !watched.contains(process) {
            watched.insert(process)
            var running = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectAddPropertyListenerBlock(process, &running, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.audioChanged() }
            }
        }
        let playingIDs = processes.filter { Self.uint32(of: $0, kAudioProcessPropertyIsRunningOutput) == 1 }
            .compactMap { Self.string(of: $0, kAudioProcessPropertyBundleID) }
        let player = Self.players.first { p in playingIDs.contains { $0.hasPrefix(p.prefix) } }

        guard let player else {
            // Sound stopped: keep the last item, paused, so it can be resumed or revisited.
            if item?.playing == true { item?.playing = false }
            return
        }
        if item?.bundleID == player.bundleID, item?.playing == false { item?.playing = true }
        lookup?.cancel()
        lookup = Task { [weak self] in
            let found = await Self.describe(app: player.app, bundleID: player.bundleID)
            guard !Task.isCancelled, let found else { return }
            if self?.item != found { self?.item = found }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func uint32(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: AppleScript

    /// Sites whose tab is almost certainly the one making sound. Tabs are matched by URL, which the
    /// browsers share over AppleScript without "Allow JavaScript from Apple Events". That setting
    /// would let any app with Automation access run code in logged-in tabs, so Pier never needs it.
    private static let mediaHosts = ["youtube.com", "youtu.be", "spotify.com", "soundcloud.com", "twitch.tv",
                                     "netflix.com", "music.apple.com", "vimeo.com", "pandora.com", "tidal.com",
                                     "deezer.com", "primevideo.com", "disneyplus.com", "hulu.com", "max.com",
                                     "kick.com", "bandcamp.com", "audible.com", "podcasts.apple.com"]

    private static func describe(app: String, bundleID: String) async -> Item? {
        switch app {
        case "Music", "Spotify":
            guard let out = await osascript("""
                tell application "\(app)" to return (name of current track) & linefeed & (artist of current track)
                """) else { return nil }
            let lines = out.components(separatedBy: "\n")
            return Item(source: .music(app: app), bundleID: bundleID, title: lines.first ?? app,
                        subtitle: lines.dropFirst().first ?? app, playing: true)
        default:
            // One line per tab: window id, tab index, is-active, URL, title.
            let safari = app == "Safari"
            let out = await osascript("""
                set out to ""
                set sep to ASCII character 9 -- "tab" means a browser tab inside the tell block
                tell application "\(app)"
                  repeat with w in windows
                    set active to \(safari ? "index of current tab of w" : "active tab index of w")
                    set i to 0
                    repeat with t in tabs of w
                      set i to i + 1
                      set out to out & (id of w as text) & sep & i & sep & (i = active) & sep & (URL of t) & sep & (\(safari ? "name" : "title") of t) & linefeed
                    end repeat
                  end repeat
                end tell
                return out
                """) ?? ""
            let tabs = out.split(separator: "\n").map { $0.components(separatedBy: "\t") }.filter { $0.count >= 5 }
            let media = tabs.filter { t in
                let host = URL(string: t[3])?.host() ?? ""
                return mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            }
            // Several media tabs: the one showing in its window is the likeliest to be playing.
            guard let hit = media.first(where: { $0[2] == "true" }) ?? media.first, let index = Int(hit[1]) else {
                return Item(source: .browser(app: app), bundleID: bundleID, title: "Playing in \(app)",
                            subtitle: app, playing: true)
            }
            let source: Source = safari ? .safariTab(window: hit[0], tab: index)
                                        : .chromeTab(app: app, window: hit[0], tab: index)
            return Item(source: source, bundleID: bundleID, title: hit[4...].joined(separator: " "),
                        subtitle: app, playing: true)
        }
    }

    /// Brings the source forward: the tab when one was matched.
    func reveal() {
        guard let item else { return }
        switch item.source {
        case .music(let app), .browser(let app):
            run("tell application \"\(app)\" to activate")
        case .chromeTab(let app, let window, let tab):
            run("""
                tell application "\(app)"
                  set active tab index of window id \(window) to \(tab)
                  set index of window id \(window) to 1
                  activate
                end tell
                """)
        case .safariTab(let window, let tab):
            run("""
                tell application "Safari"
                  set current tab of window id \(window) to tab \(tab) of window id \(window)
                  set index of window id \(window) to 1
                  activate
                end tell
                """)
        }
    }

    /// The icon flips at once; for Music and Spotify their own answer then settles it (Music keeps its
    /// audio running a while after a pause, so the sound alone can't say).
    func playPause() {
        guard let item else { return }
        self.item?.playing.toggle()
        if case .music(let app) = item.source {
            control(app, "playpause")
        } else {
            // Browsers answer the system media keys (Media Session), so no code runs in the page.
            Self.pressMediaKey(16)   // NX_KEYTYPE_PLAY
        }
    }

    func next() { skip("next track", key: 17) }          // NX_KEYTYPE_NEXT
    func previous() { skip("previous track", key: 18) }  // NX_KEYTYPE_PREVIOUS

    private func skip(_ command: String, key: Int) {
        guard let item else { return }
        if case .music(let app) = item.source { control(app, command) } else { Self.pressMediaKey(key) }
    }

    /// Runs a command in Music or Spotify, then reads back what it's doing now.
    private func control(_ app: String, _ command: String) {
        Task {
            _ = await Self.osascript("tell application \"\(app)\" to \(command)")
            try? await Task.sleep(for: .milliseconds(250))
            guard let out = await Self.osascript("""
                tell application "\(app)" to return (player state as text) & linefeed & (name of current track) & linefeed & (artist of current track)
                """) else { return }
            let lines = out.components(separatedBy: "\n")
            guard var current = item, case .music(let now) = current.source, now == app else { return }
            current.playing = lines.first == "playing"
            if lines.count >= 3 { current.title = lines[1]; current.subtitle = lines[2] }
            if current != item { item = current }
        }
    }

    /// Where the song is, how long it is, and its artwork, for the hover card. Music and Spotify only.
    struct Details { var position: Double; var duration: Double; var artwork: NSImage? }

    func details() async -> Details? {
        guard let item, case .music(let app) = item.source else { return nil }
        let spotify = app == "Spotify"
        guard let out = await Self.osascript("""
            tell application "\(app)" to return (player position as text) & linefeed & (duration of current track as text)
            """) else { return nil }
        let numbers = out.components(separatedBy: "\n").map { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        guard numbers.count == 2 else { return nil }
        var details = Details(position: numbers[0], duration: spotify ? numbers[1] / 1000 : numbers[1], artwork: nil)
        if spotify {
            if let link = await Self.osascript("tell application \"Spotify\" to return artwork url of current track"),
               let url = URL(string: link), let (data, _) = try? await URLSession.shared.data(from: url) {
                details.artwork = NSImage(data: data)
            }
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pier-artwork")
            try? FileManager.default.removeItem(at: file)
            _ = await Self.osascript("""
                tell application "Music" to set art to raw data of artwork 1 of current track
                set f to open for access (POSIX file "\(file.path)") with write permission
                set eof f to 0
                write art to f
                close access f
                """)
            details.artwork = NSImage(contentsOf: file)
        }
        return details
    }

    /// A keyboard media key (⏯ ⏭ ⏮), as a system-defined event. Posting it needs Accessibility.
    private static func pressMediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func run(_ script: String) {
        Task { _ = await Self.osascript(script) }
    }

    /// osascript in a child process keeps a slow or hung app from ever blocking the bar.
    private static func osascript(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: proc.terminationStatus == 0 ? text : nil)
            }
            do { try p.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
