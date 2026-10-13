import AppKit
import Darwin

/// Claude Code sessions, from the files Claude itself keeps in ~/.claude/sessions/<pid>.json
/// (the same source Hangar reads). Each session is traced up its process tree to the app
/// hosting it (Terminal, Hangar, VS Code), so that app's tile can say "needs you" or "done".
enum AgentWatch {
    struct Session {
        let pid: pid_t
        let name: String
        let status: String   // "busy", "idle", "waiting"
        let hostID: String   // AppItem.id of the hosting app
    }

    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    @MainActor private static var hosts: [pid_t: String] = [:]

    @MainActor
    static func read() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var sessions: [Session] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (row["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0,   // the file outlives a crashed session
                  let host = host(of: pid) else { continue }
            sessions.append(Session(pid: pid, name: row["name"] as? String ?? "Claude",
                                    status: row["status"] as? String ?? "idle", hostID: host))
        }
        hosts = hosts.filter { pid, _ in sessions.contains { $0.pid == pid } }
        return sessions
    }

    /// Walks parent processes up to the first GUI app. A helper (Hangar's terminal host) maps to
    /// the running app whose bundle id it extends.
    @MainActor
    private static func host(of pid: pid_t) -> String? {
        if let known = hosts[pid] { return known }
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), let id = app.bundleIdentifier {
                if app.activationPolicy == .regular { hosts[pid] = id; return id }
                if let owner = NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular && ($0.bundleIdentifier.map { id.hasPrefix($0 + ".") } ?? false)
                }), let ownerID = owner.bundleIdentifier {
                    hosts[pid] = ownerID
                    return ownerID
                }
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
