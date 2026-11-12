import Foundation

// Search's ranking: pure Foundation, no AppKit, checked by `Pier --self-check`.
// The index, the hotkey and opening things live in AppSearchIndex.swift; the views in DockView.swift.

/// One searchable name, normalised once when it is indexed so each keystroke only compares strings.
struct SearchKey: Equatable, Sendable {
    let spaced: String        // "visual studio code"
    let compact: String       // "visualstudiocode"
    let initials: String      // "vsc"
    let tails: [String]       // "studio code", "code": the name from each later word on
    let chars: [Character]    // of `spaced`
    let starts: [Int]         // where each word starts in `chars`

    init(_ raw: String) {
        let words = Self.words(raw)
        spaced = words.joined(separator: " ")
        compact = words.joined()
        initials = String(words.compactMap(\.first))
        tails = words.indices.dropFirst().map { words[$0...].joined(separator: " ") }
        chars = Array(spaced)
        var at = 0
        starts = words.map { word in defer { at += word.count + 1 }; return at }
    }

    /// Lowercased words, split at anything that isn't a letter or digit and at camelCase humps.
    static func words(_ raw: String) -> [String] {
        var out: [String] = [], current = "", lastLower = false
        for ch in raw.folding(options: .diacriticInsensitive, locale: nil) {
            let wordChar = ch.isLetter || ch.isNumber
            if !current.isEmpty, !wordChar || (ch.isUppercase && lastLower) {
                out.append(current)
                current = ""
            }
            if wordChar { current += ch.lowercased() }
            lastLower = ch.isLowercase
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

struct SearchEntry: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case app, setting, link, project }
    let id: String            // an app's is AppItem.id (bundle id, else path), so running apps match
    let kind: Kind
    let name: String
    let detail: String        // the small second line; empty when there is nothing worth saying
    let target: URL
    let projectPath: String?  // a project link's folder, for its icon
    let keys: [SearchKey]     // the name first, then other names it answers to

    init(id: String, kind: Kind, name: String, aliases: [String] = [], detail: String = "", target: URL, projectPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.target = target
        self.projectPath = projectPath
        var seen = Set<String>()
        keys = ([name] + aliases).map(SearchKey.init).filter { !$0.compact.isEmpty && seen.insert($0.compact).inserted }
    }
}

/// What you launched from search, how often, when, and which result you chose for which typed text.
struct SearchUsage: Equatable, Sendable {
    var launches: [String: Int] = [:]
    var lastUsed: [String: Date] = [:]
    // shortcut: one small entry per distinct text you ever chose from, never pruned; cap it if the defaults grow.
    var picks: [String: [String: Int]] = [:]   // typed text → entry id → times chosen

    mutating func record(_ id: String, query: String, now: Date = Date()) {
        launches[id, default: 0] += 1
        lastUsed[id] = now
        let typed = SearchRank.Query(query).compact
        if !typed.isEmpty { picks[typed, default: [:]][id, default: 0] += 1 }
    }

    /// Up to 60 for how often, up to 30 for how recently, and 120 per time (up to 4) it was the pick for this text.
    func boost(_ id: String, typed: String = "", now: Date) -> Int {
        var boost = min(60, Int(12 * log2(Double(1 + (launches[id] ?? 0)))))
        if let used = lastUsed[id] {
            let age = now.timeIntervalSince(used)
            boost += age < 86_400 ? 30 : age < 604_800 ? 15 : 0
        }
        return boost + min(picks[typed]?[id] ?? 0, 4) * 120
    }

    static func load(_ defaults: UserDefaults = .standard) -> SearchUsage {
        SearchUsage(launches: defaults.dictionary(forKey: "searchLaunches") as? [String: Int] ?? [:],
                    lastUsed: defaults.dictionary(forKey: "searchLastUsed") as? [String: Date] ?? [:],
                    picks: defaults.dictionary(forKey: "searchPicks") as? [String: [String: Int]] ?? [:])
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(launches, forKey: "searchLaunches")
        defaults.set(lastUsed, forKey: "searchLastUsed")
        defaults.set(picks, forKey: "searchPicks")
    }
}

enum SearchRank {
    /// How well the typed text fits a name, strongest first. Usage adds at most about one step
    /// (a much-used word-start match can pass an unused prefix match); a learned pick adds more.
    enum Tier {
        static let exact = 1000, prefix = 900, wordStart = 800, acronym = 700
        static let abbreviation = 620   // "ps" → Photoshop: a few letters of one word, from its start
        static let substring = 500, fuzzy = 400, typo = 100
        static let alias = -40, running = 15
    }

