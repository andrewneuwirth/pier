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

/// Customize Pier (right-click the bar), and the same pages as a walkthrough on the first launch.
@MainActor
enum CustomizeWindow {
    private static var window: NSWindow?

    static func show(_ model: any CustomizeStore, walkthrough: Bool = false) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = walkthrough
            ? AnyView(Walkthrough(model: model) { window?.close() })
            : AnyView(CustomizeView(model: model))
        let w = NSWindow(contentViewController: NSHostingController(rootView: view.frame(width: 560, height: 480)))
        w.title = walkthrough ? "Welcome to Pier" : "Customize Pier"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                UserDefaults.standard.set(true, forKey: "onboarded")
            }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case widgets = "Widgets", groups = "App Groups", permissions = "Permissions", search = "Search"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .widgets: "square.stack.3d.up"
        case .groups: "square.grid.2x2"
        case .permissions: "lock.shield"
        case .search: "magnifyingglass"
        }
    }

    @MainActor @ViewBuilder
    func view(_ model: any CustomizeStore, walkthrough: Bool) -> some View {
        switch self {
        case .widgets: WidgetsPage(model: model)
        case .groups: GroupsPage(model: model, offerImport: walkthrough)
        case .permissions: PermissionsPage()
        case .search: SearchPage()
        }
    }
}

private struct CustomizeView: View {
    let model: any CustomizeStore
    @State var page = Page.widgets

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MT.Space.s4) {
                ForEach(Page.allCases) { p in
                    Button { page = p } label: {
                        Label(p.rawValue, systemImage: p.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, MT.Space.s10).padding(.vertical, MT.Space.s6)
                            .background(page == p ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.control))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, MT.Space.s26 + MT.Space.s12).padding(.horizontal, MT.Space.s10)
            .frame(width: 170)
            .background(Color.mtFillInset)
            ScrollView { page.view(model, walkthrough: false).padding(MT.Space.s18).padding(.top, MT.Space.s18) }
                .frame(maxWidth: .infinity)
        }
        .background(Color.mtGround)
        .foregroundStyle(Color.mtInk)
    }
}

/// Welcome, then each page in turn, then done. Every step can be skipped and changed later in Customize.
private struct Walkthrough: View {
    let model: any CustomizeStore
    let finish: () -> Void
    @State private var step = 0
    private let pages: [Page] = [.groups, .widgets, .permissions, .search]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 {
                    Hero(symbol: "dock.rectangle", title: "Welcome to Pier",
                         text: "Pier replaces the macOS Dock with app groups, search, downloads and live stats. "
                             + "A few quick steps set it up; everything can be changed later by right-clicking the bar › Customize Pier…")
                } else if step <= pages.count {
                    ScrollView { pages[step - 1].view(model, walkthrough: true).padding(MT.Space.s18).padding(.top, MT.Space.s18) }
                } else {
                    Hero(symbol: "checkmark.circle", title: "You're set",
                         text: "Drag apps onto the bar to pin them, right-click a tile for its options, and press ⌥Space to search. "
                             + "Quit Pier from the bar's right-click menu to get the macOS Dock back.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Text(step == 0 || step > pages.count ? "" : "Step \(step) of \(pages.count)").foregroundStyle(Color.mtInkMuted)
                Spacer()
                Button(step > pages.count ? "Done" : step == 0 ? "Get Started" : "Continue") {
                    if step > pages.count { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(MT.Space.s18)
        }
        .background(Color.mtGround)
        .foregroundStyle(Color.mtInk)
    }
}

private struct Hero: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: MT.Space.s12) {
            Image(systemName: symbol).font(.system(size: 52)).foregroundStyle(Color.mtGood)
            Text(title).font(.title.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(Color.mtInkMuted).frame(maxWidth: 400)
        }
        .padding(MT.Space.s26)
    }
}

private struct PageHeader: View {
    let title: String, text: String
    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s4) {
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(Color.mtInkMuted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.mtSurface, in: .rect(cornerRadius: MT.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: MT.Radius.card).stroke(Color.mtHairline))
    }
}

// MARK: Pages

private struct WidgetsPage: View {
    let model: any CustomizeStore

