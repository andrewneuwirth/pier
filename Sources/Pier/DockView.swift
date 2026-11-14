import AppKit
import SwiftUI
import MacToolsKit

/// NSWorkspace icons are expensive to fetch on every redraw.
@MainActor
enum IconCache {
    private static var icons: [String: (stamp: Date?, image: NSImage)] = [:]
    private static var apps: [String: (source: String, stamp: Date?, image: NSImage)] = [:]

    /// The bundle's modification date: a reinstall at the same path (rebuilt app, update) changes it,
    /// so its new icon is read instead of the cached one.
    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func icon(_ path: String) -> NSImage {
        let stamp = stamp(path)
        if let hit = icons[path], hit.stamp == stamp { return hit.image }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = (stamp, icon)
        return icon
    }

    /// The icon an app shows in the Dock, which can differ from its file's: one you picked in Pier
    /// (Change Icon…), else one the app records choosing (ChatGPT saves DockIconResourceName, an
    /// image in its bundle). Apps that only swap the icon in memory can't be read from outside.
    static func appIcon(_ item: AppItem, override: String?) -> NSImage {
        let source = source(item, override: override)
        let stamp = stamp(item.url.path)
        if let cached = apps[item.url.path], cached.source == source, cached.stamp == stamp { return cached.image }
        let image = source.isEmpty ? nil : NSImage(contentsOfFile: source)
        let result = image ?? icon(item.url.path)
        apps[item.url.path] = (source, stamp, result)
        return result
    }

    /// True when the app's chosen icon changed, or the app was reinstalled, since it was last drawn.
    static func changed(_ item: AppItem, override: String?) -> Bool {
        guard let cached = apps[item.url.path] else { return false }
        return cached.source != source(item, override: override) || cached.stamp != stamp(item.url.path)
    }

    private static func source(_ item: AppItem, override: String?) -> String {
        if let override, FileManager.default.fileExists(atPath: override) { return override }
        if let id = item.bundleID,
           let name = CFPreferencesCopyAppValue("DockIconResourceName" as CFString, id as CFString) as? String,
           !name.contains("/") {
            let path = item.url.appendingPathComponent("Contents/Resources/\(name)").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return ""
    }
}

extension EnvironmentValues {
    @Entry var tileSize: CGFloat = DockModel.maxTile
    @Entry var dockEdge = DockEdge.bottom
}

/// How the bar's views turn with the edge, so they are written once.
extension DockEdge {
    /// Tiles one after another along the bar.
    func stack(spacing: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        (self == .bottom ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))) { content() }
    }
    /// An icon, then what sits between it and the screen edge (the running dot).
    func cross(spacing: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        (self == .bottom ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))) { content() }
    }
    var screenSide: Edge.Set { self == .bottom ? .bottom : .trailing }
    var headroom: Edge.Set { self == .bottom ? .top : .leading }
    var alongAxis: Edge.Set { self == .bottom ? .horizontal : .vertical }
    var acrossAxis: Edge.Set { self == .bottom ? .vertical : .horizontal }
    var anchor: UnitPoint { self == .bottom ? .bottom : .trailing }
    /// Positive `across` moves toward the screen edge.
    func offset(along: CGFloat = 0, across: CGFloat = 0) -> CGSize {
        self == .bottom ? CGSize(width: along, height: across) : CGSize(width: across, height: along)
    }
    /// Where the drop line goes on a tile: its start or its end, along the bar.
    func side(after: Bool) -> Alignment {
        self == .bottom ? (after ? .trailing : .leading) : (after ? .bottom : .top)
    }
}

private extension View {
    func frame(_ edge: DockEdge, along: CGFloat? = nil, across: CGFloat? = nil) -> some View {
        frame(width: edge == .bottom ? along : across, height: edge == .bottom ? across : along)
    }
}

struct DockView: View {
    let controller: DockController
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        let model = controller.model
        let edge = model.edge
        edge.stack(spacing: MT.Space.s4) {
            AppTile(item: model.finder, controller: controller)
            ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                GroupDivider()
                ForEach(group) { AppTile(item: $0, controller: controller) }
            }
            if !model.recent.isEmpty || !model.overflow.isEmpty {
                GroupDivider()
                ForEach(model.recent) { AppTile(item: $0, controller: controller) }
                if !model.overflow.isEmpty { OverflowTile(controller: controller) }
            }
            GroupDivider()
            SearchTile(controller: controller)
            StatsCluster(model: model, controller: controller)
            GroupDivider()
            if !controller.minimized.windows.isEmpty {
                // Like the macOS Dock: minimized windows get their own section.
                ForEach(controller.minimized.windows) { MinimizedTile(window: $0, minimized: controller.minimized) }
                GroupDivider()
            }
            LinksTile(controller: controller, kind: .quick)
            LinksTile(controller: controller, kind: .projects)
            MacToolsTile(controller: controller)
            DownloadsTile(controller: controller)
            TrashTile(controller: controller)
        }
        .padding(MT.Space.s6)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
        .environment(\.tileSize, model.tileSize)
        .environment(\.dockEdge, edge)
        .contextMenu {
            Button("Edit Groups…") { controller.editGroups() }
            Menu("Show On") {
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { controller.screenName == name },
                                               set: { if $0 { controller.show(on: name) } }))
                }
            }
            Menu("Position") {
                ForEach(DockEdge.allCases, id: \.self) { choice in
                    Toggle(choice.title, isOn: Binding(get: { edge == choice }, set: { if $0 { controller.setEdge(choice) } }))
                }
            }
            Toggle("Open at Login", isOn: $openAtLogin)
            Divider()
            Button("Quit Pier") { controller.quit() }
        }
        .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
        // Clear headroom beyond the glass, so a bouncing or hovered icon isn't clipped by the window edge.
        .fixedSize().padding(edge.headroom, 12)
    }
}

private struct GroupDivider: View {
    @Environment(\.dockEdge) private var edge

