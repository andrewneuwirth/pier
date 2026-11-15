import AppKit
import SwiftUI
import MacToolsKit

/// Customize Pier (right-click the bar), and the same pages as a walkthrough on the first launch.
@MainActor
enum CustomizeWindow {
    private static var window: NSWindow?

    static func show(_ model: any CustomizeStore, walkthrough: Bool = false) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = walkthrough
            ? AnyView(Walkthrough(model: model) { window?.close() }.frame(minWidth: 620, minHeight: 560))
            : AnyView(CustomizeView(model: model).frame(minWidth: 760, minHeight: 540))
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.minSize]   // the window can grow; SwiftUI only sets the floor
        let w = NSWindow(contentViewController: host)
        w.title = walkthrough ? "Welcome to Pier" : "Customize Pier"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = walkthrough
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.setContentSize(walkthrough ? NSSize(width: 680, height: 600) : NSSize(width: 920, height: 660))
        w.setFrameAutosaveName(walkthrough ? "PierWalkthrough" : "PierCustomize")
        if w.frame.origin == .zero { w.center() }
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

enum Page: String, CaseIterable, Identifiable, Hashable {
    case widgets = "Widgets", groups = "App Groups", permissions = "Permissions", search = "Search"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .widgets: "square.stack.3d.up.fill"
        case .groups: "square.grid.2x2.fill"
        case .permissions: "lock.shield.fill"
        case .search: "magnifyingglass"
        }
    }
    var tint: Color {
        switch self {
        case .widgets: .blue
        case .groups: .orange
        case .permissions: .green
        case .search: .purple
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

struct CustomizeView: View {
    let model: any CustomizeStore
    @State var page: Page? = .widgets

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label { Text(p.rawValue) } icon: { SettingsIcon(symbol: p.symbol, tint: p.tint) }
                    .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            (page ?? .widgets).view(model, walkthrough: false)
                .navigationTitle((page ?? .widgets).rawValue)
        }
    }
}

/// The small rounded-square icon System Settings puts beside each sidebar item.
private struct SettingsIcon: View {
    let symbol: String, tint: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

/// Welcome, then each page in turn, then done. Every step can be skipped and changed later in Customize.
struct Walkthrough: View {
    let model: any CustomizeStore
    let finish: () -> Void
    @State var step = 0
    private let pages: [Page] = [.groups, .widgets, .permissions, .search]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if step == 0 {
                    Hero(symbol: "dock.rectangle", title: "Welcome to Pier",
                         text: "Pier replaces the macOS Dock with app groups, search, downloads and live stats. "
                             + "A few quick steps set it up; everything can be changed later by right-clicking the bar › Customize Pier…")
                } else if step <= pages.count {
                    VStack(spacing: 0) {
                        HStack(spacing: MT.Space.s10) {
                            SettingsIcon(symbol: pages[step - 1].symbol, tint: pages[step - 1].tint)
                            Text(pages[step - 1].rawValue).font(.title2.bold())
                            Spacer()
                        }
                        .padding(.horizontal, MT.Space.s26).padding(.top, MT.Space.s26 + MT.Space.s12)
                        pages[step - 1].view(model, walkthrough: true)
                    }
                } else {
                    Hero(symbol: "checkmark.circle.fill", title: "You're set",
                         text: "Drag apps onto the bar to pin them, right-click a tile for its options, and press ⌥Space to search. "
                             + "Quit Pier from the bar's right-click menu to get the macOS Dock back.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step > 0 && step <= pages.count {
                    HStack(spacing: 6) {
                        ForEach(1...pages.count, id: \.self) { i in
                            Capsule().fill(i == step ? Color.accentColor : Color.mtRingTrack).frame(width: i == step ? 18 : 6, height: 6)
                        }
                    }
                    .animation(MT.Motion.quick, value: step)
                }
                Spacer()
                Button(step > pages.count ? "Done" : step == 0 ? "Get Started" : "Continue") {
                    if step > pages.count { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(MT.Space.s18)
        }
        .background(.background)
    }
}

private struct Hero: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: MT.Space.s18) {
            if symbol == "dock.rectangle" {
                BarPreview(widgets: Widget.allCases, scale: 0.85)
            } else {
                Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(Color.mtGood)
            }
            Text(title).font(.largeTitle.bold())
            Text(text).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
        }
        .padding(MT.Space.s26)
    }
}

// MARK: Drawn previews

