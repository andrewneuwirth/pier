import AppKit

/// A web link's own icon, for Quick Links and search: the homepage's declared icons (apple-touch-icon first,
/// then the biggest PNG), else /apple-touch-icon.png, else /favicon.ico. Cached on disk per host; a miss is
/// remembered only until Pier quits, so a link added while offline gets its icon next launch.
enum SiteIcon {
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.example.pier/site-icons")
    @MainActor private static var memory: [String: NSImage?] = [:]

    @MainActor
    static func load(_ host: String) async -> NSImage? {
        if let hit = memory[host] { return hit }
        let image = await Task.detached(priority: .utility) { fetch(host) }.value
        memory[host] = image
        return image
    }

    private static func fetch(_ host: String) -> NSImage? {
        // A bare word ("a") is not a site: no request.
        guard host.contains("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        let file = folder.appendingPathComponent(host)
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
        guard let home = URL(string: "https://\(host)/") else { return nil }
        var tries = [URL]()
        if let (data, final) = get(home), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            tries += iconLinks(in: html).compactMap { URL(string: $0, relativeTo: final)?.absoluteURL }
        }
        tries += ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: $0, relativeTo: home)?.absoluteURL }
        for url in tries {
            // SVG favicons don't draw in NSImage reliably at this size; the PNG/ICO ones do.
            guard url.pathExtension.lowercased() != "svg", let (data, _) = get(url),
                  let image = NSImage(data: data), image.isValid, image.size.width > 0 else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file)
            return image
        }
        return nil
    }

    /// The hrefs of the page's `<link rel="…icon…">` tags, best first: apple-touch-icon, then by declared size.
    static func iconLinks(in html: String) -> [String] {
        func attribute(_ name: String, _ tag: String) -> String? {
            guard let range = tag.range(of: #"\b\#(name)\s*=\s*["']([^"']*)["']"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let match = String(tag[range])
            guard let open = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
        }
        var found: [(rank: Int, href: String)] = []
        var rest = html[...]
        while let range = rest.range(of: #"<link\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(rest[range])
            rest = rest[range.upperBound...]
            guard let rel = attribute("rel", tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", tag)?.replacingOccurrences(of: "&amp;", with: "&"), !href.isEmpty else { continue }
            let size = attribute("sizes", tag).flatMap { $0.split(separator: "x").first.flatMap { Int($0) } } ?? 16
            found.append((rel.contains("apple-touch-icon") ? 10_000 + size : size, href))
        }
        return found.sorted { $0.rank > $1.rank }.map(\.href)
    }

    private static func get(_ url: URL) -> (Data, URL)? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")   // some sites refuse a bare client
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, URL)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 { result = (data, http.url ?? url) }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    static func selfCheck() {
        let html = #"""
        <link rel="icon" href="/favicon/favicon.ico" sizes="16x16 32x32"/>
        <link href="/a-48.png" sizes="48x48" rel="icon" type="image/png">
        <link rel='apple-touch-icon' href='/touch.png?v=1&amp;x=2' sizes='180x180'/>
        <link rel="mask-icon" href="/mask.svg"><link rel="stylesheet" href="/s.css">
        """#
        check("site icon: apple-touch first, then by size, mask and stylesheet skipped",
              iconLinks(in: html) == ["/touch.png?v=1&x=2", "/a-48.png", "/favicon/favicon.ico"])
    }
}
