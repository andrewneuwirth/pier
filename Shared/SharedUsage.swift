import Foundation
import Darwin

/// What the app hands the widget: the latest reading of each service, in the
/// app group's shared folder. The widget is sandboxed and can't read the
/// Claude Code / Codex credentials itself, so the app does the fetching.
struct SharedWindow: Codable, Equatable {
    var percent: Double
    var resetsAt: Date?
}

struct SharedReading: Codable, Equatable {
    var short: SharedWindow?
    var long: SharedWindow?
    var note: String?
    var failed = false
    var stale = false
}

struct SharedSnapshot: Codable, Equatable {
    var claude: SharedReading?
    var chatgpt: SharedReading?
    var updated: Date
}

enum SharedStore {
    /// ~/Library/Application Support/UsageRings/usage.json in the real home
    /// folder. Not an app-group container: a sandboxed widget can't open one
    /// without a provisioning profile (macOS 15+). The widget instead holds a
    /// read-only sandbox exception for just this folder.
    static var file: URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Application Support/UsageRings/usage.json")
    }

    /// Why the last read failed (shown by the widget instead of guessing).
    static func diagnose() -> String {
        guard let file else { return "no home folder" }
        do {
            let data = try Data(contentsOf: file)
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            _ = try d.decode(SharedSnapshot.self, from: data)
            return "ok"
        } catch {
            return "\(file.lastPathComponent): \(error.localizedDescription)"
        }
    }

    static func read() -> SharedSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(SharedSnapshot.self, from: data)
    }

    /// True when it changed what's stored (so the widget is worth reloading).
    @discardableResult
    static func write(_ snapshot: SharedSnapshot) -> Bool {
        guard let file else { return false }
        var old = read()
        old?.updated = snapshot.updated
        guard old != snapshot else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(snapshot).write(to: file, options: .atomic)
        return true
    }
}