    /// The typed text, normalised once per keystroke, with its one-typo variants for 4+ letters.
    struct Query {
        let spaced: String, compact: String
        let chars: [Character]
        let typos: [String]

        init(_ raw: String) {
            let key = SearchKey(raw.lowercased())
            spaced = key.spaced
            compact = key.compact
            let chars = Array(key.compact)
            self.chars = chars
            guard chars.count >= 4 else { typos = []; return }
            // Two neighbouring letters swapped ("chrmoe"), or one letter too many ("chroome").
            // A letter left out ("chrme") needs no variant: it already matches as a subsequence.
            let swaps = chars.indices.dropLast().filter { chars[$0] != chars[$0 + 1] }.map { i -> String in
                var c = chars
                c.swapAt(i, i + 1)
                return String(c)
            }
            let drops = chars.indices.map { i -> String in
                var c = chars
                c.remove(at: i)
                return String(c)
            }
            typos = swaps + drops
        }
    }

    static func score(_ query: String, _ name: String) -> Int { score(Query(query), SearchKey(name)) }

    static func score(_ q: Query, _ key: SearchKey) -> Int {
        guard !q.compact.isEmpty else { return 0 }
        let exactish = strict(q.spaced, q.compact, key)
        if exactish > 0 { return exactish }
        // Letters spread further apart than twice the typed length are a coincidence, not a match.
        if let (gaps, oneWord) = subsequence(q.chars, in: key), gaps <= q.chars.count * 2 {
            if oneWord, q.chars.count <= 3 { return Tier.abbreviation - min(gaps, 50) }
            // Two letters scattered over several words match nearly everything.
            if q.chars.count >= 3 { return Tier.fuzzy - min(gaps * 10, 190) }
        }
        // A corrected typo has to land on the start of a word: mid-word, a shortened query fits far too much.
        let best = q.typos.map { strict($0, $0, key) }.max() ?? 0
        return best >= Tier.wordStart ? Tier.typo + best / 10 : 0
    }

    /// The best of an entry's names; a match on another name (CFBundleName, bundle id tail) counts a little less.
    static func score(_ q: Query, _ entry: SearchEntry) -> Int {
        var best = 0
        for (i, key) in entry.keys.enumerated() { best = max(best, score(q, key) + (i == 0 ? 0 : Tier.alias)) }
        guard best > 0 else { return 0 }
        // Same fit: an app before a link before a settings pane.
        return best - (entry.kind == .setting ? 20 : entry.kind == .app ? 0 : 10)
    }

    /// Best first. Nothing typed: the apps you launch most and most recently, then the ones that are open.
    static func rank(_ query: String, _ entries: [SearchEntry], usage: SearchUsage = SearchUsage(),
                     running: Set<String> = [], now: Date = Date(), limit: Int = 8) -> [SearchEntry] {
        let q = Query(query)
        let scored: [(entry: SearchEntry, score: Int)] = entries.compactMap { entry in
            let fit = q.compact.isEmpty ? (entry.kind == .app ? 1 : 0) : score(q, entry)
            guard fit > 0 else { return nil }
            return (entry, fit + usage.boost(entry.id, typed: q.compact, now: now) + (running.contains(entry.id) ? Tier.running : 0))
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.name.count != b.entry.name.count { return a.entry.name.count < b.entry.name.count }
            return a.entry.name < b.entry.name
        }
        .prefix(limit).map(\.entry)
    }

    static func strict(_ spaced: String, _ compact: String, _ key: SearchKey) -> Int {
        if spaced == key.spaced || compact == key.compact { return Tier.exact }
        if key.spaced.hasPrefix(spaced) || key.compact.hasPrefix(compact) { return Tier.prefix }
        if key.tails.contains(where: { $0.hasPrefix(spaced) }) { return Tier.wordStart }
        if compact.count >= 2, key.initials.hasPrefix(compact) { return Tier.acronym }
        if key.spaced.contains(spaced) { return Tier.substring }
        return 0
    }