    var body: some View {
        let shown = model.widgets
        let hidden = Widget.allCases.filter { !shown.contains($0) }
        VStack(alignment: .leading, spacing: MT.Space.s12) {
            PageHeader(title: "Widgets", text: "Choose what sits in the bar and in what order. Changes show up right away.")
            Card {
                ForEach(Array(shown.enumerated()), id: \.element) { index, widget in
                    if index > 0 { Divider() }
                    WidgetRow(widget: widget, on: true) {
                        Button { move(widget, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("Move earlier")
                        Button { move(widget, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == shown.count - 1).help("Move later")
                        Button { model.setWidgets(shown.filter { $0 != widget }) } label: { Image(systemName: "minus.circle.fill") }
                            .foregroundStyle(Color.mtBad).help("Remove from the bar")
                    }
                }
                if shown.isEmpty { Text("The bar is empty apart from the file browser.").padding(MT.Space.s12) }
            }
            if !hidden.isEmpty {
                Text("Not in the bar").font(.headline).padding(.top, MT.Space.s6)
                Card {
                    ForEach(Array(hidden.enumerated()), id: \.element) { index, widget in
                        if index > 0 { Divider() }
                        WidgetRow(widget: widget, on: false) {
                            Button { model.setWidgets(shown + [widget]) } label: { Image(systemName: "plus.circle.fill") }
                                .foregroundStyle(Color.mtGood).help("Add to the bar")
                        }
                    }
                }
            }
            Button("Reset to Default") { model.setWidgets(Widget.allCases) }.padding(.top, MT.Space.s6)
        }
    }

    private func move(_ widget: Widget, by delta: Int) {
        var list = model.widgets
        guard let i = list.firstIndex(of: widget), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        model.setWidgets(list)
    }
}

private struct WidgetRow<Actions: View>: View {
    let widget: Widget, on: Bool
    @ViewBuilder let actions: Actions
    var body: some View {
        HStack(spacing: MT.Space.s10) {
            Image(systemName: widget.symbol).frame(width: 22).foregroundStyle(on ? Color.mtGood : Color.mtInkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.title)
                Text(widget.detail).font(.caption).foregroundStyle(Color.mtInkMuted)
            }
            Spacer()
            actions.buttonStyle(.borderless).imageScale(.large)
        }
        .padding(.horizontal, MT.Space.s12).padding(.vertical, MT.Space.s8)
    }
}

private struct GroupsPage: View {
    let model: any CustomizeStore
    let offerImport: Bool
    @State private var groups: [GroupsFile.Group] = []

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s12) {
            PageHeader(title: "App Groups", text: "Pinned apps, in groups separated by a line in the bar. "
                       + "You can also drag apps onto the bar, or off it to unpin.")
            if offerImport {
                Button { importDock() } label: { Label("Use My Dock's Apps", systemImage: "square.and.arrow.down") }
                    .help("Replace these groups with the apps pinned in the macOS Dock, in one group")
            }
            ForEach(groups.indices, id: \.self) { g in
                Card {
                    HStack {
                        TextField("Group name", text: Binding(get: { groups[g].name }, set: { groups[g].name = $0; save() }))
                            .textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Button { pickApps(into: g) } label: { Image(systemName: "plus") }.help("Add apps")
                        Button { groups.remove(at: g); save() } label: { Image(systemName: "trash") }.help("Delete this group")
                    }
                    .buttonStyle(.borderless).padding(MT.Space.s12)
                    Divider()
                    ForEach(groups[g].apps, id: \.self) { path in
                        HStack(spacing: MT.Space.s8) {
                            Image(nsImage: IconCache.icon(path)).resizable().frame(width: 20, height: 20)
                            Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                            Spacer()
                            Button { groups[g].apps.removeAll { $0 == path }; save() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(Color.mtInkMuted).help("Unpin")
                        }
                        .padding(.horizontal, MT.Space.s12).padding(.vertical, MT.Space.s4)
                    }
                    if groups[g].apps.isEmpty { Text("No apps yet").foregroundStyle(Color.mtInkMuted).padding(MT.Space.s12) }
                }
            }
            HStack {
                Button { groups.append(.init(name: "New Group", apps: [])); save() } label: { Label("Add Group", systemImage: "plus") }
                Spacer()
                Button("Open groups.json") { _ = GroupsFile.load(); NSWorkspace.shared.open(GroupsFile.url) }
                    .help("The same settings as a text file, for hand editing")
            }
        }
        .onAppear { groups = model.groupList }
    }

    private func save() { model.setGroups(groups) }

    private func importDock() {
        let apps = DockImport.apps()
        guard !apps.isEmpty else { return NSSound.beep() }
        groups = [.init(name: "Apps", apps: apps)]
        save()
    }

    private func pickApps(into g: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        groups[g].apps += panel.urls.map(\.path).filter { !groups[g].apps.contains($0) }
        save()
    }
}

private struct PermissionsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s12) {
            PageHeader(title: "Permissions", text: "Pier works without these, with fewer features. macOS asks once; "
                       + "you can change them any time in System Settings › Privacy & Security.")
            // Re-read every second so a grant made in System Settings shows up here without reopening.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Card {
                    PermissionRow(title: "Accessibility", symbol: "accessibility",
                                  text: "Window menus and tab groups, unread badges, keeping windows clear of the bar, pasting screenshots.",
                                  granted: AXIsProcessTrusted()) {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    Divider()
                    PermissionRow(title: "Screen Recording", symbol: "rectangle.dashed.badge.record",
                                  text: "Window previews when you hover an app, and minimized-window thumbnails. Nothing is saved or sent.",
                                  granted: CGPreflightScreenCaptureAccess()) {
                        if !CGRequestScreenCaptureAccess() {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String, symbol: String, text: String, granted: Bool
    let request: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: MT.Space.s10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(granted ? Color.mtGood : Color.mtInkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text).font(.caption).foregroundStyle(Color.mtInkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mtGood)
            } else {
                Button("Allow…", action: request)
            }
        }
        .padding(MT.Space.s12)
    }
}