    var body: some View {
        Capsule().fill(Color.mtRingTrack).frame(edge, along: 1, across: 32).padding(edge.alongAxis, MT.Space.s4)
            .padding(edge.screenSide, 7)   // centred on the icons, not the running dots
    }
}

/// An icon with the running dot under it (beside it, toward the screen, on the right edge), as every
/// tile in the bar is laid out.
private struct Tile<Icon: View>: View {
    var running = false
    /// Replaces the running dot's colour: amber needs you, green finished.
    var attention: MTStatus? = nil
    /// Each change plays one gentle bounce (the macOS Dock's, quieter).
    var bounce = 0
    @ViewBuilder var icon: Icon
    @Environment(\.tileSize) private var size
    @Environment(\.dockEdge) private var edge
    @State private var hovering = false

    var body: some View {
        edge.cross(spacing: 3) {
            icon.frame(width: size, height: size)
                .phaseAnimator(MT.Motion.allowed(.default) == nil ? [0] : [0, -10, 0, -5, 0], trigger: bounce) { icon, lift in
                    icon.offset(edge.offset(across: lift))
                } animation: { _ in .spring(response: 0.22, dampingFraction: 0.6) }
            Circle().fill(attention?.color ?? Color.mtInk.opacity(running ? 0.75 : 0))
                .frame(width: attention == nil ? 4 : 6, height: attention == nil ? 4 : 6)
                .frame(edge, across: 4)
        }
        .scaleEffect(hovering ? 1.08 : 1, anchor: edge.anchor)
        .animation(MT.Motion.allowed(MT.Motion.quick), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

private struct AppTile: View {
    let item: AppItem
    let controller: DockController
    @State private var frame: CGRect = .zero
    @Environment(\.dockEdge) private var edge

    var body: some View {
        let model = controller.model
        let reorder = controller.reorder
        Tile(running: model.isRunning(item), attention: model.attention[item.id], bounce: model.bounces[item.id] ?? 0) {
            Image(nsImage: model.icon(for: item)).resizable().interpolation(.high)
        }
        .overlay(alignment: .topTrailing) {
            // Past the running dot's strip, onto the icon's own corner (no change at the bottom edge).
            if let badge = model.badges[item.id] { Badge(text: badge).padding(edge.screenSide, 7) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame = $0
            controller.tileFrames[item.id] = $0
        }
        .onHover { controller.hoverChanged(item, inside: $0, frame: frame) }
        .onTapGesture {
            controller.closeCard()
            model.open(item)
        }
        // Reorder by dragging inside the bar; drag off it, away from the screen edge, to remove. (A system drag session
        // never reached the bar's own drop targets, so this is a plain gesture.)
        .offset(reorder.dragging == item.id ? reorder.offset : .zero)
        .opacity(reorder.dragging == item.id && reorder.removing ? 0.35 : 1)
        .zIndex(reorder.dragging == item.id ? 1 : 0)
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { controller.dragChanged(item, $0) }
            .onEnded { controller.dragEnded(item, $0) })
        .overlay(alignment: edge.side(after: reorder.target?.after == true)) {
            if reorder.target?.id == item.id {
                Capsule().fill(Color.accentColor).frame(edge, along: 3).padding(edge.acrossAxis, 4)
                    .offset(edge.offset(along: reorder.target?.after == true ? 4 : -4))
            }
        }
        // Right-click is handled by DockController (the app's own Dock items plus Pier's).
        .accessibilityLabel(model.badges[item.id].map { "\(item.name), \($0) unread" } ?? item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// Right-click menu for any app, in the bar or the overflow grid.
private struct AppMenu: View {
    let item: AppItem
    let model: DockModel

    var body: some View {
        if item != model.finder {
            Menu("Keep in Pier") {
                ForEach(Array(model.groupNames.enumerated()), id: \.offset) { index, name in
                    Button(name) { model.pin(item, toGroup: index) }
                }
            }
            if model.isPinned(item) {
                Button("Remove from Pier") { model.unpin(item) }
            } else {
                Button("Hide from Pier") { model.hide(item) }
            }
            Divider()
        }
        Button("Change Icon…") { model.chooseIcon(for: item) }
        if model.hasCustomIcon(item) { Button("Use Original Icon") { model.setIcon(nil, for: item) } }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if model.isRunning(item) {
            Divider()
            Button("Quit") { model.quit(item) }
        }
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.mtBad, in: .capsule)
            .offset(x: 4, y: -2)
            .allowsHitTesting(false)
    }
}

/// "+N": the open apps that didn't make the 4 most recent.
private struct OverflowTile: View {
    let controller: DockController
    @State private var frame: CGRect = .zero
    @Environment(\.tileSize) private var size

    var body: some View {
        let count = controller.model.overflow.count
        Tile(running: true) {
            Text("+\(count)")
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Color.mtInk)
                .frame(width: size * 0.82, height: size * 0.82)
                .background(Color.mtFillHover, in: .rect(cornerRadius: size * 0.22))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onTapGesture { controller.toggleGrid(.openApps, from: frame) }
        .help("\(count) more open apps")
        .accessibilityLabel("\(count) more open apps")
        .accessibilityAddTraits(.isButton)
    }
}

private struct DownloadsTile: View {
    let controller: DockController
    @State private var frame: CGRect = .zero

    var body: some View {
        Tile {
            Image(nsImage: IconCache.icon(DownloadsModel.folder.path)).resizable()
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onTapGesture { controller.toggleGrid(.downloads, from: frame) }
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .accessibilityAddTraits(.isButton)
    }
}

private struct TrashTile: View {
    let controller: DockController
    private static let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    var body: some View {
        Tile {
            Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage()).resizable()
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.trashFrame = $0 }
        .onTapGesture { NSWorkspace.shared.open(Self.trash) }
        .help("Trash")
        .accessibilityLabel("Trash")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Stats

private struct StatsCluster: View {
    let model: DockModel
    let controller: DockController
    @State private var memFrame: CGRect = .zero
    @Environment(\.dockEdge) private var edge

    var body: some View {
        let gb = 1_073_741_824.0
        let memPercent = model.memoryUsed / model.memoryTotal * 100
        GlassEffectContainer(spacing: 0) {
            edge.stack(spacing: MT.Space.s4) {
                usageRing("Claude", model.usage?.claude, tint: .mtClaude)
                usageRing("ChatGPT", model.usage?.chatgpt, tint: .mtChatGPT)
                MiniRing(percent: memPercent, secondary: nil, label: "MEM", base: .mtInk,
                         detail: String(format: "Memory: %.1f of %.0f GB used", model.memoryUsed / gb, model.memoryTotal / gb),
                         tooltip: false)   // the hover card replaces the tooltip
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { memFrame = $0 }
                    .onHover { controller.memoryHover($0, frame: memFrame) }
                    .onTapGesture {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                           configuration: .init())
                    }
                ThermalBadge(state: model.thermal)
            }
        }
        .padding(edge.screenSide, 7)
    }

    private func usageRing(_ name: String, _ reading: UsageSnapshot.Reading?, tint: Color) -> some View {
        var detail = name
        if let r = reading {
            if let s = r.short { detail += "\nSession: \(Int(s.percent.rounded()))% used" }
            if let l = r.long { detail += "\nWeek: \(Int(l.percent.rounded()))% used" }
            if r.stale { detail += "\nShowing the last reading" }
            if r.failed, let note = r.note { detail += "\n\(note)" }
        } else {
            detail += "\nNo reading yet."
        }
        return MiniRing(percent: reading?.primary?.percent, secondary: reading?.secondary?.percent,
                        label: name == "ChatGPT" ? "GPT" : name.uppercased(), base: tint, detail: detail)
            .opacity(reading?.failed == true ? 0.55 : reading?.stale == true ? 0.8 : 1)
    }
}

/// The design system's StatRing at bar size: 40pt instead of 56.
private struct MiniRing: View {
    let percent: Double?
    let secondary: Double?
    let label: String
    let base: Color
    let detail: String
    var tooltip = true

    var body: some View {
        ZStack {
            Arc(percent: percent ?? 0, width: 3, inset: 2, tint: usageTint(percent ?? 0, base: base))
            if let secondary { Arc(percent: secondary, width: 2, inset: 7.5, tint: base) }
            VStack(spacing: 0) {
                Group {
                    if let percent { Text("\(Int(percent.rounded()))").contentTransition(.numericText()) } else { Text("–") }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(MTStatus.forUsage(percent ?? 0)?.color ?? Color.mtInk)
                Text(label).font(.system(size: 6, weight: .semibold)).foregroundStyle(Color.mtInkMuted)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(MT.Motion.allowed(MT.Motion.value), value: percent)
        .help(tooltip ? detail : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }
}

private struct Arc: View {
    let percent: Double
    let width: CGFloat
    let inset: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.mtRingTrack, lineWidth: width)
            Circle().inset(by: width / 2)
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }
}

private struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        let (word, status): (String, MTStatus) = switch state {
        case .nominal: ("Normal", .good)
        case .fair: ("Warm", .warn)
        case .serious: ("Hot", .bad)
        case .critical: ("Critical", .bad)
        @unknown default: ("Normal", .good)
        }
        VStack(spacing: 2) {
            Image(systemName: "thermometer.medium").font(.system(size: 14, weight: .medium)).foregroundStyle(status.color)
            Text(word).font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.mtInkMuted)
        }
        .frame(width: 40, height: 40)
        .help("Thermal state: \(word)")
        .accessibilityElement(children: .combine)
    }
}

// MARK: Popups

struct HoverCard: View {
    let item: AppItem
    let app: NSRunningApplication?
    let previews: WindowPreviews
    let controller: DockController
    @State private var memory: UInt64?

    var body: some View {
        VStack(spacing: MT.Space.s8) {
            if let app {
                switch previews.state {
                case .loading:
                    EmptyView()
                case .none:
                    EmptyView()
                case .needsPermission:
                    Button("Allow Screen Recording for window previews") { WindowPreviews.requestCapture() }
                        .buttonStyle(.glass).controlSize(.small)
                case .shots(let shots):
                    HStack(alignment: .center, spacing: MT.Space.s8) {
                        ForEach(shots) { shot in
                            ShotView(shot: shot) {
                                controller.closeCard()
                                WindowPreviews.raise(shot, of: app)
                            } close: {
                                if WindowPreviews.close(shot, of: app) { previews.remove(shot) }
                            }
                        }
                    }
                }
            }
            Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mtInk)
            // An app with several windows: stack them into one place with tabs (or undo it).
            if let app, controller.tabs.windowCount(app) > 1 {
                let grouped = controller.tabs.isGrouped(app)
                Button(grouped ? "Ungroup Tabs" : "Group into Tabs", systemImage: "rectangle.stack") {
                    controller.closeCard()
                    if grouped { controller.tabs.ungroup(app) } else { controller.tabs.groupAll(app) }
                }
                .buttonStyle(.glass).controlSize(.small)
            }
            if app != nil, let memory {
                Text("\(AppMemory.format(memory)) memory").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Color.mtInkMuted)
            }
            ForEach(controller.model.agentNotes[item.id] ?? [], id: \.self) { note in
                Label(note, systemImage: note.hasSuffix("needs you") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(note.hasSuffix("needs you") ? Color.mtWarn : Color.mtGood)
            }
        }
        .padding(.horizontal, MT.Space.s12)
        .padding(.vertical, MT.Space.s8)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.card))
        .onHover { controller.cardHover($0) }
        .task { if app != nil { memory = await AppMemory.use(of: item.url.path) } }
    }
}

/// Hovering MEM: the apps holding the most memory, each with its share as a bar.
struct MemoryCard: View {
    let model: DockModel
    let controller: DockController
    @State private var apps: [AppMemory.Use]?
    private static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s8) {
            HStack {
                Text("MEMORY").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
                Spacer(minLength: MT.Space.s12)
                Text("\(AppMemory.format(UInt64(model.memoryUsed))) of \(AppMemory.format(UInt64(model.memoryTotal)))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Color.mtInkMuted)
            }
            if let apps {
                let top = Array(apps.prefix(Self.shown))
                let largest = Double(top.first?.bytes ?? 1)
                ForEach(top) { use in
                    HStack(spacing: MT.Space.s8) {
                        Image(nsImage: IconCache.icon(use.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(use.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mtInk).lineLimit(1)
                                Spacer(minLength: MT.Space.s8)
                                Text(AppMemory.format(use.bytes)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(Color.mtInkMuted)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Color.mtRingTrack)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.mtInk.opacity(0.55))
                                            .frame(width: geo.size.width * Double(use.bytes) / largest)
                                    }
                            }
                            .frame(height: 3)
                        }
                    }
                }
                Text("Click MEM for Activity Monitor").font(.system(size: 10)).foregroundStyle(Color.mtInkMuted)
            } else {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(Color.mtInkMuted)
            }
        }
        .padding(MT.Space.s12)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
        .onHover { controller.cardHover($0) }
        .task { apps = await AppMemory.snapshot() }
    }
}

