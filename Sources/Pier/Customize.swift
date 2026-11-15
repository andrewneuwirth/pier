import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsKit

/// A piece of the bar that can be shown, hidden and reordered (Customize › Widgets). Saved as
/// `widgets` in groups.json; missing means every widget in this order.
enum Widget: String, CaseIterable, Codable, Identifiable {
    case groups, recent, search, stats, minimized, quickLinks, projects, macTools, downloads, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .groups: "App Groups"
        case .recent: "Recent Apps"
        case .search: "Search"
        case .stats: "Memory & AI Usage"
        case .minimized: "Minimized Windows"
        case .quickLinks: "Quick Links"
        case .projects: "Projects"
        case .macTools: "newi tools"
        case .downloads: "Downloads"
        case .trash: "Trash"
        }
    }

    var detail: String {
        switch self {
        case .groups: "Your pinned apps, in named groups."
        case .recent: "The last 4 open apps that aren't pinned."
        case .search: "Apps, settings, files and screenshots (⌥Space)."
        case .stats: "Memory in use, heat, and Claude / ChatGPT limits."
        case .minimized: "Minimized windows get their own tiles."
        case .quickLinks: "Websites you open often."
        case .projects: "Your projects' sites and dev servers."
        case .macTools: "Every newi tools app you have installed."
        case .downloads: "Newest downloads, and a drop zone to send files."
        case .trash: "Drop files here to trash them."
        }
    }

    var symbol: String {
        switch self {
        case .groups: "square.grid.2x2"
        case .recent: "clock"
        case .search: "magnifyingglass"
        case .stats: "gauge.with.dots.needle.33percent"
        case .minimized: "rectangle.bottomhalf.inset.filled"
        case .quickLinks: "link"
        case .projects: "folder"
        case .macTools: "hammer"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        }
    }

    /// Widgets in the same cluster sit side by side; a divider goes between clusters.
    var cluster: Int {
        switch self {
        case .groups: 0
        case .recent: 1
        case .search, .stats: 2
        case .minimized: 3
        case .quickLinks, .projects, .macTools, .downloads, .trash: 4
        }
    }

    /// The saved list, read leniently: unknown names (from a newer Pier, or a typo) are skipped.
    static func parse(_ names: [String]?) -> [Widget] {
        guard let names else { return allCases }
        var seen = Set<Widget>()
        return names.compactMap(Widget.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}

/// The macOS Dock's own pinned apps, for the first launch's "Import from Dock".
enum DockImport {
    static func apps() -> [String] {
        let dock = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]]
        return paths(from: dock ?? [])
    }

    static func paths(from tiles: [[String: Any]]) -> [String] {
        tiles.compactMap { tile in
            let data = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            guard let string = data?["_CFURLString"] as? String else { return nil }
            let url = string.hasPrefix("file://") ? URL(string: string) : URL(fileURLWithPath: string)
            guard let path = url?.path, path.hasSuffix(".app") || path.hasSuffix(".app/") else { return nil }
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    static func selfCheck() {
        func check(_ label: String, _ ok: Bool) { print(ok ? "ok  \(label)" : "FAIL \(label)"); if !ok { exit(1) } }
        func tile(_ url: String) -> [String: Any] { ["tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15]]] }
        let tiles = [tile("file:///Applications/Safari.app/"), tile("file:///System/Applications/Notes%20Copy.app/"),
                     tile("file:///Users/me/Documents/"), ["tile-type": "spacer-tile"]]
        check("dock import: app paths in order, decoded, folders and spacers skipped",
              paths(from: tiles) == ["/Applications/Safari.app", "/System/Applications/Notes Copy.app"])
        check("widgets: missing list means all, in order", Widget.parse(nil) == Widget.allCases)
        check("widgets: unknown names and repeats are skipped",
              Widget.parse(["trash", "clock", "search", "trash"]) == [.trash, .search])
    }
}

// MARK: Window

/// What the Customize pages read and change: DockModel, or a stand-in for --customize-preview.
@MainActor protocol CustomizeStore: AnyObject {
    var widgets: [Widget] { get }
    var groupList: [GroupsFile.Group] { get }
    func setWidgets(_ list: [Widget])
    func setGroups(_ list: [GroupsFile.Group])
}
extension DockModel: CustomizeStore {}

