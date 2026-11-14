import AppKit
import Observation
import MacToolsKit

struct AppItem: Identifiable, Equatable {
    let url: URL
    let name: String
    let bundleID: String?
    var id: String { bundleID ?? url.path }

    init?(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.url = url
        bundleID = Bundle(url: url)?.bundleIdentifier
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    init(running app: NSRunningApplication, url: URL) {
        self.url = url
        bundleID = app.bundleIdentifier
        name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
    }
}

/// ~/Library/Application Support/Pier/groups.json. Hand-editable; Pier reloads it on save and
/// writes it when you pin, unpin or hide from a right-click menu.
struct GroupsFile: Codable {
    struct Group: Codable { var name: String; var apps: [String] }
    var groups: [Group]
    /// Bundle ids (or paths) of always-running apps kept out of the bar.
    var hidden: [String]?
    /// Icons picked in Pier (Change Icon…): app id → image file.
    var icons: [String: String]?
    /// Your own phone number or email, for Downloads › Text Myself. Kept here, not in the code.
    var myNumber: String?
    /// Quick Links, in order. (Perch's favorites were copied in when it was retired.)
    var links: [Link]?
    /// Old home of the Projects list; moved once into the shared ProjectLinks.file (see reloadGroups).
    var projectLinks: [Link]?
    /// title, url, and for project links the folder (`path`) and the command that starts its server (`start`).
    typealias Link = ProjectLink

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pier")
    static let url = folder.appendingPathComponent("groups.json")

    /// the owner's Dock as it was on 2026-10-13, sorted into groups.
    static let starter = GroupsFile(groups: [
        .init(name: "Code", apps: ["/Applications/Visual Studio Code.app", "/Applications/Xcode.app",
                                   "/Applications/Android Studio.app", "/System/Applications/Utilities/Terminal.app",
                                   "/Applications/Hangar.app", "/Applications/Projects.app"]),
        .init(name: "AI", apps: ["/Applications/Claude.app", "/Applications/ChatGPT.app"]),
        .init(name: "Web", apps: ["/Applications/Google Chrome.app", "/Applications/Safari.app"]),
        .init(name: "Personal", apps: ["/System/Applications/Notes.app", "/System/Applications/Photos.app",
                                       "/System/Applications/Calendar.app", "/System/Applications/Messages.app"]),
        .init(name: "System", apps: ["/System/Applications/System Settings.app"]),
    ])

    static func load() -> GroupsFile {
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(GroupsFile.self, from: data) {
            return file
        }
        // Missing: write the starter so there is something to edit. Unreadable (a typo mid-edit): keep
        // the file as the user left it and show the starter until it parses.
        if !FileManager.default.fileExists(atPath: url.path) { starter.save() }
        return starter
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }
}

@MainActor @Observable
final class DockModel {
    private(set) var groups: [[AppItem]] = []
    private(set) var groupNames: [String] = []
    private(set) var links: [GroupsFile.Link] = []
    private(set) var projectLinks: [GroupsFile.Link] = []

    /// Which list of links: the everyday Quick Links, or your projects' sites and servers.
    enum LinkKind { case quick, projects }

    func links(_ kind: LinkKind) -> [GroupsFile.Link] { kind == .quick ? links : projectLinks }

    private func store(_ list: [GroupsFile.Link], _ kind: LinkKind) {
        if kind == .quick { file.links = list; file.save() } else { ProjectLinks.save(list) }   // the watcher reloads
    }
    private(set) var running: [String: NSRunningApplication] = [:]   // by AppItem.id
    /// Open, unpinned, not hidden: the 4 used most recently get tiles; the rest sit behind "+N".
    private(set) var recent: [AppItem] = []
    private(set) var overflow: [AppItem] = []
    static let recentCount = 4
    private(set) var badges: [String: String] = [:]   // AppItem.id → "3"
    /// An app that wants you: warn = a Claude session is waiting on you, good = one finished while
    /// you were elsewhere. Shown as the tile's dot colour; "done" clears when you switch to the app.
    private(set) var attention: [String: MTStatus] = [:]
    /// Bumped to make a tile do its one gentle bounce.
    private(set) var bounces: [String: Int] = [:]
    /// "gtr-tone-app needs you", per app, for the hover card.
    private(set) var agentNotes: [String: [String]] = [:]
    /// Bumped when an app's chosen icon changes, so its tile redraws.
    private(set) var iconVersion = 0
    private(set) var memoryUsed: Double = 0      // bytes
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var usage: UsageSnapshot?
    /// Icon size; shrinks when the bar would be wider than the screen, as the macOS Dock does.
    var tileSize: CGFloat = maxTile
    nonisolated static let maxTile: CGFloat = 48, minTile: CGFloat = 24
    /// Set through DockController.setEdge, which also saves it.
    var edge = DockEdge.saved