private struct ShotView: View {
    let shot: WindowShot
    let action: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        VStack(spacing: MT.Space.s4) {
            // One box size for every window, the picture centred in it, so a small window doesn't
            // leave a stray thumbnail in a corner of the card.
            Image(nsImage: shot.image).resizable().scaledToFit()
                .clipShape(.rect(cornerRadius: MT.Radius.control))
                .frame(width: 180, height: 120)
            Text(shot.title.isEmpty ? " " : shot.title)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mtInkMuted)
                .lineLimit(1).frame(maxWidth: 180)
        }
        .padding(MT.Space.s6)
        .background(hovering || confirming ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .overlay(alignment: .topTrailing) {
            // Like Windows' taskbar previews: × on hover, then a confirm step before anything closes.
            if hovering && !confirming {
                Button { confirming = true } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.mtBad, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(MT.Space.s4)
                .help("Close Window")
                .accessibilityLabel("Close \(shot.title.isEmpty ? "window" : shot.title)")
            }
        }
        .overlay {
            if confirming {
                VStack(spacing: MT.Space.s8) {
                    Text("Close this window?").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mtInk)
                    HStack(spacing: MT.Space.s6) {
                        Button("Cancel") { confirming = false }
                            .buttonStyle(.glass)
                        Button("Close") {
                            confirming = false
                            close()
                        }
                        .buttonStyle(.glassProminent).tint(Color.mtBad)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.row))
            }
        }
        .animation(MT.Motion.allowed(MT.Motion.quick), value: hovering)
        .animation(MT.Motion.allowed(MT.Motion.quick), value: confirming)
        .contentShape(.rect)
        // After the overlays, so the × counts as inside the preview and the highlight doesn't flicker.
        .onHover { hovering = $0 }
        .onTapGesture { if !confirming { action() } }
    }
}