/// A tile drawn like Pier's own glyph tiles: a soft gradient square with a symbol.
private struct MiniTile: View {
    var symbol: String? = nil
    var color: Color
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color.mix(with: .black, by: 0.25)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { if let symbol { Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white) } }
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
    }
}

private struct MiniRing: View {
    let value: Double, color: Color, size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Color.mtRingTrack, lineWidth: size * 0.14)
            Circle().trim(from: 0, to: value).stroke(color, style: .init(lineWidth: size * 0.14, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: size * 0.8, height: size * 0.8).frame(width: size, height: size)
    }
}

private struct MiniDivider: View {
    var size: CGFloat
    var body: some View { Capsule().fill(Color.mtHairline).frame(width: 1.5, height: size * 0.8) }
}

/// What one widget looks like in the bar, drawn with shapes (no real apps or data).
struct WidgetArt: View {
    let widget: Widget
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: size * 0.18) {
            switch widget {
            case .groups:
                MiniTile(color: .blue, size: size); MiniTile(color: .orange, size: size); MiniTile(color: .pink, size: size)
                MiniDivider(size: size)
                MiniTile(color: .teal, size: size); MiniTile(color: .indigo, size: size)
            case .recent:
                ForEach([Color.green, .purple, .red], id: \.self) { c in
                    VStack(spacing: 2) { MiniTile(color: c, size: size); Circle().fill(Color.mtInkMuted).frame(width: 3, height: 3) }
                }
                Text("+2").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: size, height: size).background(Color.mtFillInset, in: .rect(cornerRadius: size * 0.24))
            case .search: MiniTile(symbol: "magnifyingglass", color: .gray, size: size)
            case .stats:
                MiniRing(value: 0.62, color: .mtGood, size: size)
                MiniRing(value: 0.35, color: .mtClaude, size: size)
                MiniRing(value: 0.8, color: .mtChatGPT, size: size)
            case .minimized:
                ForEach(0..<2, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color.mtSurface)
                        .frame(width: size * 1.1, height: size * 0.75)
                        .overlay(alignment: .top) { Rectangle().fill(i == 0 ? Color.blue.opacity(0.5) : Color.orange.opacity(0.5)).frame(height: size * 0.16) }
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.mtHairline))
                }
            case .quickLinks: MiniTile(symbol: "link", color: .cyan, size: size)
            case .projects: MiniTile(symbol: "folder.fill", color: .mtProjects, size: size)
            case .macTools: MiniTile(symbol: "hammer.fill", color: .mtGood, size: size)
            case .downloads: MiniTile(symbol: "arrow.down", color: .blue, size: size)
                    .overlay(alignment: .topTrailing) { Circle().fill(Color.mtBad).frame(width: size * 0.32).offset(x: 3, y: -3) }
            case .trash: MiniTile(symbol: "trash.fill", color: .gray, size: size)
            }
        }
    }
}

/// The whole bar as it would look with these widgets, in order, with the same dividers Pier draws.
struct BarPreview: View {
    let widgets: [Widget]
    var scale: CGFloat = 1

    var body: some View {
        let size = 24 * scale
        HStack(spacing: size * 0.22) {
            MiniTile(symbol: "face.smiling", color: .blue, size: size)   // the file browser, always first
            ForEach(Array(widgets.enumerated()), id: \.element) { index, widget in
                if index == 0 || widgets[index - 1].cluster != widget.cluster { MiniDivider(size: size) }
                WidgetArt(widget: widget, size: size)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(size * 0.3)
        .background(.regularMaterial, in: .rect(cornerRadius: size * 0.55, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.55, style: .continuous).stroke(Color.mtHairline))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(MT.Motion.panel, value: widgets)
    }
}

// MARK: Widgets page

private struct WidgetsPage: View {
    let model: any CustomizeStore
    @State private var dragging: Widget?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: MT.Space.s12)]

