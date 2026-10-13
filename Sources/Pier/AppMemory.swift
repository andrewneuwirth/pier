import AppKit
import Darwin

/// Memory per app, the way Activity Monitor's Memory column counts it: each process's physical
/// footprint, added to the app responsible for it. That puts Chrome's helpers on Chrome and
/// Safari's web pages (WebKit processes outside Safari.app) on Safari. Measured only when asked.
enum AppMemory {
    struct Use: Identifiable, Sendable {
        let path: String   // the .app bundle
        let bytes: UInt64
        var id: String { path }
        var name: String { FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
    }

    /// Every app with its total, largest first.
    static func snapshot() async -> [Use] {
        await Task.detached(priority: .userInitiated) { measure() }.value
    }

    static func use(of appPath: String) async -> UInt64? {
        await snapshot().first { $0.path == appPath }?.bytes
    }

    private static func measure() -> [Use] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var totals: [String: UInt64] = [:]
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            guard let footprint = footprint(of: pid),
                  let app = appBundle(of: responsible(for: pid)) ?? appBundle(of: pid) else { continue }
            totals[app, default: 0] += footprint
        }
        return totals.map { Use(path: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : nil
    }

    /// The outermost .app a process's binary lives in.
    private static func appBundle(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let end = path.range(of: ".app/") else { return nil }
        return String(path[..<end.lowerBound]) + ".app"
    }

    /// The process macOS holds responsible for this one (an XPC helper → its app). Private libSystem
    /// call, looked up at runtime; without it each process counts toward its own bundle only.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsible(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
