import AppKit
import SwiftUI
import MacToolsKit

/// NSWorkspace icons are expensive to fetch on every redraw.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    private static var apps: [String: (source: String, image: NSImage)] = [:]

    static func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// The icon an app shows in the Dock, which can differ from its file's: one you picked in Pier
    /// (Change Icon…), else one the app records choosing (ChatGPT saves DockIconResourceName, an
    /// image in its bundle). Apps that only swap the icon in memory can't be read from outside.
    static func appIcon(_ item: AppItem, override: String?) -> NSImage {
        let source = source(item, override: override)
        if let cached = apps[item.url.path], cached.source == source { return cached.image }
        let image = source.isEmpty ? nil : NSImage(contentsOfFile: source)
        let result = image ?? icon(item.url.path)
        apps[item.url.path] = (source, result)
        return result
    }

    /// True when the app's chosen icon changed since it was last drawn.
    static func changed(_ item: AppItem, override: String?) -> Bool {
        guard let cached = apps[item.url.path] else { return false }
        return cached.source != source(item, override: override)
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
}

struct DockView: View {
    let controller: DockController
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        let model = controller.model
        HStack(spacing: MT.Space.s4) {
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
            if let playing = controller.nowPlaying.item {
                NowPlayingTile(item: playing, nowPlaying: controller.nowPlaying)
            }
            StatsCluster(model: model, controller: controller)
            GroupDivider()
            LinksTile(controller: controller)
            DownloadsTile(controller: controller)
            TrashTile(controller: controller)
        }
        .padding(MT.Space.s6)
        .glassEffect(.regular, in: .rect(cornerRadius: MT.Radius.panel))
        .environment(\.tileSize, model.tileSize)
        .contextMenu {
            Button("Edit Groups…") { controller.editGroups() }
            Menu("Show On") {
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { controller.screenName == name },
                                               set: { if $0 { controller.show(on: name) } }))
                }
            }
            Toggle("Open at Login", isOn: $openAtLogin)
            Divider()
            Button("Quit Pier") { controller.quit() }
        }
        .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
    }
}

private struct GroupDivider: View {
    var body: some View {
        Capsule().fill(Color.mtRingTrack).frame(width: 1, height: 32).padding(.horizontal, MT.Space.s4)
            .padding(.bottom, 7)   // centred on the icons, not the running dots
    }
}

