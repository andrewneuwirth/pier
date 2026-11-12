import AppKit
import Carbon.HIToolbox
import Observation
import QuickLookThumbnailing

/// Search's Screenshots tab: the newest screenshots and screen recordings from the folder macOS saves them to,
/// kept live only while the search panel is open (a folder watch, no polling), with cached Quick Look thumbnails.
/// Also the rescue: a capture dragged out of macOS's floating preview is never saved, only left in a temporary
/// folder; Pier watches for those all the time and copies each one into the screenshot folder once its preview is gone.
@MainActor @Observable
final class ScreenshotsModel {
    nonisolated static let limit = 80
    private(set) var items: [FileHit] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var watched = ""
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var tempWatch: FSEventStreamRef?
    /// The self-check points these at temporary folders.
    @ObservationIgnored var folderOverride: String?
    @ObservationIgnored var temporaryRootOverride: String?

    var folder: String { folderOverride ?? Self.folder() }

    /// Fresh list, then watch the folder until `stop`. Called each time the panel opens.
    func start() {
        let folder = folder
        refresh(folder)
        guard watch == nil || watched != folder else { return }
        stop()
        let fd = Darwin.open(folder, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        // macOS writes a hidden file first and renames it a moment later; wait for that to settle.
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                self.pending = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self else { return }
                    self.refresh(self.folder)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = source
        watched = folder
    }

    /// The panel closed: nothing runs until it opens again.
    func stop() {
        pending?.cancel()
        watch?.cancel()
        watch = nil
    }

    private func refresh(_ folder: String) {
        let fresh = Self.merge(saved: Self.list(in: folder), temporary: Self.temporaryCaptures(root: temporaryRootOverride ?? Self.temporaryRoot))
        if fresh != items { items = fresh }
    }

    /// Watches macOS's temporary capture folders for as long as Pier runs (one recursive FSEvents stream, which costs
    /// nothing while nothing happens there). Each new capture shows in the tab at once if the panel is open, and is
    /// copied into the screenshot folder if macOS never saves it.
    func startRescue() {
        guard tempWatch == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let model = Unmanaged<ScreenshotsModel>.fromOpaque(info).takeUnretainedValue()
            let captures = paths.prefix(count).filter(ScreenshotsModel.isTemporaryCapture)
            guard !captures.isEmpty else { return }
            MainActor.assumeIsolated { model.temporaryCaptured(Set(captures)) }
        }, &context, [Self.temporaryRoot] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        tempWatch = stream
    }

    private func temporaryCaptured(_ paths: Set<String>) {
        if watch != nil { refresh(folder) }   // the panel is open: show it now
        for path in paths where FileManager.default.fileExists(atPath: path) { rescueLater(path, tries: 0) }
    }