    /// The typed letters in order, beginning at the start of a word: how many letters were skipped
    /// in the tightest such match, and whether it stayed inside one word.
    private static func subsequence(_ q: [Character], in key: SearchKey) -> (gaps: Int, oneWord: Bool)? {
        var best: (gaps: Int, oneWord: Bool)?
        for start in key.starts where key.chars[start] == q[0] {
            var at = start, matched = 1, oneWord = true
            while matched < q.count, at + 1 < key.chars.count {
                at += 1
                if key.chars[at] == " " { oneWord = false } else if key.chars[at] == q[matched] { matched += 1 }
            }
            guard matched == q.count else { continue }
            let gaps = at - start + 1 - q.count
            if best == nil || gaps < best!.gaps { best = (gaps, oneWord) }
        }
        return best
    }

    // MARK: Self-check

    /// `Pier --self-check`: the ranking cases, one line each. Stops at the first that fails.
    static func selfCheck() {
        func app(_ name: String, _ aliases: String...) -> SearchEntry {
            SearchEntry(id: name, kind: .app, name: name, aliases: aliases, target: URL(fileURLWithPath: "/Applications/\(name).app"))
        }
        let apps = [app("Visual Studio Code", "Code", "VSCode"), app("Xcode"), app("Codepoint"), app("TVSync"),
                    app("Adobe Photoshop 2025"), app("Maps"), app("Google Chrome", "Chrome"), app("Calendar"),
                    app("Calculator"), app("Notes"), app("Notes Plus"), app("Safari")]
        func top(_ query: String, usage: SearchUsage = SearchUsage(), running: Set<String> = []) -> [String] {
            rank(query, apps, usage: usage, running: running, now: Date(timeIntervalSince1970: 1_000_000)).map(\.name)
        }

        check("tiers: exact > prefix > word start > acronym > substring > fuzzy > typo",
              [score("notes", "Notes"), score("not", "Notes"), score("code", "Visual Studio Code"), score("vsc", "Visual Studio Code"),
               score("ode", "Xcode"), score("chrme", "Chrome"), score("chrmoe", "Chrome")]
                == [Tier.exact, Tier.prefix, Tier.wordStart, Tier.acronym, Tier.substring, Tier.fuzzy - 10, Tier.typo + Tier.exact / 10])
        check("exact before prefix: notes -> Notes, Notes Plus", top("notes") == ["Notes", "Notes Plus"])
        check("another name in full, prefix, substring: code -> Visual Studio Code, Codepoint, Xcode",
              top("code") == ["Visual Studio Code", "Codepoint", "Xcode"])
        check("acronym before substring: vs -> Visual Studio Code, TVSync", top("vs") == ["Visual Studio Code", "TVSync"])
        check("acronym: vsc -> Visual Studio Code", top("vsc").first == "Visual Studio Code")
        check("abbreviation before substring: ps -> Adobe Photoshop 2025 ahead of Maps",
              top("ps").firstIndex(of: "Adobe Photoshop 2025")! < top("ps").firstIndex(of: "Maps")!)
        check("transposition: chrmoe -> Google Chrome", top("chrmoe") == ["Google Chrome"])
        check("missing letter: chrme -> Google Chrome", top("chrme") == ["Google Chrome"])
        check("extra letter: saffari -> Safari", top("saffari") == ["Safari"])
        check("typos need 4+ letters and a word start: cdoe -> Codepoint, Visual Studio Code; xoc -> nothing",
              top("cdoe") == ["Codepoint", "Visual Studio Code"] && top("xoc").isEmpty)
        check("other names: vscode -> Visual Studio Code", top("vscode") == ["Visual Studio Code"])
        check("no match: zzzz -> nothing", top("zzzz").isEmpty)
        check("tie: shorter name first: ca -> Calendar, Calculator", Array(top("ca").prefix(2)) == ["Calendar", "Calculator"])
        check("running app wins a tie: ca -> Calculator", top("ca", running: ["Calculator"]).first == "Calculator")

        let now = Date(timeIntervalSince1970: 1_000_000)
        var usage = SearchUsage()
        check("before learning: c -> Calendar", top("c").first == "Calendar")
        usage.record("Google Chrome", query: "c", now: now)
        usage.record("Google Chrome", query: "C", now: now)
        check("picked Chrome for c twice: c -> Google Chrome", top("c", usage: usage).first == "Google Chrome")
        check("what was learned for c stays with c: ca -> Calendar", top("ca", usage: usage).first == "Calendar")
        usage.record("Safari", query: "saf", now: now)
        check("nothing typed: most used first: Google Chrome, Safari", Array(top("", usage: usage).prefix(2)) == ["Google Chrome", "Safari"])
        check("names split into words: LockScreen, Wi-Fi", SearchKey("LockScreen").spaced == "lock screen" && score("wifi", "Wi-Fi") == Tier.exact)
    }
}

func check(_ label: String, _ ok: Bool) {
    precondition(ok, "self-check failed: \(label)")
    print("ok  \(label)")
}

// MARK: Files

/// A file or folder Spotlight found by name.
struct FileHit: Identifiable, Equatable, Sendable {
    let path: String
    var isFolder = false
    /// When it was last opened or changed, whichever is later.
    var date: Date?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Ranking for file results: how the name fits first, then how recent, then where it is.
enum FileRank {
    /// 200 apart. Among files of one kind, date and place add between -30 and +140, so the better name match
    /// always wins. The kind of file (`kind`) and a file you picked before for the same text can outweigh a step.
    enum Tier { static let exact = 1000, prefix = 800, wordStart = 600, substring = 400 }