    var body: some View {
        let shown = model.widgets
        let hidden = Widget.allCases.filter { !shown.contains($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: MT.Space.s18) {
                // The live bar: what you'll get, updated as you change things.
                VStack(spacing: MT.Space.s10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        BarPreview(widgets: shown).padding(.vertical, MT.Space.s12).padding(.horizontal, MT.Space.s4)
                            .frame(maxWidth: .infinity)
                    }
                    Text("Drag cards to reorder. Changes show up in the bar right away.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(MT.Space.s18)
                .background(Color.mtFillInset, in: .rect(cornerRadius: MT.Radius.panel))

                section("In the bar", count: shown.count) {
                    LazyVGrid(columns: columns, spacing: MT.Space.s12) {
                        ForEach(shown) { widget in
                            WidgetCard(widget: widget, inBar: true, dimmed: dragging == widget) {
                                model.setWidgets(shown.filter { $0 != widget })
                            }
                            .draggable(widget.rawValue) { WidgetArt(widget: widget).padding(8).onAppear { dragging = widget } }
                            .dropDestination(for: String.self) { items, _ in
                                defer { dragging = nil }
                                guard let name = items.first, let moved = Widget(rawValue: name), moved != widget else { return false }
                                var list = shown.filter { $0 != moved }
                                list.insert(moved, at: list.firstIndex(of: widget) ?? list.endIndex)
                                model.setWidgets(list)
                                return true
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing but the file browser. Add widgets from below.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(MT.Space.s26)
                            .background(Color.mtFillInset, in: .rect(cornerRadius: MT.Radius.card))
                    }
                }

                if !hidden.isEmpty {
                    section("More widgets", count: hidden.count) {
                        LazyVGrid(columns: columns, spacing: MT.Space.s12) {
                            ForEach(hidden) { widget in
                                WidgetCard(widget: widget, inBar: false, dimmed: false) { model.setWidgets(shown + [widget]) }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Reset to Default") { model.setWidgets(Widget.allCases) }
                }
            }
            .padding(MT.Space.s26)
        }
    }

    private func section(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MT.Space.s10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

private struct WidgetCard: View {
    let widget: Widget, inBar: Bool, dimmed: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color.mtFillInset)
                WidgetArt(widget: widget, size: 28)
                    .saturation(inBar ? 1 : 0.4).opacity(inBar ? 1 : 0.75)
            }
            .frame(height: 78)
            .overlay(alignment: .topTrailing) {
                Button(action: toggle) {
                    Image(systemName: inBar ? "minus" : "plus")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(inBar ? Color.mtBad : Color.mtGood, in: .circle)
                }
                .buttonStyle(.plain)
                .help(inBar ? "Remove from the bar" : "Add to the bar")
                .accessibilityLabel(inBar ? "Remove \(widget.title)" : "Add \(widget.title)")
                .padding(MT.Space.s8)
                .opacity(hovered || !inBar ? 1 : 0.0001)   // still clickable, and VoiceOver still finds it
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(widget.title, systemImage: widget.symbol).font(.headline)
                Text(widget.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .padding(MT.Space.s12)
        }
        .background(Color.mtSurface)
        .clipShape(.rect(cornerRadius: MT.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MT.Radius.card, style: .continuous)
            .stroke(hovered ? Color.accentColor.opacity(0.6) : Color.mtHairline, lineWidth: hovered ? 1.5 : 1))
        .shadow(color: .black.opacity(hovered ? 0.1 : 0.04), radius: hovered ? 8 : 3, y: 2)
        .opacity(dimmed ? 0.4 : 1)
        .scaleEffect(hovered ? 1.01 : 1)
        .animation(MT.Motion.quick, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: toggle)
    }
}

// MARK: App Groups page

private struct GroupsPage: View {
    let model: any CustomizeStore
    let offerImport: Bool
    @State private var groups: [GroupsFile.Group] = []

    var body: some View {
        Form {
            if offerImport {
                Section {
                    LabeledContent {
                        Button("Use My Dock's Apps") { importDock() }
                    } label: {
                        Text("Start from your Dock")
                        Text("Replace these groups with the apps pinned in the macOS Dock.")
                    }
                }
            }
            ForEach(groups.indices, id: \.self) { g in
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: MT.Space.s8)], spacing: MT.Space.s10) {
                        ForEach(groups[g].apps, id: \.self) { path in
                            AppChip(path: path) { groups[g].apps.removeAll { $0 == path }; save() }
                        }
                        Button { pickApps(into: g) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.title3).frame(width: 40, height: 40)
                                    .background(Color.mtFillInset, in: .rect(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(style: .init(lineWidth: 1, dash: [3])).foregroundStyle(.secondary))
                                Text("Add").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 76)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, MT.Space.s4)
                } header: {
                    HStack {
                        TextField("Group name", text: Binding(get: { groups[g].name }, set: { groups[g].name = $0; save() }), prompt: Text("Group name"))
                            .labelsHidden().textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Button(role: .destructive) { groups.remove(at: g); save() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this group")
                    }
                }
            }
            Section {
                HStack {
                    Button { groups.append(.init(name: "New Group", apps: [])); save() } label: { Label("Add Group", systemImage: "plus") }
                    Spacer()
                    Button("Open groups.json") { _ = GroupsFile.load(); NSWorkspace.shared.open(GroupsFile.url) }
                        .help("The same settings as a text file, for hand editing")
                }
            } footer: {
                Text("Groups are separated by a line in the bar. You can also drag apps onto the bar, or off it to unpin.")
            }
        }
        .formStyle(.grouped)
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

private struct AppChip: View {
    let path: String
    let remove: () -> Void
    @State private var hovered = false
    var body: some View {
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(path)).resizable().frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.mtInkMuted)
                    }
                    .buttonStyle(.plain).offset(x: 6, y: -6).opacity(hovered ? 1 : 0.0001)
                    .help("Unpin \(name)").accessibilityLabel("Unpin \(name)")
                }
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 76)
        .onHover { hovered = $0 }
    }
}

