import AppKit
import Carbon.HIToolbox
import Observation

/// Where Search looks: the tabs at the top of the results, ⌘1 to ⌘4 (All has none: press the open tab's again).
enum SearchScope: Int, CaseIterable {
    case all, applications, files, downloads, screenshots

    var tab: String { ["All", "Apps", "Files", "Downloads", "Screenshots"][rawValue] }
    var shortcut: String { rawValue == 0 ? "" : "⌘\(rawValue)" }
}

/// A row in the search panel: an app, setting or link from the index, or a file (screenshots included).
enum SearchItem: Identifiable, Equatable {
    case entry(SearchEntry), file(FileHit)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .file(let hit): "file:" + hit.path
        }
    }
    var url: URL {
        switch self {
        case .entry(let entry): entry.target
        case .file(let hit): URL(fileURLWithPath: hit.path)
        }
    }
}

/// Search's state: the index of installed apps and System Settings panes (built off the main thread
/// at launch and again when an Applications folder changes), what is typed, where to look, and which row
/// is selected. Each keystroke only ranks the list already in memory (SearchRank, in AppSearch.swift);
/// files come from Spotlight beside it.
@MainActor @Observable
final class AppSearch {
    enum Phase { case indexing, ready }
    private(set) var phase = Phase.indexing
    /// The file search for what is typed. It runs beside the instant results and lands when Spotlight answers.
    enum FilePhase: Equatable { case idle, searching, results([FileHit], total: Int), failed }
    private(set) var files = FilePhase.idle
    var query = "" {
        didSet {
            selection = 0
            navigated = false
            searchFiles()
        }
    }
    var scope = SearchScope.all {
        didSet {
            guard scope != oldValue else { return }
            selection = 0
            files = .idle   // the old scope's files don't belong to the new one
            searchFiles()
        }
    }
    private(set) var selection = 0
    /// The arrow keys have moved the selection since the last keystroke: Space then previews instead of typing.
    private(set) var navigated = false
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    private var indexed: [SearchEntry] = []
    @ObservationIgnored private let model: DockModel
    @ObservationIgnored private let downloads: DownloadsModel
    @ObservationIgnored let screenshots = ScreenshotsModel()
    @ObservationIgnored private var usage = SearchUsage.load()
    @ObservationIgnored private var watches: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(model: DockModel, downloads: DownloadsModel) {
        self.model = model
        self.downloads = downloads
    }