struct DownloadsGrid: View {
    let model: DownloadsModel
    let sendBox: SendBox
    let close: () -> Void
    private static let cell: CGFloat = 84
    private static let columns = 4

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s10) {
            HStack {
                Text("DOWNLOADS").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
                Spacer()
                Button("Open Folder") {
                    FileOpener.open(DownloadsModel.folder)
                    close()
                }
                .buttonStyle(.glass).controlSize(.small)
            }
            if model.items.isEmpty {
                Text("Nothing in Downloads yet").font(.system(size: 13)).foregroundStyle(Color.mtInkMuted)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let rows = (model.items.count + Self.columns - 1) / Self.columns
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: MT.Space.s8), count: Self.columns),
                              spacing: MT.Space.s8) {
                        ForEach(model.items) { item in
                            DownloadCell(item: item, thumbnail: model.thumbnails[item.url], close: close)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: min(CGFloat(rows) * 118, 420))
            }
            SendZone(box: sendBox, close: close)
        }
        .padding(MT.Space.s12)
        .frame(width: CGFloat(Self.columns) * Self.cell + CGFloat(Self.columns - 1) * MT.Space.s8 + MT.Space.s12 * 2)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
    }
}

private struct DownloadCell: View {
    let item: DownloadItem
    let thumbnail: NSImage?
    let close: () -> Void
    @State private var hovering = false
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: MT.Space.s4) {
            Image(nsImage: thumbnail ?? NSImage()).resizable().scaledToFit().frame(width: 56, height: 56)
            Text(item.name).font(.system(size: 11)).foregroundStyle(Color.mtInk)
                .lineLimit(2).multilineTextAlignment(.center).frame(height: 28, alignment: .top)
            Text(Self.ago.localizedString(for: item.added, relativeTo: .now))
                .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mtInkMuted)
        }
        .frame(width: 84)
        .padding(.vertical, MT.Space.s6)
        .background(hovering ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .animation(MT.Motion.allowed(MT.Motion.quick), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            FileOpener.open(item.url)
            close()
        }
        .draggable(item.url)
        .contextMenu {
            Menu("Send To") {
                ForEach(QuickSend.Target.allCases) { target in
                    Button(target.rawValue, systemImage: target.symbol) {
                        close()
                        QuickSend.send(item.url, to: target)
                    }
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .help(item.name)
    }
}

struct OpenAppsGrid: View {
    let model: DockModel
    var title = "ALSO OPEN"
    var items: [AppItem]? = nil   // nil: the apps that didn't fit on the bar
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s10) {
            let items = items ?? model.overflow
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: MT.Space.s8), count: min(5, max(items.count, 1))),
                      spacing: MT.Space.s8) {
                ForEach(items) { item in
                    OpenAppCell(item: item, model: model, close: close)
                }
            }
        }
        .padding(MT.Space.s12)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
    }
}