    let finder = AppItem(path: "/System/Library/CoreServices/Finder.app")!

    @ObservationIgnored private var file = GroupsFile.starter
    @ObservationIgnored private var lastUsed: [String: Date] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var groupsWatch: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var lastStatus: [pid_t: String] = [:]
    @ObservationIgnored private let usagePoller = UsagePoller()

    init() {
        reloadGroups()
        refreshStats()
        usage = UsageSnapshot.read()
        usagePoller.onChange = { [weak self] in self?.usage = UsageSnapshot.read() }
        refreshBadges()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    // An app may have switched its Dock icon (ChatGPT's Dock icon setting) since we last looked.
                    if let app, let url = app.bundleURL, let self {
                        let item = AppItem(running: app, url: url)
                        if IconCache.changed(item, override: self.file.icons?[item.id]) { self.iconVersion += 1 }
                    }
                    if name == NSWorkspace.didActivateApplicationNotification, let id = app?.bundleIdentifier {
                        self?.lastUsed[id] = Date()
                        if self?.attention[id] == .good { self?.attention[id] = nil }   // you've seen it
                    }
                    self?.refreshRunning()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.thermal = ProcessInfo.processInfo.thermalState }
            })
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            // Badges every 10s: 30 feels late for a message. One AX read of the hidden Dock, no redraw unless a count changed.
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBadges() }
            },
            // Claude sessions every 3s: a handful of tiny files; nothing redraws unless a state changed.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAgents() }
            },
        ]
        watchGroupsFolder()
    }

    // MARK: Apps

    func isRunning(_ item: AppItem) -> Bool { running[item.id] != nil }
    func isPinned(_ item: AppItem) -> Bool { groups.contains { $0.contains(item) } }

    func reloadGroups() {
        file = GroupsFile.load()
        // The Projects list is shared with the Projects app now: move it out of groups.json once.
        if let old = file.projectLinks {
            if !FileManager.default.fileExists(atPath: ProjectLinks.file.path) { ProjectLinks.save(old) }
            file.projectLinks = nil
            file.save()
        }
        if links != file.links ?? [] { links = file.links ?? [] }
        if let shared = ProjectLinks.load(), shared != projectLinks { projectLinks = shared }   // unreadable: keep the last good list
        let loaded = file.groups.map { ($0.name, $0.apps.compactMap(AppItem.init(path:))) }.filter { !$0.1.isEmpty }
        groups = loaded.map(\.1)
        groupNames = file.groups.map(\.name)
        refreshRunning()
    }

    private func refreshRunning() {
        var map: [String: NSRunningApplication] = [:]
        var order: [(item: AppItem, launched: Date)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let url = app.bundleURL, app.processIdentifier != getpid() else { continue }
            let item = AppItem(running: app, url: url)
            if map[item.id] == nil { order.append((item, app.launchDate ?? .distantPast)) }
            map[item.id] = map[item.id] ?? app
        }
        running = map

        let pinned = Set(groups.flatMap { $0.map(\.id) } + [finder.id])
        let hidden = Set(file.hidden ?? [])
        let open = order.filter { !pinned.contains($0.item.id) && !hidden.contains($0.item.id) && !hidden.contains($0.item.url.path) }
            .sorted { $0.launched < $1.launched }
        // Pick the 4 most recently used, but show them in launch order so tiles don't jump on every switch.
        let picked = Set(open.sorted { (lastUsed[$0.item.id] ?? $0.launched) > (lastUsed[$1.item.id] ?? $1.launched) }
            .prefix(Self.recentCount).map(\.item.id))
        let newRecent = open.filter { picked.contains($0.item.id) }.map(\.item)
        let newOverflow = open.filter { !picked.contains($0.item.id) }.map(\.item)
        if newRecent != recent { recent = newRecent }
        if newOverflow != overflow { overflow = newOverflow }
    }

    func open(_ item: AppItem, files: [URL] = []) {
        let config = NSWorkspace.OpenConfiguration()
        if files.isEmpty, let app = running[item.id] {
            // Like the macOS Dock: every window of the app comes forward, not just the front one.
            app.activate(options: .activateAllWindows)
            // The reopen event makes a window only when the app has none; it never adds a second one.
            config.activates = false
            NSWorkspace.shared.openApplication(at: item.url, configuration: config)
        } else if files.isEmpty {
            NSWorkspace.shared.openApplication(at: item.url, configuration: config)
        } else {
            NSWorkspace.shared.open(files, withApplicationAt: item.url, configuration: config)
        }
    }

    func quit(_ item: AppItem) { running[item.id]?.terminate() }

    // Each edit saves groups.json; the folder watch reloads it, so the file stays the one source.

    func pin(_ item: AppItem, toGroup index: Int) {
        guard file.groups.indices.contains(index) else { return }
        unpinFromFile(item)
        file.groups[index].apps.append(item.url.path)
        file.save()
    }

    /// Drag to reorder: puts the app just before (or after) `target`, pinning it if it wasn't.
    /// Finder stays first, so Finder as the target means the front of the first group.
    func place(_ app: URL, relativeTo target: AppItem, after: Bool = false) {
        guard let moving = AppItem(path: app.path), moving.id != target.id else { return }
        unpinFromFile(moving)
        var spot: (group: Int, index: Int)?
        if target == finder {
            spot = file.groups.isEmpty ? nil : (0, 0)
        } else {
            for (g, group) in file.groups.enumerated() {
                if let i = group.apps.firstIndex(where: { AppItem(path: $0)?.id == target.id }) { spot = (g, i); break }
            }
        }
        guard let spot else { return }
        let index = target == finder ? 0 : spot.index + (after ? 1 : 0)
        file.groups[spot.group].apps.insert(moving.url.path, at: index)
        file.save()
    }

    func unpin(_ item: AppItem) {
        unpinFromFile(item)
        file.save()
    }

    /// Every app in /Applications whose bundle id starts with com.example., by name. Read each time
    /// the grid opens, so a newly installed tool shows up without restarting Pier.
    static func macTools() -> [AppItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return names.filter { $0.hasSuffix(".app") }
            .compactMap { AppItem(path: "/Applications/" + $0) }
            .filter { $0.bundleID?.hasPrefix("com.example.") == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func icon(for item: AppItem) -> NSImage {
        _ = iconVersion   // redraw when a chosen icon changes
        return IconCache.appIcon(item, override: file.icons?[item.id])
    }

    func hasCustomIcon(_ item: AppItem) -> Bool { file.icons?[item.id] != nil }

    func setIcon(_ image: URL?, for item: AppItem) {
        var icons = file.icons ?? [:]
        icons[item.id] = image?.path
        file.icons = icons.isEmpty ? nil : icons
        file.save()
        iconVersion += 1
    }

    func chooseIcon(for item: AppItem) {
        let panel = NSOpenPanel()
        panel.message = "Choose an icon for \(item.name)"
        panel.allowedContentTypes = [.image]
        NSApp.activate()   // Pier has no windows of its own; the panel needs it frontmost
        if panel.runModal() == .OK, let url = panel.url { setIcon(url, for: item) }
    }

    func addLink(_ url: URL, to kind: LinkKind = .quick) {
        let list = links(kind)
        guard url.scheme == "http" || url.scheme == "https", !list.contains(where: { $0.url == url.absoluteString }) else { return }
        let title = url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        store(list + [GroupsFile.Link(title: title, url: url.absoluteString)], kind)
    }

    /// The Links editor's Done: keeps rows with an address, adds https:// when it's missing.
    func setLinks(_ edited: [GroupsFile.Link], for kind: LinkKind = .quick) {
        var seen = Set<String>()
        let cleaned = edited.compactMap { link -> GroupsFile.Link? in
            var address = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return nil }
            if !address.contains("://") { address = "https://" + address }
            guard seen.insert(address).inserted else { return nil }
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return GroupsFile.Link(title: title.isEmpty ? (URL(string: address)?.host() ?? address) : title, url: address,
                                   path: link.path, start: link.start)
        }
        guard cleaned != links(kind) else { return }
        store(cleaned, kind)
    }

    func removeLink(_ link: GroupsFile.Link, from kind: LinkKind = .quick) {
        store(links(kind).filter { $0 != link }, kind)
    }

    func hide(_ item: AppItem) {
        file.hidden = (file.hidden ?? []) + [item.id]
        file.save()
    }

    private func unpinFromFile(_ item: AppItem) {
        for i in file.groups.indices {
            file.groups[i].apps.removeAll { AppItem(path: $0)?.id == item.id }
        }
    }

    /// groups.json's folder and the shared Projects list's folder (the Projects app writes it too).
    private func watchGroupsFolder() {
        let projects = ProjectLinks.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        groupsWatch = [GroupsFile.folder, projects].compactMap { folder in
            let fd = Darwin.open(folder.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            // Watch the folder, not the file: editors save by replacing the file.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadGroups() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    // MARK: Badges

    private func refreshBadges() {
        let fresh = DockBadges.read(matching: groups.flatMap { $0 } + recent + overflow + [finder])
        guard fresh != badges else { return }
        // A count that went up is something new: bounce, unless you're already in that app.
        for (id, label) in fresh where (Int(label) ?? 0) > (Int(badges[id] ?? "") ?? 0) && !isFrontmost(id) {
            bounce(id)
        }
        badges = fresh
    }

    // MARK: Agents

    private func refreshAgents() {
        let sessions = AgentWatch.read()
        var fresh = attention.filter { $0.value == .good }   // "done" stays until you visit the app
        var notes: [String: [String]] = [:]
        for s in sessions {
            let was = lastStatus[s.pid]
            if s.status == "waiting" {
                fresh[s.hostID] = .warn
                notes[s.hostID, default: []].append("\(s.name) needs you")
                if was != "waiting" { bounce(s.hostID) }
            } else if was == "busy" && s.status == "idle" && !isFrontmost(s.hostID) {
                if fresh[s.hostID] != .warn { fresh[s.hostID] = .good }
                notes[s.hostID, default: []].append("\(s.name) finished")
                bounce(s.hostID)
            }
        }
        // A waiting session that was answered leaves no "needs you" behind.
        for (id, status) in attention where status == .warn && !sessions.contains(where: { $0.hostID == id && $0.status == "waiting" }) {
            fresh[id] = nil
        }
        lastStatus = Dictionary(sessions.map { ($0.pid, $0.status) }, uniquingKeysWith: { a, _ in a })
        if fresh != attention { attention = fresh }
        for (id, list) in agentNotes where fresh[id] == .good && notes[id] == nil { notes[id] = list }   // keep "finished" text
        if notes != agentNotes { agentNotes = notes }
    }

    private func isFrontmost(_ id: String) -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id }

    private func bounce(_ id: String) { bounces[id, default: 0] += 1 }

    // MARK: Stats

    private func tick() {
        refreshStats()
        let fresh = UsageSnapshot.read()   // UsagePoller fetches every 5 min; this only picks up the file
        if fresh != usage { usage = fresh }   // setting an equal value would still redraw
    }

    private func refreshStats() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return }
        // Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressed.
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = Double(pages) * Double(vm_kernel_page_size)
        // Redraw only when the ring's whole-number percent changes, not on every byte of churn.
        if (used / memoryTotal * 100).rounded() != (memoryUsed / memoryTotal * 100).rounded() { memoryUsed = used }
    }
}

/// The screen edge the bar sits on (Position in the bar's menu). "Along" is the way the tiles run;
/// "across" points at the screen edge.
enum DockEdge: String, CaseIterable {
    case bottom, right

    static var saved: DockEdge { UserDefaults.standard.string(forKey: "edge").flatMap { DockEdge(rawValue: $0) } ?? .bottom }
    var title: String { rawValue.capitalized }

    func along(_ point: CGPoint) -> CGFloat { self == .bottom ? point.x : point.y }
    func along(_ size: CGSize) -> CGFloat { self == .bottom ? size.width : size.height }
    func across(_ size: CGSize) -> CGFloat { self == .bottom ? size.height : size.width }
}

/// Opens files the normal way, but folders in Burrow when it's installed: macOS always hands a plain folder open to Finder,
/// even with Burrow set as the folder handler.
enum FileOpener {
    static let burrow = URL(fileURLWithPath: "/Applications/Burrow.app")

    static func open(_ url: URL) {
        var dir: ObjCBool = false
        let isFolder = url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        if isFolder, FileManager.default.fileExists(atPath: burrow.path) {
            NSWorkspace.shared.open([url], withApplicationAt: burrow, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