private struct SearchPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s12) {
            PageHeader(title: "Search", text: "One panel for apps, System Settings, files, links and screenshots.")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let spotlight = SearchHotkey.spotlightHasCommandSpace
                Card {
                    ShortcutRow(keys: "⌥ Space", text: "Always opens Pier's search.", on: true)
                    Divider()
                    ShortcutRow(keys: "⌘ Space", text: spotlight
                                ? "Opens Spotlight now. Turn off Spotlight's shortcut and it opens Pier's search instead."
                                : "Opens Pier's search (Spotlight's shortcut is off).", on: !spotlight)
                    if spotlight {
                        Button("Open Keyboard Shortcuts…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .padding([.horizontal, .bottom], MT.Space.s12)
                    }
                }
            }
            Text("Other tools (Hammerspoon, a mouse utility) can open search by posting the distributed notification "
                 + "`app.newitools.pier.search`.")
                .font(.caption).foregroundStyle(Color.mtInkMuted).textSelection(.enabled)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String, text: String, on: Bool
    var body: some View {
        HStack(spacing: MT.Space.s10) {
            Text(keys).font(.body.monospaced()).padding(.horizontal, MT.Space.s8).padding(.vertical, MT.Space.s4)
                .background(Color.mtFillInset, in: .rect(cornerRadius: MT.Radius.control))
            Text(text).foregroundStyle(on ? Color.mtInk : Color.mtInkMuted).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(MT.Space.s12)
    }
}

// MARK: Preview

/// `Pier --customize-preview DIR`: renders the walkthrough and Customize pages to PNGs offscreen, with
/// made-up data. No window is shown and the real bar, settings and Dock are untouched.
@MainActor
enum CustomizePreview {
    @Observable final class Store: CustomizeStore {
        var widgets: [Widget] = Widget.allCases.filter { $0 != .projects && $0 != .macTools }
        var groupList: [GroupsFile.Group] = [
            .init(name: "Work", apps: ["/System/Applications/Mail.app", "/System/Applications/Calendar.app", "/System/Applications/Notes.app"]),
            .init(name: "Web", apps: ["/Applications/Safari.app"]),
        ]
        func setWidgets(_ list: [Widget]) { widgets = list }
        func setGroups(_ list: [GroupsFile.Group]) { groupList = list }
    }

    static func run(into folder: String) {
        let store = Store()
        let shots: [(String, AnyView)] = [
            ("1-welcome", AnyView(Walkthrough(model: store) {})),
            ("2-widgets", AnyView(CustomizeView(model: store))),
        ] + Page.allCases.filter { $0 != .widgets }.enumerated().map { i, page in
            ("\(i + 3)-\(page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
             AnyView(CustomizeView(model: store, page: page)))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view) in shots {
                let host = NSHostingView(rootView: view.frame(width: 560, height: 480))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let suffix = appearance == .darkAqua ? "-dark" : ""
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + suffix + ".png"))
            }
        }
        print("wrote \(shots.count * 2) pictures to \(folder)")
    }
}