// MARK: Permissions and Search

private struct PermissionsPage: View {
    var body: some View {
        // Re-read every second so a grant made in System Settings shows up here without reopening.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    PermissionRow(title: "Accessibility", symbol: "accessibility", tint: .blue,
                                  text: "Window menus and tab groups, unread badges, keeping windows clear of the bar, pasting screenshots.",
                                  granted: AXIsProcessTrusted()) {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    PermissionRow(title: "Screen Recording", symbol: "rectangle.dashed.badge.record", tint: .red,
                                  text: "Window previews when you hover an app, and minimized-window thumbnails. Nothing is saved or sent.",
                                  granted: CGPreflightScreenCaptureAccess()) {
                        if !CGRequestScreenCaptureAccess() {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                } footer: {
                    Text("Pier works without these, with fewer features. Change them any time in System Settings › Privacy & Security.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct PermissionRow: View {
    let title: String, symbol: String, tint: Color, text: String, granted: Bool
    let request: () -> Void
    var body: some View {
        LabeledContent {
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mtGood)
            } else {
                Button("Allow…", action: request)
            }
        } label: {
            Label { Text(title); Text(text) } icon: { SettingsIcon(symbol: symbol, tint: tint) }
        }
    }
}

private struct SearchPage: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let spotlight = SearchHotkey.spotlightHasCommandSpace
            Form {
                Section {
                    LabeledContent {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mtGood)
                    } label: {
                        Label { Text("⌥ Space"); Text("Always opens Pier's search.") } icon: { SettingsIcon(symbol: "option", tint: .purple) }
                    }
                    LabeledContent {
                        if spotlight {
                            Button("Open Keyboard Shortcuts…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            }
                        } else {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mtGood)
                        }
                    } label: {
                        Label {
                            Text("⌘ Space")
                            Text(spotlight ? "Opens Spotlight now. Turn off Spotlight's shortcut and it opens Pier's search instead."
                                           : "Opens Pier's search (Spotlight's shortcut is off).")
                        } icon: { SettingsIcon(symbol: "command", tint: .gray) }
                    }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("Search finds apps, System Settings panes, files, links and your newest screenshots.")
                }
                Section("Automation") {
                    LabeledContent("Open search", value: "app.newitools.pier.search").textSelection(.enabled)
                    LabeledContent("Paste newest screenshot", value: "app.newitools.pier.pasteScreenshot").textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        }
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
        let size = NSSize(width: 920, height: 660)
        var shots: [(String, AnyView, NSSize)] = [
            ("1-welcome", AnyView(Walkthrough(model: store) {}), NSSize(width: 680, height: 600)),
            ("1b-step", AnyView(Walkthrough(model: store, finish: {}, step: 2)), NSSize(width: 680, height: 600)),
        ]
        for (i, page) in Page.allCases.enumerated() {
            shots.append(("\(i + 2)-\(page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                          AnyView(CustomizeView(model: store, page: page)), size))
        }
        // NavigationSplitView and Form need a real window to lay out; it's never ordered on screen.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view, size) in shots {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // let the split view and grids settle
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let suffix = appearance == .darkAqua ? "-dark" : ""
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + suffix + ".png"))
            }
        }
        print("wrote \(shots.count * 2) pictures to \(folder)")
    }
}