    /// What a person opens by hand comes first: documents, then folders, pictures and recordings, archives and
    /// installers, anything else; source code and data files well below, so `transcript.ts` sits under the PDFs
    /// (near a document whose name only has the word in it somewhere) instead of on top of them.
    static func kind(_ hit: FileHit) -> Int {
        if hit.isFolder { return -20 }
        let ext = (hit.name as NSString).pathExtension.lowercased()
        let documents: Set = ["pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "txt", "md", "rtf", "epub"]
        let media: Set = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "mp4", "mov", "m4v", "mkv", "mp3", "m4a", "wav", "aac", "flac", "aiff"]
        let archives: Set = ["zip", "dmg", "pkg", "tar", "gz", "tgz", "7z", "rar"]
        let code: Set = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm",
                         "cs", "php", "sh", "json", "jsonl", "yml", "yaml", "toml", "xml", "plist", "css", "scss", "html", "htm", "sql", "lock",
                         "map", "o", "a", "d", "log", "db", "sqlite"]
        return documents.contains(ext) ? 0 : media.contains(ext) ? -40 : archives.contains(ext) ? -60 : code.contains(ext) ? -350 : -80
    }

    /// What is typed, as the words every name must contain (any order).
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Not the noise: hidden things, dependency and build folders, caches, the insides of apps and other
    /// packages, and ~/Library except the cloud drives that live in it. Apps themselves are in the list above.
    static func keep(_ path: String, home: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let name = parts.last, !name.hasSuffix(".app"), !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        let noise: Set = ["node_modules", "deriveddata", "build", "dist", "caches", "cache", "__pycache__", "pods", "site-packages", "venv"]
        let packages = [".app", ".framework", ".bundle", ".plugin", ".appex", ".xcarchive", ".photoslibrary"]
        for folder in parts.dropLast() {
            let folder = folder.lowercased()
            if noise.contains(folder) || packages.contains(where: { folder.hasSuffix($0) }) { return false }
        }
        if path.hasPrefix(home + "/Library/") {
            return path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/")
        }
        return true
    }

    /// A folder as the second line shows it: "~/Documents/Meetings", "iCloud Drive/Notes", "Backup/Photos".
    static func place(_ folder: String, home: String) -> String {
        let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if folder.hasPrefix(cloud) { return "iCloud Drive" + folder.dropFirst(cloud.count) }
        if folder.hasPrefix(home) { return "~" + folder.dropFirst(home.count) }
        if folder.hasPrefix("/Volumes/") { return String(folder.dropFirst("/Volumes/".count)) }
        return folder
    }

    /// "Today", "Yesterday", "Tuesday" (this past week), "Mar 12" (this year), "Mar 2024".
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if days < 7 { return date.formatted(style.weekday(.wide)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).year())
    }