private struct OpenAppCell: View {
    let item: AppItem
    let model: DockModel
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: MT.Space.s4) {
            Image(nsImage: model.icon(for: item)).resizable().frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if let badge = model.badges[item.id] { Badge(text: badge) }
                }
            Text(item.name).font(.system(size: 11)).foregroundStyle(Color.mtInk).lineLimit(1)
        }
        .frame(width: 72)
        .padding(.vertical, MT.Space.s6)
        .background(hovering ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            model.open(item)
            close()
        }
        .contextMenu { AppMenu(item: item, model: model) }
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// The bottom of the Downloads grid: drop a file here, then pick where it goes. Nothing is sent;
/// the message or chat box is filled in and you press Send.
private struct SendZone: View {
    let box: SendBox
    let close: () -> Void
    private var file: URL? { box.file }
    private var targeted: Bool { box.targeted }

    var body: some View {
        Group {
            if let file {
                HStack(spacing: MT.Space.s8) {
                    Image(nsImage: IconCache.icon(file.path)).resizable().frame(width: 28, height: 28)
                    Text(file.lastPathComponent).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mtInk)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: MT.Space.s4)
                    Button { box.file = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Color.mtInkMuted).help("Clear")
                }
                HStack(spacing: MT.Space.s6) {
                    ForEach(QuickSend.Target.allCases) { target in
                        Button {
                            close()
                            QuickSend.send(file, to: target)
                        } label: {
                            Label(target.rawValue, systemImage: target.symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass).controlSize(.small)
                    }
                }
            } else {
                Label("Drag a file here to send it", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mtInkMuted)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
        }
        .padding(MT.Space.s8)
        .background(targeted ? Color.mtFillHover : Color.mtFillInset, in: .rect(cornerRadius: MT.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: MT.Radius.row)
                .strokeBorder(targeted ? Color.accentColor : Color.mtRingTrack, style: StrokeStyle(lineWidth: 1, dash: file == nil ? [4, 3] : []))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }   // drops land in AppKit (FirstClickHostingView)
        .animation(MT.Motion.allowed(MT.Motion.quick), value: file)
    }
}

/// A links tile: Quick Links, or Projects (your sites and servers). Drop a link from a browser on it
/// to add one to that list.
private struct LinksTile: View {
    let controller: DockController
    let kind: DockModel.LinkKind
    @State private var frame: CGRect = .zero

    var body: some View {
        let quick = kind == .quick
        Tile {
            GlyphIcon(symbol: quick ? "link" : "server.rack", color: quick ? .accentColor : .mtProjects)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame = $0
            if quick { controller.linksFrame = $0 } else { controller.projectLinksFrame = $0 }
        }
        .onTapGesture { controller.toggleGrid(quick ? .links : .projectLinks, from: frame) }
        .help(quick ? "Quick Links" : "Projects")
        .accessibilityLabel(quick ? "Quick Links" : "Projects")
        .accessibilityAddTraits(.isButton)
    }
}

/// A white SF Symbol on a dark gradient of `color`, sized like an app icon: the links tiles and Mac Tools.
private struct GlyphIcon: View {
    let symbol: String
    let color: Color
    @Environment(\.tileSize) private var size

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.40, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size * 0.82, height: size * 0.82)
            .background(LinearGradient(colors: [color.mix(with: .black, by: 0.15), color.mix(with: .black, by: 0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: size * 0.82 * 185 / 824, style: .continuous))
    }
}

/// the owner's own Mac Tools apps (every com.example.* app in /Applications), in the apps grid.
private struct MacToolsTile: View {
    let controller: DockController
    @State private var frame: CGRect = .zero

    var body: some View {
        Tile { GlyphIcon(symbol: "hammer.fill", color: .mtGood) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onTapGesture { controller.toggleGrid(.macTools, from: frame) }
            .help("Mac Tools")
            .accessibilityLabel("Mac Tools")
            .accessibilityAddTraits(.isButton)
    }
}

/// Search: click it, or press Option-Space (or Command-Space) anywhere.
private struct SearchTile: View {
    let controller: DockController

    var body: some View {
        Tile { GlyphIcon(symbol: "magnifyingglass", color: .mtInkMuted) }
            .onTapGesture { controller.toggleSearch() }
            .help("Search (⌥Space)")
            .accessibilityLabel("Search")
            .accessibilityAddTraits(.isButton)
    }
}

/// The search panel, Spotlight-style: a big glass field and, under it, tabs and the results grouped by kind
/// (a grid of thumbnails in the Screenshots tab). The arrow keys, Return, ⌘1 to ⌘4, ⌘C and Space are handled by
/// SearchPanelController.
struct SearchPanel: View {
    @Bindable var search: AppSearch
    let model: DockModel
    let open: (SearchItem) -> Void
    /// A row was dragged out and dropped somewhere that took it.
    let dropped: () -> Void
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0
    private static let width: CGFloat = 680, rowHeight: CGFloat = 44, maxList: CGFloat = 460

