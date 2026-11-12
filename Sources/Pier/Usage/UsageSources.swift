import Foundation

/// Both services expose the same numbers their own CLIs draw, from endpoints
/// that cost nothing to call — no model tokens, no session required. That is
/// what lets these rings stay honest while you are working in a browser tab
/// instead of a terminal.
enum Fetch {
    static func json(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("Pier", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.shape
        }
        return object
    }

    enum Failure: Error {
        case status(Int), shape, noCredential
    }

    /// Timestamps arrive as ISO-8601 with microseconds from one service and as
    /// epoch seconds from the other.
    static func date(iso: Any?) -> Date? {
        guard let text = iso as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func date(epoch: Any?) -> Date? {
        guard let seconds = epoch as? Double ?? (epoch as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Claude

enum ClaudeSource {
    /// Claude Code keeps its OAuth credential in the login keychain. Shelling
    /// out to `security` keeps the token inside a short-lived pipe: this app
    /// never writes it anywhere, and never holds it past the request.
    private static func token() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data),
              let found = firstString(named: "accessToken", in: object)
        else { throw Fetch.Failure.noCredential }
        return found
    }

    static func load() async -> Usage {
        let accessToken: String
        do { accessToken = try token() } catch {
            return .error("Sign in with Claude Code")
        }
        do {
            let body = try await Fetch.json(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                headers: ["Authorization": "Bearer \(accessToken)",
                          "anthropic-beta": "oauth-2025-04-20"])
            return Usage(short: window(body["five_hour"]),
                         long: window(body["seven_day"]),
                         note: nil,
                         fetchedAt: Date())
        } catch Fetch.Failure.status(401) {
            return .error("Session expired — open Claude Code")
        } catch Fetch.Failure.status(429) {
            // The usage endpoint has its own limit, unrelated to the plan's.
            return .error("Checking too often", rateLimited: true)
        } catch Fetch.Failure.status(let code) {
            return .error("Anthropic returned \(code)")
        } catch {
            return .error("Couldn't reach Anthropic")
        }
    }

    private static func window(_ raw: Any?) -> UsageWindow? {
        guard let dictionary = raw as? [String: Any],
              let utilization = dictionary["utilization"] as? Double
        else { return nil }
        return UsageWindow(percent: utilization, resetsAt: Fetch.date(iso: dictionary["resets_at"]))
    }
}

// MARK: - ChatGPT

enum ChatGPTSource {
    static func load() async -> Usage {
        let auth = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: auth),
              let object = try? JSONSerialization.jsonObject(with: data),
              let accessToken = firstString(named: "access_token", in: object)
        else { return .error("Sign in with Codex") }

        var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
        if let account = firstString(named: "account_id", in: object)
            ?? firstString(named: "chatgpt_account_id", in: object) {
            headers["chatgpt-account-id"] = account
        }

        do {
            let body = try await Fetch.json(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
            let limit = body["rate_limit"] as? [String: Any] ?? [:]

            // Which window is which varies by plan, so sort by the window's own
            // length rather than trusting primary/secondary to mean short/long.
            let windows = [limit["primary_window"], limit["secondary_window"]]
                .compactMap { $0 as? [String: Any] }
            return Usage(short: windows.first(where: isShort).flatMap(window),
                         long: windows.first(where: { !isShort($0) }).flatMap(window),
                         note: (body["plan_type"] as? String)?.capitalized,
                         fetchedAt: Date())
        } catch Fetch.Failure.status(401), Fetch.Failure.status(403) {
            return .error("Session expired — run codex login")
        } catch Fetch.Failure.status(429) {
            return .error("Checking too often", rateLimited: true)
        } catch Fetch.Failure.status(let code) {
            return .error("ChatGPT returned \(code)")
        } catch {
            return .error("Couldn't reach ChatGPT")
        }
    }

    /// Anything that renews within a working day counts as the short window.
    private static func isShort(_ raw: [String: Any]) -> Bool {
        let seconds = raw["limit_window_seconds"] as? Double
            ?? (raw["limit_window_seconds"] as? Int).map(Double.init) ?? 0
        return seconds > 0 && seconds <= 12 * 3600
    }

    private static func window(_ raw: [String: Any]) -> UsageWindow? {
        guard let used = raw["used_percent"] as? Double
            ?? (raw["used_percent"] as? Int).map(Double.init)
        else { return nil }
        return UsageWindow(percent: used, resetsAt: Fetch.date(epoch: raw["reset_at"]))
    }
}

/// Both credential files nest the token at a path that has moved between
/// versions, so find it by name instead of by a hard-coded path.
private func firstString(named key: String, in object: Any) -> String? {
    if let dictionary = object as? [String: Any] {
        if let direct = dictionary[key] as? String, !direct.isEmpty { return direct }
        for value in dictionary.values {
            if let found = firstString(named: key, in: value) { return found }
        }
    }
    return nil
}