    /// Where each typed word first appears in the name, for the emphasis.
    static func emphasis(_ name: String, _ words: [String]) -> [Range<String.Index>] {
        words.compactMap { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
    }

    /// The whole text against the name (with and without its extension); failing that, the weakest of its words.
    static func fit(_ words: [String], _ name: String) -> Int {
        let keys = [SearchKey((name as NSString).deletingPathExtension), SearchKey(name)]
        func tier(_ text: String) -> Int {
            let q = SearchRank.Query(text)
            let best = keys.map { SearchRank.strict(q.spaced, q.compact, $0) }.max() ?? 0
            if best >= SearchRank.Tier.exact { return Tier.exact }
            // A prefix counts as one when it ends on a word: "transcript" leads "Transcript_2024.pdf", but in
            // "TranscriptionCleanup.swift" it is only the start of a longer word, no better than a word start.
            if best >= SearchRank.Tier.prefix, keys.contains(where: { $0.spaced.hasPrefix(q.spaced + " ") }) { return Tier.prefix }
            return best >= SearchRank.Tier.wordStart ? Tier.wordStart : Tier.substring   // Spotlight already found the letters in it
        }
        return max(tier(words.joined(separator: " ")), words.map(tier).min() ?? Tier.substring)
    }

    static func score(_ hit: FileHit, words: [String], home: String, usage: SearchUsage = SearchUsage(), now: Date) -> Int {
        var score = fit(words, hit.name) + kind(hit)
        // Recency, strongly: 87 for yesterday, 45 at a month, 7 at a year, 1 for 2021.
        if let date = hit.date { score += Int(90 / (1 + max(0, now.timeIntervalSince(date)) / 86_400 / 30)) }
        let folders = place((hit.path as NSString).deletingLastPathComponent, home: home).split(separator: "/")
        if folders.first == "~", folders.count > 1 {
            score += folders[1] == "Downloads" ? 40 : folders[1] == "Desktop" || folders[1] == "Documents" ? 10 : 0
        }
        if folders.count <= 2 { score += 10 }                          // right there, not buried
        score -= min(max(folders.count - 6, 0) * 5, 30)                // very deep
        return score + usage.boost(hit.path, typed: SearchRank.Query(words.joined(separator: " ")).compact, now: now)
    }

    /// Best first, without the noise; `total` is how many there were before the list was cut to `limit`.
    static func rank(_ query: String, _ hits: [FileHit], home: String, usage: SearchUsage = SearchUsage(),
                     now: Date = Date(), limit: Int = 50) -> (rows: [FileHit], total: Int) {
        let words = words(query)
        let scored = hits.filter { keep($0.path, home: home) }.map { ($0, score($0, words: words, home: home, usage: usage, now: now)) }
        let rows = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.name.count != b.0.name.count { return a.0.name.count < b.0.name.count }
            return a.0.path < b.0.path
        }
        return (rows.prefix(limit).map(\.0), rows.count)
    }