/// An icon with the running dot under it, as every tile in the bar is laid out.
private struct Tile<Icon: View>: View {
    var running = false
    /// Replaces the running dot's colour: amber needs you, green finished.
    var attention: MTStatus? = nil
    /// Each change plays one gentle bounce (the macOS Dock's, quieter).
    var bounce = 0
    @ViewBuilder var icon: Icon
    @Environment(\.tileSize) private var size
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            icon.frame(width: size, height: size)
                .phaseAnimator(MT.Motion.allowed(.default) == nil ? [0] : [0, -10, 0, -5, 0], trigger: bounce) { icon, lift in
                    icon.offset(y: lift)
                } animation: { _ in .spring(response: 0.22, dampingFraction: 0.6) }
            Circle().fill(attention?.color ?? Color.mtInk.opacity(running ? 0.75 : 0))
                .frame(width: attention == nil ? 4 : 6, height: attention == nil ? 4 : 6)
                .frame(height: 4)
        }
        .scaleEffect(hovering ? 1.08 : 1, anchor: .bottom)
        .animation(MT.Motion.allowed(MT.Motion.quick), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

private struct AppTile: View {
    let item: AppItem
    let controller: DockController
    @State private var frame: CGRect = .zero

    var body: some View {
        let model = controller.model
        let reorder = controller.reorder
        Tile(running: model.isRunning(item), attention: model.attention[item.id], bounce: model.bounces[item.id] ?? 0) {
            Image(nsImage: model.icon(for: item)).resizable().interpolation(.high)
        }
        .overlay(alignment: .topTrailing) {
            if let badge = model.badges[item.id] { Badge(text: badge) }
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
        // Reorder by dragging inside the bar; drag up off it to remove. (A system drag session
        // never reached the bar's own drop targets, so this is a plain gesture.)
        .offset(reorder.dragging == item.id ? reorder.offset : .zero)
        .opacity(reorder.dragging == item.id && reorder.removing ? 0.35 : 1)
        .zIndex(reorder.dragging == item.id ? 1 : 0)
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { controller.dragChanged(item, $0) }
            .onEnded { controller.dragEnded(item, $0) })
        .overlay(alignment: reorder.target?.after == true ? .trailing : .leading) {
            if reorder.target?.id == item.id {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
                    .offset(x: reorder.target?.after == true ? 4 : -4)
            }
        }
        .contextMenu { AppMenu(item: item, model: model) }
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

private struct NowPlayingTile: View {
    let item: NowPlaying.Item
    let nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: MT.Space.s8) {
            Image(nsImage: IconCache.icon(NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID)?.path ?? ""))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mtInk)
                Text(item.subtitle).font(.system(size: 10)).foregroundStyle(Color.mtInkMuted)
            }
            .lineLimit(1)
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                nowPlaying.playPause()
            } label: {
                Image(systemName: item.playing ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mtInk)
            .accessibilityLabel(item.playing ? "Pause" : "Play")
        }
        .padding(.leading, MT.Space.s6)
        .padding(.trailing, MT.Space.s8)
        .frame(height: 40)
        .contentShape(.rect)
        .onTapGesture { nowPlaying.reveal() }
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 7)
        .help("\(item.title) · \(item.subtitle)\nClick to go there")
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

    var body: some View {
        let gb = 1_073_741_824.0
        let memPercent = model.memoryUsed / model.memoryTotal * 100
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: MT.Space.s4) {
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
        .padding(.bottom, 7)
    }

    private func usageRing(_ name: String, _ reading: UsageSnapshot.Reading?, tint: Color) -> some View {
        var detail = name
        if let r = reading {
            if let s = r.short { detail += "\nSession: \(Int(s.percent.rounded()))% used" }
            if let l = r.long { detail += "\nWeek: \(Int(l.percent.rounded()))% used" }
            if r.stale { detail += "\nShowing the last reading" }
        } else {
            detail += "\nNo reading. Open Usage Rings to start tracking."
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
                    HStack(alignment: .top, spacing: MT.Space.s8) {
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
            Image(nsImage: shot.image).resizable().scaledToFit()
                .frame(maxWidth: 180, maxHeight: 120)
                .clipShape(.rect(cornerRadius: MT.Radius.control))
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
                    NSWorkspace.shared.open(DownloadsModel.folder)
                    close()
                }
                .buttonStyle(.glass).controlSize(.small)
            }
            if model.items.isEmpty {
                Text("Nothing in Downloads yet").font(.system(size: 13)).foregroundStyle(Color.mtInkMuted)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let rows = (model.items.count + Self.columns - 1) / Self.columns
                ScrollView {
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
            NSWorkspace.shared.open(item.url)
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
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s10) {
            Text("ALSO OPEN").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: MT.Space.s8), count: min(5, max(model.overflow.count, 1))),
                      spacing: MT.Space.s8) {
                ForEach(model.overflow) { item in
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

/// Quick Links: a tile that opens the list. Drop a link from a browser on it to add one.
private struct LinksTile: View {
    let controller: DockController
    @State private var frame: CGRect = .zero
    @Environment(\.tileSize) private var size

    var body: some View {
        Tile {
            Image(systemName: "link")
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size * 0.82, height: size * 0.82)
                .background(LinearGradient(colors: [Color.accentColor.mix(with: .black, by: 0.15), Color.accentColor.mix(with: .black, by: 0.55)],
                                           startPoint: .top, endPoint: .bottom),
                            in: .rect(cornerRadius: size * 0.82 * 185 / 824, style: .continuous))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame = $0
            controller.linksFrame = $0
        }
        .onTapGesture { controller.toggleGrid(.links, from: frame) }
        .help("Quick Links")
        .accessibilityLabel("Quick Links")
        .accessibilityAddTraits(.isButton)
    }
}

struct LinksList: View {
    let model: DockModel
    let controller: DockController
    let close: () -> Void
    @State private var editing = false
    @State private var draft: [Draft] = []
    @FocusState private var focused: UUID?

    /// An editable row; its own id, since a half-typed address can be empty or repeat another.
    struct Draft: Identifiable { let id = UUID(); var title: String; var url: String }

    var body: some View {
        VStack(alignment: .leading, spacing: MT.Space.s6) {
            HStack {
                Text("QUICK LINKS").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(Color.mtInkMuted)
                Spacer()
                if editing {
                    Button("Done") { save() }.buttonStyle(.glassProminent).controlSize(.small)
                } else {
                    Button("Edit") {
                        draft = model.links.map { Draft(title: $0.title, url: $0.url) }
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
    }

    @ViewBuilder private var list: some View {
        if model.links.isEmpty {
            Text("No links yet. Click Edit to add one, or drag a link from your browser onto the Links tile.")
                .font(.system(size: 12)).foregroundStyle(Color.mtInkMuted).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.links) { link in
            LinkRow(link: link) {
                close()
                if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            }
            .contextMenu {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url, forType: .string)
                }
                Button("Remove Link", role: .destructive) { model.removeLink(link) }
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
            ScrollView {
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
        // Typing needs Pier to be the active app; it has no windows of its own, so nothing else changes.
        .onAppear { NSApp.activate() }
    }

    private func moveDragged(by height: CGFloat) {
        defer { dragging = nil; dragOffset = 0 }
        guard let id = dragging, let from = draft.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + Int((height / Self.rowHeight).rounded()), 0), draft.count - 1)
        guard to != from else { return }
        draft.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    private func save() {
        model.setLinks(draft.map { GroupsFile.Link(title: $0.title, url: $0.url) })
        editing = false
    }
}

private struct LinkRow: View {
    let link: GroupsFile.Link
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let host = URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
        HStack(spacing: MT.Space.s10) {
            // A letter badge drawn here, so no site's icon is fetched from the network.
            Text(String(link.title.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color(hue: Double(host.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360, saturation: 0.48, brightness: 0.78),
                            in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mtInk).lineLimit(1)
                Text(host).font(.system(size: 10)).foregroundStyle(Color.mtInkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
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