    var body: some View {
        VStack(spacing: MT.Space.s8) {
            field
            results
        }
        .frame(width: Self.width)
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: MT.Space.s12) {
            Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.mtInkMuted)
            TextField("Search", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 26)).foregroundStyle(Color.mtInk)
                .autocorrectionDisabled().focused($focused)
        }
        .padding(.horizontal, MT.Space.s18)
        .frame(height: 64)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.section))
    }

    private var results: some View {
        let sections = search.sections
        // Where each section's rows start in the one list the arrow keys walk.
        let starts = sections.indices.map { i in sections[..<i].reduce(0) { $0 + $1.items.count } }
        return VStack(spacing: MT.Space.s4) {
            tabs
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // A plain VStack: a few dozen rows, and a lazy one inside a ScrollView has frozen before.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { number, section in
                            Text(section.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                                .foregroundStyle(Color.mtInkMuted)
                                .padding(.horizontal, MT.Space.s10).frame(height: 26, alignment: .bottomLeading)
                            if search.scope == .screenshots {
                                ScreenshotGrid(shots: section.items, model: search.screenshots, selection: search.selection,
                                               open: open, dropped: dropped)
                            } else {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                                    row(item, selected: starts[number] + offset == search.selection)
                                        .frame(height: Self.rowHeight)
                                        .id(starts[number] + offset)
                                }
                            }
                        }
                        if let status {
                            Text(status).font(.system(size: 13)).foregroundStyle(Color.mtInkMuted)
                                .frame(maxWidth: .infinity).frame(height: Self.rowHeight)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, Self.maxList))
                .onChange(of: search.selection) { _, selection in proxy.scrollTo(selection) }   // keeps the selected row in view
            }
            Text(search.scope == .screenshots ? "Arrows Move  ·  Return Opens  ·  ⌘C Copies the Image  ·  Space Previews  ·  Drag Out to Share"
                                              : "↑↓ Move  ·  Return Opens  ·  ⌘Return Shows in Finder  ·  Space Previews  ·  ⌘1 to ⌘4 Switch Tabs")
                .font(.system(size: 10)).foregroundStyle(Color.mtInkMuted).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 20)
        }
        .padding(MT.Space.s8)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.section))
    }

    /// All, Apps, Files, Downloads, Screenshots: the open one in the accent colour.
    private var tabs: some View {
        HStack(spacing: MT.Space.s4) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                let open = scope == search.scope
                Text(scope.tab).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(open ? Color.white : Color.mtInk)
                    .padding(.horizontal, MT.Space.s12).frame(height: 28)
                    .background(open ? Color.accentColor : Color.mtFillInset, in: .capsule)
                    .contentShape(.capsule)
                    .onTapGesture { search.scope = scope }
                    .help(scope.shortcut.isEmpty ? "All" : "\(scope.tab) (\(scope.shortcut))")
                    .accessibilityLabel(scope.tab)
                    .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MT.Space.s4).padding(.top, MT.Space.s4)
    }

    @ViewBuilder private func row(_ item: SearchItem, selected: Bool) -> some View {
        switch item {
        case .entry(let entry):
            SearchRow(entry: entry, running: model.running[entry.id] != nil, selected: selected,
                      icon: entry.kind == .app ? AppItem(path: entry.target.path).map(model.icon(for:)) : nil)
                .overlay { RowMouse(url: entry.target, click: { open(item) }, dropped: dropped) }
        case .file(let hit):
            FileRow(hit: hit, words: FileRank.words(search.query), selected: selected)
                .overlay { RowMouse(url: URL(fileURLWithPath: hit.path), click: { open(item) }, dropped: dropped) }
        }
    }

    /// Why there is nothing (more) to show.
    private var status: String? {
        let typed = !FileRank.words(search.query).isEmpty
        if search.scope == .files, !typed { return "Type a Name to Search Your Files" }
        if search.scope == .screenshots, search.items.isEmpty {
            return typed ? "No Matches" : "No Screenshots in " + FileRank.place(search.screenshots.folder, home: NSHomeDirectory())
        }
        if search.files == .searching { return "Searching Files…" }
        if search.files == .failed { return "Spotlight Did Not Answer" }
        guard search.items.isEmpty else { return nil }
        return search.phase == .indexing ? "Indexing Apps…" : "No Matches"
    }
}

/// The Screenshots tab: thumbnails, newest first, four to a row, each with how long ago it was taken. A click opens
/// one, dragging carries the file out (a copy) and the selected one has an accent ring.
struct ScreenshotGrid: View {
    static let columns = 4
    let shots: [SearchItem]
    let model: ScreenshotsModel
    let selection: Int
    let open: (SearchItem) -> Void
    let dropped: () -> Void
    private static let cell = CGSize(width: 152, height: 96)