    /// About 10 s on, and again every 5 s while a capture preview is still on screen (macOS may yet save it), for up to
    /// two minutes: copy it if the folder still has no file of that name.
    private func rescueLater(_ path: String, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 10 : 5)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: path) else { return }
                if Self.previewShowing(), tries < 22 { return self.rescueLater(path, tries: tries + 1) }
                if Self.rescue(path, into: self.folder) { NSLog("Pier: kept a dragged-out screenshot: \((path as NSString).lastPathComponent)") }
            }
        }
    }

    /// macOS's floating capture preview is on screen (window owner names need no Screen Recording permission).
    private static func previewShowing() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "screencaptureui" }
    }

    /// The mouse button's paste: the newest capture from the last 10 minutes (one still in its preview included) goes on
    /// the clipboard, as ⌘C does, and ⌘V is sent to the app in front. Nothing that recent: a beep.
    static func pasteNewest() {
        // The temporary captures are only readable with Full Disk Access (macOS marks those folders com.apple.macl).
        guard let newest = freshest(merge(saved: list(in: folder()), temporary: temporaryCaptures()), now: Date()) else {
            NSSound.beep()
            return
        }
        copy(newest)
        guard AXIsProcessTrusted() else {
            NSLog("Pier: the screenshot is on the clipboard, but pasting it needs Accessibility for Pier (System Settings › Privacy & Security)")
            return
        }
        // The mouse button arrives as Control-Command-J: wait (up to 0.5 s) for its Control to let go, then send a full
        // Command down, V, Command up; many apps (Chrome, Electron) ignore a lone V that only carries the Command flag.
        func send(waited: Double = 0) {
            if CGEventSource.flagsState(.hidSystemState).contains(.maskControl), waited < 0.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(waited: waited + 0.05) }
                return
            }
            // Terminals paste only text; Claude Code in a terminal attaches the clipboard image on Control-V instead.
            let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                          "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"]
            let inTerminal = terminals.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            let (modifier, flag): (Int, CGEventFlags) = inTerminal ? (kVK_Control, .maskControl) : (kVK_Command, .maskCommand)
            let source = CGEventSource(stateID: .combinedSessionState)
            for (code, down) in [(modifier, true), (kVK_ANSI_V, true), (kVK_ANSI_V, false), (modifier, false)] {
                let key = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
                key?.flags = down || code == kVK_ANSI_V ? flag : []
                key?.post(tap: .cgSessionEventTap)
            }
        }
        send()
    }

    /// A thumbnail drawn at the size it is shown, asked once per file and kept; the file's icon until it arrives.
    /// (Called while the grid draws, so nothing observed changes here; the answer lands on the next turn.)
    func thumbnail(_ hit: FileHit, size: CGSize) -> NSImage {
        if let image = thumbnails[hit.path] { return image }
        guard asked.insert(hit.path).inserted else { return IconCache.icon(hit.path) }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: hit.path), size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnails[hit.path] = image } }
        }
        return IconCache.icon(hit.path)
    }

    /// The image itself on the clipboard (plus the file), so it pastes into a chat as a picture.
    static func copy(_ hit: FileHit) {
        let url = URL(fileURLWithPath: hit.path)
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            board.setData(data, forType: .png)
        } else if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            board.setData(tiff, forType: .tiff)
        }
    }

    // MARK: Pure

    /// Where macOS keeps a capture while its floating preview shows: TemporaryItems/NSIRD_screencaptureui_…/
    nonisolated static let temporaryRoot = NSTemporaryDirectory() + "TemporaryItems"

    nonisolated static func isTemporaryCapture(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2].hasPrefix("NSIRD_screencaptureui_") else { return false }
        return isCapture(String(parts[parts.count - 1]), marked: true)
    }

    /// The captures still in macOS's temporary folders, newest first.
    nonisolated static func temporaryCaptures(root: String = temporaryRoot) -> [FileHit] {
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("NSIRD_screencaptureui_") }
        return folders.flatMap { list(in: root + "/" + $0, limit: 50, marked: { _ in true }) }
            .sorted { ($0.date ?? .distantPast, $1.path) > ($1.date ?? .distantPast, $0.path) }
    }

    /// Both places as one list, newest first; a capture in both (same name) is listed once, as the saved one.
    nonisolated static func merge(saved: [FileHit], temporary: [FileHit], limit: Int = limit) -> [FileHit] {
        let names = Set(saved.map(\.name))
        return (saved + temporary.filter { !names.contains($0.name) })
            .sorted { ($0.date ?? .distantPast, $1.path) > ($1.date ?? .distantPast, $0.path) }
            .prefix(limit).map { $0 }
    }

    /// The newest capture, if it was taken in the last `within` seconds.
    nonisolated static func freshest(_ hits: [FileHit], now: Date, within: TimeInterval = 600) -> FileHit? {
        guard let newest = hits.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }),
              let date = newest.date, now.timeIntervalSince(date) <= within else { return nil }
        return newest
    }

    /// Copies a capture macOS left behind into the screenshot folder, keeping when it was taken. Never a second
    /// copy: a file of that name already there (macOS saved its own, or this ran before) means nothing to do.
    @discardableResult
    nonisolated static func rescue(_ path: String, into folder: String) -> Bool {
        let target = folder + "/" + (path as NSString).lastPathComponent
        let files = FileManager.default
        guard files.fileExists(atPath: path), !files.fileExists(atPath: target), (try? files.copyItem(atPath: path, toPath: target)) != nil
        else { return false }
        if let taken = (try? files.attributesOfItem(atPath: path))?[.creationDate] {
            try? files.setAttributes([.creationDate: taken], ofItemAtPath: target)
        }
        return true
    }

    /// Where screenshots are saved: `defaults read com.apple.screencapture location`, else the Desktop (as macOS does).
    nonisolated static func folder(location: String? = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
                                   home: String = NSHomeDirectory(),
                                   exists: (String) -> Bool = { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue }) -> String {
        if let location, !location.isEmpty {
            let path = location.hasPrefix("~") ? home + location.dropFirst() : location
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if exists(trimmed) { return trimmed }
        }
        return home + "/Desktop"
    }

    /// A screenshot or screen recording: a picture or movie that macOS named as one, or marked as a screen capture
    /// (the mark survives renaming). Everything else in the folder, such as other pictures on the Desktop, is left out.
    nonisolated static func isCapture(_ name: String, marked: Bool) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf", "mov", "mp4"].contains(ext), !name.hasPrefix(".") else { return false }
        return marked || ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot"].contains { name.hasPrefix($0) }
    }

    /// Newest first, by when each was taken.
    nonisolated static func list(in folder: String, limit: Int = limit, marked: (String) -> Bool = marked) -> [FileHit] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                                  options: .skipsHiddenFiles)) ?? []
        return urls.filter { isCapture($0.lastPathComponent, marked: marked($0.path)) }
            .map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return FileHit(path: url.path, date: v?.creationDate ?? v?.contentModificationDate)
            }
            .sorted { ($0.date ?? .distantPast, $1.path) > ($1.date ?? .distantPast, $0.path) }
            .prefix(limit).map { $0 }
    }

    /// The screen-capture mark macOS puts on the file (an extended attribute: one cheap read, no Spotlight query).
    nonisolated private static func marked(_ path: String) -> Bool {
        getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// Typing narrows by name or by the day it shows ("today", "yesterday", "nov 3").
    nonisolated static func filter(_ hits: [FileHit], query: String, now: Date = Date()) -> [FileHit] {
        let words = FileRank.words(query)
        guard !words.isEmpty else { return hits }
        return hits.filter { hit in
            let text = (hit.name + " " + (hit.date.map { FileRank.when($0, now: now) } ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    // MARK: Self-check

    /// Folder resolution, which files count, the order, the filter, and a screenshot showing up live.
    static func selfCheck() {
        let home = "/Users/me"
        check("screenshots: the saved location, with ~ expanded",
              folder(location: "~/Pictures/Screenshots/", home: home, exists: { $0 == home + "/Pictures/Screenshots" }) == home + "/Pictures/Screenshots")
        check("screenshots: a location that is gone, or none, falls back to the Desktop",
              folder(location: "/Volumes/Gone", home: home, exists: { _ in false }) == home + "/Desktop"
                && folder(location: nil, home: home, exists: { _ in true }) == home + "/Desktop")
        check("screenshots: named or marked captures count; other pictures and files don't",
              isCapture("Screenshot 2026-11-12 at 3.25.32 PM.png", marked: false) && isCapture("Screen Recording 2026-11-12.mov", marked: false)
                && isCapture("renamed.png", marked: true) && !isCapture("holiday.png", marked: false) && !isCapture("Screenshot notes.txt", marked: false))

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pier-screenshots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func write(_ name: String, minutesAgo: Double) {
            let url = temp.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
            try? FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
        }
        write("Screenshot A.png", minutesAgo: 60 * 30)
        write("Screenshot B.png", minutesAgo: 5)
        write("Screenshot C.png", minutesAgo: 60 * 3)
        write("holiday.png", minutesAgo: 1)
        let listed = list(in: temp.path).map(\.name)
        check("screenshots: newest first, others left out", listed == ["Screenshot B.png", "Screenshot C.png", "Screenshot A.png"])
        check("screenshots: typing narrows by name or day",
              filter(list(in: temp.path), query: "c.png").map(\.name) == ["Screenshot C.png"]
                && filter(list(in: temp.path), query: "today").count == list(in: temp.path).filter { Calendar.current.isDateInToday($0.date!) }.count)

        // The rescue and the paste, in a temporary stand-in for TemporaryItems.
        let root = temp.appendingPathComponent("TemporaryItems"), saved = temp.path
        let preview = root.appendingPathComponent("NSIRD_screencaptureui_test")
        try? FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        func capture(_ name: String, minutesAgo: Double) -> String {
            let path = preview.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data(name.utf8))
            try? FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: path)
            return path
        }
        let dragged = capture("Screenshot T.png", minutesAgo: 1)
        check("screenshots: a temporary capture is recognised; other temporary files are not",
              isTemporaryCapture(dragged) && !isTemporaryCapture(root.appendingPathComponent("NSIRD_Python_x/Screenshot.png").path)
                && temporaryCaptures(root: root.path).map(\.name) == ["Screenshot T.png"])
        let takenAt = (try? FileManager.default.attributesOfItem(atPath: dragged))?[.creationDate] as? Date
        check("screenshots: dragged out and never saved: copied into the folder, keeping when it was taken",
              rescue(dragged, into: saved) && FileManager.default.fileExists(atPath: saved + "/Screenshot T.png")
                && (try? FileManager.default.attributesOfItem(atPath: saved + "/Screenshot T.png"))?[.creationDate] as? Date == takenAt)
        let twin = capture("Screenshot B.png", minutesAgo: 5)   // macOS already saved "Screenshot B.png"
        check("screenshots: already in the folder: not copied again, the saved one untouched",
              !rescue(twin, into: saved) && !rescue(dragged, into: saved)
                && (try? Data(contentsOf: URL(fileURLWithPath: saved + "/Screenshot B.png"))) == Data([0x89, 0x50, 0x4E, 0x47]))
        _ = capture("Screenshot P.png", minutesAgo: 0)
        let both = merge(saved: list(in: saved), temporary: temporaryCaptures(root: root.path))
        check("screenshots: one list from both places, newest first, each name once",
              both.first?.name == "Screenshot P.png" && both.filter { $0.name == "Screenshot B.png" }.count == 1
                && both.first { $0.name == "Screenshot B.png" }.map { !isTemporaryCapture($0.path) } == true)
        check("screenshots: paste takes the newest across both places: the one still in its preview",
              freshest(both, now: Date())?.name == "Screenshot P.png")
        let older = [FileHit(path: "/a/Screenshot old.png", date: Date().addingTimeInterval(-11 * 60)),
                     FileHit(path: "/b/Screenshot older.png", date: Date().addingTimeInterval(-60 * 60))]
        check("screenshots: paste takes the folder's when it is the newer, and nothing older than 10 minutes",
              freshest([FileHit(path: "/t/Screenshot 1.png", date: Date().addingTimeInterval(-300)),
                        FileHit(path: "/s/Screenshot 2.png", date: Date().addingTimeInterval(-30))], now: Date())?.path == "/s/Screenshot 2.png"
                && freshest(older, now: Date()) == nil)
        for name in ["Screenshot T.png"] { try? FileManager.default.removeItem(atPath: saved + "/" + name) }


        let model = ScreenshotsModel()
        model.folderOverride = temp.path
        model.temporaryRootOverride = root.path
        model.start()
        write("Screenshot D.png", minutesAgo: 0)
        let deadline = Date().addingTimeInterval(3)
        while model.items.first?.name != "Screenshot D.png", Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("screenshots: a new one shows up at the top while watching (\(Int((3 - deadline.timeIntervalSinceNow) * 1000)) ms)",
              model.items.first?.name == "Screenshot D.png")
        model.stop()
        write("Screenshot E.png", minutesAgo: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check("screenshots: nothing is watched once stopped", model.items.first?.name == "Screenshot D.png")
    }
}