    static func selfCheck() {
        let home = "/Users/me", now = Date(timeIntervalSince1970: 1_800_000_000), day = 86_400.0
        func file(_ path: String, daysAgo: Double = 400) -> FileHit {
            FileHit(path: home + "/" + path, date: now.addingTimeInterval(-daysAgo * day))
        }
        func top(_ query: String, _ hits: [FileHit], usage: SearchUsage = SearchUsage()) -> [String] {
            rank(query, hits, home: home, usage: usage, now: now).rows.map { String($0.path.dropFirst(home.count + 1)) }
        }
        check("files: exact name > prefix > word start > substring",
              top("transcript", [file("a/Subtranscripts.txt"), file("a/College Transcript.pdf"), file("a/Transcript 2024.pdf"), file("a/transcript.pdf")])
                == ["a/transcript.pdf", "a/Transcript 2024.pdf", "a/College Transcript.pdf", "a/Subtranscripts.txt"])
        check("files: a document before code of the same name: transcript.pdf, transcript.ts",
              top("transcript", [file("a/transcript.ts", daysAgo: 1), file("a/transcript.pdf", daysAgo: 20)]) == ["a/transcript.pdf", "a/transcript.ts"])
        check("files: code named exactly sits under a PDF that starts with the word, and still shows",
              top("transcript", [file("dev/src/transcript.ts", daysAgo: 15), file("Downloads/Transcript_Me.pdf", daysAgo: 34)])
                == ["Downloads/Transcript_Me.pdf", "dev/src/transcript.ts"])
        check("files: by kind, same name and date: document, folder, picture, archive, other, code",
              top("report", [file("a/report.json"), file("a/report.xyz"), file("a/report.zip"), file("a/report.png"),
                             FileHit(path: home + "/a/report", isFolder: true, date: now.addingTimeInterval(-400 * day)), file("a/report.pdf")])
                == ["a/report.pdf", "a/report", "a/report.png", "a/report.zip", "a/report.xyz", "a/report.json"])
        check("files: a whole word later in the name ties the start of a longer word, so the recent one wins",
              top("transcript", [file("a/TranscriptionCleanup.swift", daysAgo: 30), file("a/College-Unofficial-Transcript.pdf", daysAgo: 1)]).first
                == "a/College-Unofficial-Transcript.pdf")
        check("files: every word, any order: transcript college -> College-Unofficial-Transcript.pdf as a word-start match",
              fit(["transcript", "college"], "College-Unofficial-Transcript.pdf") == Tier.wordStart)
        check("files: the words in order are the whole name: exact", fit(["college", "transcript"], "College Transcript.pdf") == Tier.exact)
        check("files: yesterday's beats the one from years ago",
              top("transcript", [file("a/Transcript old.pdf", daysAgo: 1900), file("a/Transcript new.pdf", daysAgo: 1)]).first == "a/Transcript new.pdf")
        check("files: same match, similar dates: Downloads first, then Documents, then elsewhere",
              top("transcript", [file("Developer/x/Transcript c.pdf", daysAgo: 10), file("Documents/x/Transcript b.pdf", daysAgo: 10),
                                 file("Downloads/x/Transcript a.pdf", daysAgo: 11)])
                == ["Downloads/x/Transcript a.pdf", "Documents/x/Transcript b.pdf", "Developer/x/Transcript c.pdf"])
        check("files: a better name match beats recent and in Downloads",
              top("transcript", [file("Downloads/My Transcript.pdf", daysAgo: 0), file("a/b/c/d/e/f/g/h/i/j/k/l/Transcript.pdf", daysAgo: 1900)]).first
                == "a/b/c/d/e/f/g/h/i/j/k/l/Transcript.pdf")
        check("files: shallow before very deep",
              top("notes", [file("a/b/c/d/e/f/g/h/Notes.txt"), file("Projects/Notes.txt")]).first == "Projects/Notes.txt")
        var usage = SearchUsage()
        usage.record(home + "/a/College Transcript.pdf", query: "transcript", now: now)
        usage.record(home + "/a/College Transcript.pdf", query: "transcript", now: now)
        check("files: picked twice for this text: ahead of a better-named file",
              top("transcript", [file("a/Transcript 2024.pdf"), file("a/College Transcript.pdf")], usage: usage).first == "a/College Transcript.pdf")
        let noise = ["Library/Caches/transcript.db", "Library/Application Support/x/transcript.json", "dev/app/node_modules/pkg/transcript.js",
                     "dev/app/.git/transcript", "dev/.hidden-transcript", "Library/Developer/Xcode/DerivedData/x/transcript.o",
                     "dev/app/build/transcript.o", "dev/app/dist/transcript.js", "dev/app/Pods/X/transcript.h", "Applications/Transcript.app", "dev/Thing.app/Contents/Resources/transcript.txt"]
        check("files: noise is left out (\(noise.count) kinds)", noise.allSatisfy { !keep(home + "/" + $0, home: home) })
        check("files: iCloud Drive, cloud storage, folders and other volumes are kept",
              ["Library/Mobile Documents/com~apple~CloudDocs/School/transcript.pdf", "Library/CloudStorage/Dropbox/transcript.pdf",
               "Documents/Transcripts"].allSatisfy { keep(home + "/" + $0, home: home) } && keep("/Volumes/Backup/transcript.pdf", home: home))
        check("files: places read short: ~/Documents/Meetings, iCloud Drive/School, Backup/Old",
              [home + "/Documents/Meetings", home + "/Library/Mobile Documents/com~apple~CloudDocs/School", "/Volumes/Backup/Old"]
                .map { place($0, home: home) } == ["~/Documents/Meetings", "iCloud Drive/School", "Backup/Old"])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: day) + day / 2)   // 2027-01-15
        check("files: dates read Today, Yesterday, Jan 3, Mar 2024",
              [0, 1, 12, 1040].map { when(noon.addingTimeInterval(-$0 * day), now: noon, calendar: utc, locale: Locale(identifier: "en_US")) }
                == ["Today", "Yesterday", "Jan 3", "Mar 2024"])
        check("files: the typed part of the name is found for emphasis",
              emphasis("College-Unofficial-Transcript.pdf", ["transcript"]).map { String("College-Unofficial-Transcript.pdf"[$0]) } == ["Transcript"])
    }
}