    var body: some View {
        let rows = stride(from: 0, to: shots.count, by: Self.columns).map { Array(shots.indices[$0..<min($0 + Self.columns, shots.count)]) }
        VStack(alignment: .leading, spacing: MT.Space.s10) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: MT.Space.s8) {
                    ForEach(row, id: \.self) { index in cell(index) }
                }
            }
        }
        .padding(.horizontal, MT.Space.s6).padding(.bottom, MT.Space.s6)
    }

    @ViewBuilder private func cell(_ index: Int) -> some View {
        if case .file(let hit) = shots[index] {
            let selected = index == selection
            VStack(spacing: MT.Space.s4) {
                Image(nsImage: model.thumbnail(hit, size: Self.cell)).resizable().interpolation(.high).scaledToFit()
                .frame(width: Self.cell.width, height: Self.cell.height)
                .background(Color.mtFillInset, in: .rect(cornerRadius: MT.Radius.control))
                .clipShape(.rect(cornerRadius: MT.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: MT.Radius.control)
                        .strokeBorder(selected ? Color.accentColor : Color.mtHairline, lineWidth: selected ? 3 : 1)
                }
                .overlay { RowMouse(url: URL(fileURLWithPath: hit.path), click: { open(shots[index]) }, dropped: dropped) }
                Text(hit.date.map { $0.formatted(.relative(presentation: .named)) } ?? hit.name)
                    .font(.system(size: 10)).foregroundStyle(selected ? Color.mtInk : Color.mtInkMuted).lineLimit(1)
            }
            .id(index)
            .help(hit.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hit.name)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

private struct SearchRow: View {
    let entry: SearchEntry
    let running: Bool
    let selected: Bool
    /// The app's Dock icon (a chosen or alternate one), so search matches the Dock.
    let icon: NSImage?

    var body: some View {
        HStack(spacing: MT.Space.s10) {
            Group {
                switch entry.kind {
                case .app: Image(nsImage: icon ?? IconCache.icon(entry.target.path)).resizable()
                case .setting: Image(nsImage: IconCache.icon(AppIndexer.systemSettings)).resizable()
                case .link, .project: ProjectBadge(path: entry.projectPath, title: entry.name, host: entry.detail)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.mtInk).lineLimit(1)
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.system(size: 10)).foregroundStyle(Color.mtInkMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if running {
                Circle().fill(Color.mtGood).frame(width: 7, height: 7).help("Running").accessibilityLabel("Running")
            }
        }
        .padding(.horizontal, MT.Space.s10)
        .frame(maxHeight: .infinity)
        .background(selected ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A file or folder: its icon, its name with the typed part in bold, then where it is and when it was last used.
private struct FileRow: View {
    let hit: FileHit
    let words: [String]
    let selected: Bool

    var body: some View {
        let folder = FileRank.place((hit.path as NSString).deletingLastPathComponent, home: NSHomeDirectory())
        HStack(spacing: MT.Space.s10) {
            Image(nsImage: IconCache.icon(hit.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14)).foregroundStyle(Color.mtInk).lineLimit(1).truncationMode(.middle)
                Text(hit.date.map { "\(folder)  ·  \(FileRank.when($0))" } ?? folder)
                    .font(.system(size: 10)).foregroundStyle(Color.mtInkMuted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MT.Space.s10)
        .frame(maxHeight: .infinity)
        .background(selected ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .help(hit.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hit.name), \(folder)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var name: AttributedString {
        var text = AttributedString(hit.name)
        for range in FileRank.emphasis(hit.name, words) {
            if let range = Range(range, in: text) { text[range].font = .system(size: 14, weight: .bold) }
        }
        return text
    }
}

/// A search row's mouse, in AppKit: a click (down and up without moving) opens the row; press and drag carries
/// its file or link out to another app, and never opens it. AppKit rather than .onDrag, because only a dragging
/// source hears how the drag ended, and the popup closes after a drop that was taken.
private struct RowMouse: NSViewRepresentable {
    let url: URL
    let click: () -> Void
    let dropped: () -> Void

    func makeNSView(context: Context) -> Source { Source() }

    func updateNSView(_ view: Source, context: Context) {
        view.url = url
        view.click = click
        view.dropped = dropped
    }

    final class Source: NSView, NSDraggingSource {
        var url: URL?
        var click: (() -> Void)?
        var dropped: (() -> Void)?
        private var pressed: NSPoint?   // where the button went down; nil once a drag has begun

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { pressed = event.locationInWindow }

        override func mouseDragged(with event: NSEvent) {
            guard let from = pressed, let url, hypot(event.locationInWindow.x - from.x, event.locationInWindow.y - from.y) > 4 else { return }
            pressed = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = url.isFileURL ? NSWorkspace.shared.icon(forFile: url.path) : NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            let at = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: at.x - 16, y: at.y - 16, width: 32, height: 32), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if pressed != nil { click?() }
            pressed = nil
        }

        /// Copy or link, never move: dragging a search result must not relocate the original. Not onto Pier itself,
        /// whose bar would open it with an app or put it in the Trash.
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if !operation.isEmpty { dropped?() }
        }
    }
}

struct LinksList: View {
    let kind: DockModel.LinkKind
    let model: DockModel
    let controller: DockController
    let close: () -> Void
    @State private var editing = false
    @State private var draft: [Draft] = []
    @FocusState private var focused: UUID?

    /// An editable row; its own id, since a half-typed address can be empty or repeat another.
    struct Draft: Identifiable { let id = UUID(); var title: String; var url: String; var path: String?; var start: String? }
    @State private var listening: Set<Int> = []   // local ports with a server answering
    @State private var busy: Set<String> = []       // servers starting or stopping

    /// ▶ starts the server with its command; ■ stops whatever listens on its port. Then the dot
    /// follows the port for up to ~30 s, until the change shows.
    private func toggleServer(_ link: GroupsFile.Link) {
        guard let port = LocalServers.port(of: link), !busy.contains(link.id) else { return }
        let starting = !listening.contains(port)
        if starting { LocalServers.start(link) } else { LocalServers.stop(port: port) }
        busy.insert(link.id)
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                listening = await LocalServers.listening(model.links(kind))
                if listening.contains(port) == starting { break }
            }
            busy.remove(link.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s6) {
            HStack {
                Text(kind == .quick ? "QUICK LINKS" : "PROJECTS").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
                Spacer()
                if editing {
                    Button("Done") { save() }.buttonStyle(.glassProminent).controlSize(.small)
                } else {
                    Button("Edit") {
                        draft = model.links(kind).map { Draft(title: $0.title, url: $0.url, path: $0.path, start: $0.start) }
                        editing = true
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
            if editing { editor } else { list }
        }
        .padding(MT.Space.s12)
        .frame(width: editing ? 380 : 280)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
        .onDisappear { if editing { save() } }   // closing the panel keeps the edits
        .task { listening = await LocalServers.listening(model.links(kind)) }
    }

    @ViewBuilder private var list: some View {
        if model.links(kind).isEmpty {
            Text("No links yet. Click Edit to add one, or drag a link from your browser onto the Links tile.")
                .font(.system(size: 12)).foregroundStyle(Color.mtInkMuted).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.links(kind)) { link in
            LinkRow(link: link, running: LocalServers.port(of: link).map { listening.contains($0) },
                    busy: busy.contains(link.id), toggle: { toggleServer(link) }) {
                close()
                if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            }
            .contextMenu {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                }
                Button("Remove Link", role: .destructive) { model.removeLink(link, from: kind) }
            }
        }
    }

    private static let rowHeight: CGFloat = 30
    @State private var dragging: UUID?
    @State private var dragOffset: CGFloat = 0

    private var editor: some View {
        VStack(alignment: .leading, spacing: MT.Space.s8) {
            // Plain rows, not a List: a List's reordering is system drag-and-drop, which never lands in
            // Pier's panels, and it swallows clicks meant for the text fields.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach($draft) { $row in
                        HStack(spacing: MT.Space.s6) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(Color.mtInkMuted)
                                .frame(width: 18, height: Self.rowHeight).contentShape(.rect)
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { dragging = row.id; dragOffset = $0.translation.height }
                                    .onEnded { moveDragged(by: $0.translation.height) })
                                .help("Drag to reorder")
                            TextField("Name", text: $row.title).frame(width: 110).focused($focused, equals: row.id)
                            TextField("Address", text: $row.url)
                            Button { draft.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Color.mtBad)
                            }
                            .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete \(row.title)")
                        }
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .frame(height: Self.rowHeight)
                        .offset(y: dragging == row.id ? dragOffset : 0)
                        .zIndex(dragging == row.id ? 1 : 0)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(max(draft.count, 1)) * Self.rowHeight, 330))
            Button {
                let row = Draft(title: "", url: "")
                draft.append(row)
                focused = row.id
            } label: { Label("Add Link", systemImage: "plus") }
            .buttonStyle(.glass).controlSize(.small)
            Text("Leave off https:// if you like; it's added for you.").font(.system(size: 10)).foregroundStyle(Color.mtInkMuted)
        }
    }

    private func moveDragged(by height: CGFloat) {
        defer { dragging = nil; dragOffset = 0 }
        guard let id = dragging, let from = draft.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + Int((height / Self.rowHeight).rounded()), 0), draft.count - 1)
        guard to != from else { return }
        draft.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    private func save() {
        model.setLinks(draft.map { GroupsFile.Link(title: $0.title, url: $0.url, path: $0.path, start: $0.start) }, for: kind)
        editing = false
    }
}

private struct LinkRow: View {
    let link: GroupsFile.Link
    /// nil for sites on the internet; true/false for a server on this Mac.
    var running: Bool? = nil
    var busy = false
    var toggle: (() -> Void)? = nil
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let url = URL(string: link.url)
        let host = url.map { u in
            let name = u.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
            return ["127.0.0.1", "localhost"].contains(name) ? "localhost:\(u.port ?? 80)" : name
        } ?? link.url
        HStack(spacing: MT.Space.s10) {
            ProjectBadge(path: link.path, title: link.title, host: host)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mtInk).lineLimit(1)
                Text(host).font(.system(size: 10)).foregroundStyle(Color.mtInkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let running {
                Circle().fill(running ? Color.mtGood : Color.mtRingTrack).frame(width: 7, height: 7)
                    .help(running ? "Running" : "Not running")
                    .accessibilityLabel(running ? "Running" : "Not running")
                // Start needs a command; stop works on any server listening on the port.
                if let toggle, running || link.start != nil {
                    Button(action: toggle) {
                        Group {
                            if busy { ProgressView().controlSize(.mini) }
                            else { Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 10, weight: .semibold)) }
                        }
                        .frame(width: 24, height: 24)
                        .background(Color.mtFillHover, in: .circle)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.mtInk)
                    .help(running ? "Stop \(link.title)" : "Start \(link.title)")
                    .accessibilityLabel(running ? "Stop \(link.title)" : "Start \(link.title)")
                }
            }
        }
        .padding(.horizontal, MT.Space.s8)
        .frame(height: 40)
        .background(hovering ? Color.mtFillHover : .clear, in: .rect(cornerRadius: MT.Radius.row))
        .contentShape(.rect(cornerRadius: MT.Radius.row))
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityLabel(link.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// A project's real icon (Kit's ProjectIcon, the same finder Projects uses), else a letter badge
/// drawn here, so no site's icon is fetched from the network.
private struct ProjectBadge: View {
    let path: String?
    let title: String
    let host: String
    @State private var icon: ProjectIcon.Found?
    @MainActor private static var cache: [String: ProjectIcon.Found] = [:]

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(.rect(cornerRadius: icon.isMacIcon ? 0 : 7, style: .continuous))
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(hue: Double(host.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360,
                                      saturation: 0.48, brightness: 0.78),
                                in: .rect(cornerRadius: 7, style: .continuous))
            }
        }
        .frame(width: 26, height: 26)
        .task(id: path) {
            guard let path else { return }
            if let cached = Self.cache[path] { icon = cached; return }
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").appendingPathComponent(path)
            let found = await Task.detached(priority: .utility) { ProjectIcon.find(root: root, app: nil) }.value
            if let found { Self.cache[path] = found }
            icon = found
        }
    }
}