    func start() {
        reindex(after: .zero)
        // The folders apps are installed into (the system's own never change while running).
        for folder in AppIndexer.folders.prefix(3) {
            let fd = Darwin.open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            // An install writes many times: wait for it to settle.
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reindex(after: .seconds(2)) } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watches.append(source)
        }
    }

    private func reindex(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let fresh = await Task.detached(priority: .userInitiated) { AppIndexer.scan() }.value
            guard !Task.isCancelled, let self else { return }
            self.indexed = fresh
            self.phase = .ready
        }
    }

    /// Best first: apps and settings from the index plus Pier's Quick Links and Projects, or apps only.
    private func entries(limit: Int) -> [SearchEntry] {
        let pool = scope == .applications ? indexed.filter { $0.kind == .app } : indexed + links(.quick) + links(.projects)
        return SearchRank.rank(query, pool, usage: usage, running: Set(model.running.keys), limit: limit)
    }

    var fileHits: [FileHit] {
        if case .results(let hits, _) = files { hits } else { [] }
    }

    struct Section: Identifiable {
        let title: String
        let items: [SearchItem]
        var id: String { title }
    }

    /// What the panel lists, grouped by kind, in the order the arrow keys walk it. Nothing typed: suggested apps,
    /// the ones you launch from Search most and open ones first (or the newest downloads, or screenshots). Typed: the top hit, the other apps, settings and links
    /// (at most 3 of them once files come in), then the files.
    var sections: [Section] {
        let typed = !FileRank.words(query).isEmpty
        switch scope {
        case .screenshots:
            let shots = ScreenshotsModel.filter(screenshots.items, query: query)
            return shots.isEmpty ? [] : [Section(title: "Screenshots · \(shots.count)", items: shots.map(SearchItem.file))]
        case .all where !typed, .applications where !typed:
            return [Section(title: "Suggestions", items: entries(limit: 8).map(SearchItem.entry))]
        case .files where !typed:
            return []
        case .downloads where !typed:
            let newest = downloads.items.prefix(12).map { FileHit(path: $0.url.path, isFolder: $0.url.hasDirectoryPath, date: $0.added) }
            return [Section(title: "Newest", items: newest.map(SearchItem.file))]
        default:
            var out: [Section] = []
            if scope == .all || scope == .applications {
                var found = entries(limit: 8)
                if !fileHits.isEmpty { found = Array(found.prefix(3)) }
                if scope == .all, let first = found.first {
                    out.append(Section(title: "Top Hit", items: [.entry(first)]))
                    found.removeFirst()
                }
                let groups: [(SearchEntry.Kind, String)] = [(.app, "Applications"), (.setting, "System Settings"),
                                                            (.link, "Quick Links"), (.project, "Projects")]
                for (kind, title) in groups {
                    let rows = found.filter { $0.kind == kind }
                    if !rows.isEmpty { out.append(Section(title: title, items: rows.map(SearchItem.entry))) }
                }
            }
            if case .results(let hits, let total) = files, !hits.isEmpty {
                let count = total > hits.count ? "Best \(hits.count) of \(total)" : "\(total)"
                out.append(Section(title: (scope == .downloads ? "Downloads" : "Files") + " · " + count, items: hits.map(SearchItem.file)))
            }
            return out
        }
    }

    /// Every row, in the order the arrow keys walk them.
    var items: [SearchItem] { sections.flatMap(\.items) }

    var selected: SearchItem? {
        let items = items
        return items.indices.contains(selection) ? items[selection] : nil
    }

    func move(_ delta: Int) {
        selection = min(max(selection + delta, 0), max(items.count - 1, 0))
        navigated = true
    }

    /// Opens it and remembers the choice for what was typed; `reveal` shows a file in Finder instead.
    func open(_ item: SearchItem, reveal: Bool) {
        let url = item.url
        if reveal, url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        // A file is remembered by its path, which is what FileRank looks it up by.
        if case .file(let hit) = item { usage.record(hit.path, query: query) } else { usage.record(item.id, query: query) }
        usage.save()
        if case .entry(let entry) = item, entry.kind == .app, let app = AppItem(path: entry.target.path) {
            model.open(app)   // as a click on its tile: every window comes forward
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Two letters or more: wait for a pause in typing, ask Spotlight off the main thread, and show the answer
    /// only if nothing newer was typed meanwhile (the newer keystroke cancelled this task).
    private func searchFiles() {
        fileTask?.cancel()
        let query = query, words = FileRank.words(query), usage = usage
        guard scope != .applications, scope != .screenshots, words.joined().count >= 2 else { files = .idle; return }
        let folder = scope == .downloads ? DownloadsModel.folder.path : nil
        // Until Spotlight answers, the rows already showing that still fit stay, so the list doesn't blink per letter.
        let still = fileHits.filter { hit in words.allSatisfy { hit.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        files = still.isEmpty ? .searching : .results(still, total: still.count)
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let ranked = await FileQuery.ranked(query, in: folder, usage: usage)
            guard !Task.isCancelled, let self else { return }
            self.files = ranked.map { .results($0.rows, total: $0.total) } ?? .failed
        }
    }

    private func links(_ kind: DockModel.LinkKind) -> [SearchEntry] {
        model.links(kind).compactMap { link in
            guard let url = URL(string: link.url) else { return nil }
            let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
            let place = ["127.0.0.1", "localhost"].contains(host) ? "localhost:\(url.port ?? 80)" : host
            return SearchEntry(id: (kind == .quick ? "link:" : "project:") + link.url, kind: kind == .quick ? .link : .project,
                               name: link.title, aliases: [host], detail: kind == .quick ? place : "Project · \(place)",
                               target: url, projectPath: link.path)
        }
    }
}

/// Reads what is installed. Called off the main thread; touches nothing shared.
enum AppIndexer {
    static let systemSettings = "/System/Applications/System Settings.app"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The first three are the ones watched for installs.
    static let folders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                          URL(fileURLWithPath: "/Applications/Utilities"), URL(fileURLWithPath: "/System/Applications"),
                          URL(fileURLWithPath: "/System/Applications/Utilities"),
                          URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]

    static func scan() -> [SearchEntry] {
        var seen = Set<String>(), out: [SearchEntry] = []
        func add(_ url: URL) {
            guard let entry = app(url), seen.insert(entry.id).inserted else { return }
            out.append(entry)
        }
        func contents(_ folder: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        // shortcut: one folder deep ("/Applications/Adobe Photoshop 2025/…app"), and an install inside
        // such a folder is only picked up at the next change to its parent; go deeper if an app is missed.
        for folder in folders {
            for url in contents(folder) {
                if url.pathExtension == "app" { add(url) } else if url.hasDirectoryPath { contents(url).filter { $0.pathExtension == "app" }.forEach(add) }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        spotlightApps().forEach(add)   // after the usual folders, so an installed app wins over a build of it
        return out + settings()
    }

    private static func app(_ url: URL) -> SearchEntry? {
        guard let bundle = Bundle(url: url) else { return nil }
        let file = url.deletingPathExtension().lastPathComponent
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let info = bundle.infoDictionary ?? [:]
        let aliases = [file, info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String,
                       bundle.bundleIdentifier?.components(separatedBy: ".").last].compactMap { $0 }
        // Where it is, only when that isn't one of the usual places.
        let parent = url.deletingLastPathComponent().path
        let usual = parent.hasPrefix("/Applications") || parent.hasPrefix("/System/")
        return SearchEntry(id: bundle.bundleIdentifier ?? url.path, kind: .app, name: name, aliases: aliases,
                           detail: usual ? "" : (parent as NSString).abbreviatingWithTildeInPath, target: url)
    }

    /// Apps Spotlight knows of elsewhere in your home folder (Downloads, Desktop, your own builds).
    /// One quick `mdfind`; nothing when Spotlight is off.
    private static func spotlightApps() -> [URL] {
        let find = Process(), pipe = Pipe()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        find.arguments = ["-onlyin", home.path, "kMDItemContentType == 'com.apple.application-bundle'"]
        find.standardOutput = pipe
        find.standardError = FileHandle.nullDevice
        guard (try? find.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        find.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            // Not helpers inside other apps, caches, hidden folders, or Xcode's build products and archives.
            .filter { path in ![".app/", "/Library/", "/.", "/Build/", ".xcarchive/"].contains { path.contains($0) } }
            .map { URL(fileURLWithPath: $0) }
    }

    /// System Settings panes: the Settings extensions the system ships, opened by their bundle id.
    private static func settings() -> [SearchEntry] {
        let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".appex") }.compactMap { file -> SearchEntry? in
            guard let info = NSDictionary(contentsOf: folder.appendingPathComponent(file).appendingPathComponent("Contents/Info.plist")),
                  (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  let id = info["CFBundleIdentifier"] as? String, let url = URL(string: "x-apple.systempreferences:\(id)") else { return nil }
            let raw = [info["CFBundleDisplayName"] as? String ?? "", info["CFBundleName"] as? String ?? ""]
            let (name, aliases) = settingName(id: id, raw: raw)
            return SearchEntry(id: "setting:" + id, kind: .setting, name: name, aliases: aliases, detail: "System Settings", target: url)
        }
    }

    /// The panes' own names are uneven ("Language & Region", "LockScreen", "PowerPreferences", none at all),
    /// so: a name that reads as one, else the bundle id's ("com.apple.Battery-Settings.extension" → Battery),
    /// else what is left of a name without its "Settings"/"Extension" ending. The rest still match as other names.
    static func settingName(id: String, raw: [String]) -> (name: String, aliases: [String]) {
        let junk = ["Settings", "Setting", "Extension", "Preferences", "Pane"]
        func spaced(_ name: String) -> String {
            name.contains(" ") || name.contains("-") ? name : name.replacing(#/([a-z])([A-Z])/#) { "\($0.1) \($0.2)" }
        }
        let fromID = id.components(separatedBy: ".").first { $0.hasSuffix("-Settings") }
            .map { spaced($0.dropLast("-Settings".count).replacingOccurrences(of: "-", with: " ")) }
        let clean = raw.first { name in !name.isEmpty && !junk.contains { name.contains($0) } }.map(spaced)
        let stripped = raw.map { name in
            spaced(junk.reduce(name) { $0.replacingOccurrences(of: $1, with: "") }.trimmingCharacters(in: .whitespaces))
        }
        let name = clean ?? fromID ?? stripped.first { !$0.isEmpty } ?? id
        return (name, stripped + [fromID ?? ""])
    }
}

/// The search panel: Spotlight-style, centred near the top of the main screen. The Search tile and the
/// hot keys open it; the keys below work while it is open.
@MainActor
final class SearchPanelController {
    let search: AppSearch
    let popup = Popup(interactive: true)
    private let model: DockModel
    private let preview = FilePreview()

    init(model: DockModel, downloads: DownloadsModel) {
        self.model = model
        search = AppSearch(model: model, downloads: downloads)
        search.start()
        search.screenshots.startRescue()
        popup.onClose = { [weak self] in
            self?.preview.close()
            self?.search.screenshots.stop()   // no folder watch while the panel is closed
        }
        // Local, like the popup's own Esc: Pier holds the keyboard while the panel is open.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.key(event) ?? false } ? nil : event
        }
    }

    var isVisible: Bool { popup.isVisible }

    func toggle() {
        // A click on the Search tile closes the panel on mouse-down (it's outside it); that same click mustn't reopen it.
        if popup.isVisible || Date().timeIntervalSince(popup.closedAt) < 0.3 {
            popup.close()
            return
        }
        search.scope = .all
        search.query = ""
        search.screenshots.start()
        popup.show(SearchPanel(search: search, model: model, open: { [weak self] in self?.activate($0, reveal: false) },
                               dropped: { [weak self] in self?.popup.close() }),
                   from: nil, edge: .bottom)
    }

    /// Up and Down move the selection (a row of the grid in the Screenshots tab, where Left and Right move one), Return
    /// opens it, Command-Return shows it in Finder. Command-1 to 4 pick a tab (again for All), and Delete in an empty
    /// field goes back to All. Space previews the selected file once the arrows have moved to it (before that, Space is
    /// part of what you type); so does Command-Y.
    private func key(_ event: NSEvent) -> Bool {
        guard popup.isVisible else { return false }
        let command = event.modifierFlags.contains(.command)
        let grid = search.scope == .screenshots
        // ⌘C in the Screenshots tab copies the picture itself, unless there is text selected in the field.
        if grid, command, event.charactersIgnoringModifiers == "c", case .file(let hit) = search.selected,
           (popup.window.firstResponder as? NSTextView)?.selectedRange().length ?? 0 == 0 {
            ScreenshotsModel.copy(hit)
            return true
        }
        // Pier has no Edit menu (agent app), so the standard text shortcuts are sent to the field by hand.
        if command, let edit = ["a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
                                "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
                                "z": Selector(("undo:"))][event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            return NSApp.sendAction(edit, to: nil, from: nil)
        }
        switch event.keyCode {
        case 123...124 where grid:   // ← →
            search.move(event.keyCode == 124 ? 1 : -1)
            if preview.isOpen, case .file(let hit) = search.selected { preview.show(URL(fileURLWithPath: hit.path)) }
        case 125, 126:
            search.move((event.keyCode == 125 ? 1 : -1) * (grid ? ScreenshotGrid.columns : 1))
            if preview.isOpen, case .file(let hit) = search.selected { preview.show(URL(fileURLWithPath: hit.path)) }
        case 36, 76:
            if let item = search.selected { activate(item, reveal: command) }
        case 18...21 where command:   // 1, 2, 3, 4
            let scope = SearchScope(rawValue: Int(event.keyCode) - 17) ?? .all
            search.scope = search.scope == scope ? .all : scope
        case 51 where search.query.isEmpty && search.scope != .all:   // Delete
            search.scope = .all
        case 49, 16:   // Space, Y
            // Space types a space until the arrows pick something, except in the Screenshots tab with nothing typed.
            let pick = search.navigated || preview.isOpen || (grid && search.query.isEmpty)
            guard event.keyCode == 49 ? pick : command else { return false }
            if preview.isOpen { preview.close() } else if case .file(let hit) = search.selected { preview.show(URL(fileURLWithPath: hit.path)) }
        default: return false
        }
        return true
    }

    /// Closed first, without handing the keyboard back, since what opens next takes it.
    private func activate(_ item: SearchItem, reveal: Bool) {
        popup.close(restoreFocus: false)
        search.open(item, reveal: reveal)
    }

    /// `Pier --ui-check [folder]`: opens the real panel (no bar, nothing else started), drives it with key events sent
    /// to Pier alone, checks it, saves two pictures of it into the folder, and quits. It takes the keyboard for about
    /// five seconds and gives it back.
    static func uiCheck(shots folder: String) {
        let controller = SearchPanelController(model: DockModel(), downloads: DownloadsModel())
        let search = controller.search, window = controller.popup.window
        func key(_ code: UInt16, _ characters: String, command: Bool = false) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        func shot(_ name: String) {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", folder + "/" + name + ".png"]
            try? capture.run()
            capture.waitUntilExit()
            print(capture.terminationStatus == 0 ? "saved \(folder)/\(name).png" : "could not save \(name).png (Screen Recording?)")
        }
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
        }
        func waitForIndex() {
            guard search.phase == .ready else { return after(0.2, waitForIndex) }
            controller.toggle()
            after(1.2) {
                let screen = (NSScreen.main ?? NSScreen.screens[0]).frame, frame = window.frame
                check("opens centred on the main screen, top in its upper third",
                      abs(frame.midX - screen.midX) <= 1 && frame.maxY < screen.maxY && frame.maxY > screen.maxY - screen.height / 3)
                check("focus lands in the field", window.isKeyWindow && (window.firstResponder as? NSTextView)?.isFieldEditor == true)
                check("nothing typed: suggested apps", search.sections.first?.title == "Suggestions")
                shot("search-empty")
                key(19, "2", command: true)
            }
            after(1.6) {
                check("⌘2 looks in Files", search.scope == .files)
                key(18, "1", command: true)
            }
            after(2.0) {
                check("⌘1 looks in Applications, and lists only apps", search.scope == .applications
                      && search.items.allSatisfy { if case .entry(let e) = $0 { e.kind == .app } else { false } })
                key(18, "1", command: true)
            }
            after(2.4) {
                check("⌘1 again looks everywhere", search.scope == .all)
                for ch in "transcript" { key(0, String(ch)) }   // the field takes the characters; the key code doesn't matter
            }
            after(4.2) {
                check("typing reaches the field", search.query == "transcript")
                check("results are grouped, files last", search.sections.last?.title.hasPrefix("Files") == true)
                shot("search-results")
                key(53, "\u{1b}")   // Escape
            }
            after(4.6) {
                check("Escape closes it", !controller.isVisible)
                print("ui-check ok")
                exit(0)
            }
        }
        waitForIndex()
    }
}

/// Option-Space and Command-Space from anywhere. Carbon hot keys: no Accessibility needed, and the key press
/// is not typed. Command-Space stays Spotlight's while its shortcut is on in System Settings (that is read,
/// never changed); Option-Space works either way.
@MainActor
enum SearchHotkey {
    private static var action: (() -> Void)?
    private static var keys: [EventHotKeyRef] = []

    static func register(_ run: @escaping () -> Void) {
        action = run
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { SearchHotkey.action?() }
            return noErr
        }, 1, &pressed, nil, nil)
        for (id, (modifiers, name)) in [(optionKey, "Option-Space"), (cmdKey, "Command-Space")].enumerated() {
            var key: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(modifiers), EventHotKeyID(signature: 0x50494552, id: UInt32(id + 1)),   // "PIER"
                                             GetApplicationEventTarget(), 0, &key)
            if status == noErr, let key { keys.append(key) } else { NSLog("Pier: \(name) is not available for Search (\(status))") }
        }
        // Outside trigger (Hammerspoon maps a mouse button to it): no faked keys, so held modifiers can't spoil it.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.example.pier.search"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SearchHotkey.action?() }
        }
        // The same, for pasting the newest screenshot into whatever app is in front.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.example.pier.pasteScreenshot"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenshotsModel.pasteNewest() }
        }
        if spotlightHasCommandSpace {
            NSLog("Pier: Command-Space opens Spotlight while its shortcut is on (System Settings › Keyboard › Keyboard Shortcuts › Spotlight); Option-Space opens Search")
        }
    }

    /// Spotlight's "Show Spotlight search" shortcut (symbolic hot key 64) is on unless it was turned off.
    static var spotlightHasCommandSpace: Bool {
        let keys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return (keys?["64"] as? [String: Any])?["enabled"] as? Bool ?? true
    }
}