/// Which local servers answer, checked once when a list opens (a refused connect returns at once).
enum LocalServers {
    static func port(of link: GroupsFile.Link) -> Int? {
        guard let url = URL(string: link.url), ["127.0.0.1", "localhost"].contains(url.host() ?? "") else { return nil }
        return url.port ?? 80
    }

    static func listening(_ links: [GroupsFile.Link]) async -> Set<Int> {
        let ports = Set(links.compactMap(port(of:)))
        return await Task.detached(priority: .userInitiated) { Set(ports.filter(isOpen)) }.value
    }

    /// Runs the link's start command in its project folder, detached, logging to ~/Library/Logs/Pier.
    /// An interactive login shell, so the PATH has what the terminal has (pnpm, npm, uv).
    @MainActor
    static func start(_ link: GroupsFile.Link) {
        guard let command = link.start, let path = link.path else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").appendingPathComponent(path)
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pier")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(link.title).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", command]
        process.currentDirectoryURL = folder
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    /// Stops whatever is listening on the port (a dev server Pier, Projects or a terminal started).
    static func stop(port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return }
        lsof.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        for pid in pids where pid != getpid() { kill(pid, SIGTERM) }
    }

    private static func isOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// A minimized window: its picture (or its app's icon), with the app icon in the corner. Click to restore.
private struct MinimizedTile: View {
    let window: MinimizedWindows.Window
    let minimized: MinimizedWindows
    @Environment(\.tileSize) private var size

    var body: some View {
        Tile {
            Group {
                if let picture = window.picture {
                    Image(nsImage: picture).resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                } else {
                    Image(nsImage: IconCache.icon(window.app.bundleURL?.path ?? "")).resizable().opacity(0.85)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(nsImage: IconCache.icon(window.app.bundleURL?.path ?? "")).resizable()
                    .frame(width: size * 0.42, height: size * 0.42)
                    .offset(x: 4, y: 4)
            }
        }
        .onTapGesture { minimized.restore(window) }
        .help(window.title.isEmpty ? (window.app.localizedName ?? "Window") : window.title)
        .accessibilityLabel("Minimized: \(window.title)")
        .accessibilityAddTraits(.isButton)
    }
}
