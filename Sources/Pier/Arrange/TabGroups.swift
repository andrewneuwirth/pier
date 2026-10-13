import AppKit
import ApplicationServices
import Observation
import SwiftUI
import MacToolsKit

/// Tab groups: an app's windows in one place under a strip of tabs. Made from the hover card or
/// right-click (Group Windows into Tabs); drag a tab off the strip to take that window out. The tab
/// showing is the real window; the others are parked just off the screen's corner (so nothing peeks
/// out from behind) and swap in when chosen. Quitting Pier or ungrouping brings every one back.
@MainActor @Observable
final class TabGroups {
    struct Group: Codable, Identifiable {
        var id = UUID()
        var windows: [WinID]
        var active: Int
        /// Where the group shows, kept so its windows can come back even after the one showing closes.
        var frame: CGRect?
    }

    private(set) var groups: [Group] = []
    @ObservationIgnored private var elements: [WinID: AXUIElement] = [:]
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var strips: [UUID: TabStripPanel] = [:]
    @ObservationIgnored private var minimized: Set<WinID> = []
    @ObservationIgnored private var placedAt = Date.distantPast       // our own moves aren't yours
    @ObservationIgnored private var workspace: [NSObjectProtocol] = []
    @ObservationIgnored private var checker: Timer?
    @ObservationIgnored private var pausedUntil = Date.distantPast
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    static let stripHeight: CGFloat = 30

    func start() {
        guard AXIsProcessTrusted() else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspace = [
            // Another app in front covers the strip; the group's app in front shows it again.
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restack() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetClosed() }
            },
        ]
        restore()
        for g in groups.indices { if let frame = activeFrame(of: g) { line(up: g, at: frame) } }
        refresh()
        // Asleep or locked, apps can stop listing their windows; don't read that as every window closing.
        let pause: (TimeInterval) -> (Notification) -> Void = { [weak self] seconds in
            { _ in MainActor.assumeIsolated { self?.pausedUntil = Date().addingTimeInterval(seconds) } }
        }
        let ws = NSWorkspace.shared.notificationCenter, dc = DistributedNotificationCenter.default()
        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause(.infinity)),
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: pause(.infinity)),
            dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause(.infinity)),
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: pause(10)),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: pause(10)),
            dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: pause(10)),
        ]
        checker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.groups.isEmpty == false { self?.validate() } }
        }
    }

    // MARK: Asking

    func windowCount(_ app: NSRunningApplication) -> Int { standardWindows(app).count }

    /// True when every window of the app is already in one group.
    func isGrouped(_ app: NSRunningApplication) -> Bool {
        let ids = Set(standardWindows(app).compactMap { AXWin.id($0) })
        return ids.count > 1 && groups.contains { Set($0.windows) == ids }
    }

    // MARK: Grouping

    /// Every window of the app into one group, in the place and at the size of the one in front.
    func groupAll(_ app: NSRunningApplication) {
        let windows = standardWindows(app)
        guard windows.count > 1 else { return }
        let front = AXWin.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
        let ids = windows.compactMap { AXWin.id($0) }
        ids.forEach(takeOut)
        observe(app.processIdentifier)
        for (id, element) in zip(ids, windows) { adopt(id, element) }
        let activeID = front.flatMap { AXWin.id($0) }.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        guard var frame = elements[activeID].flatMap(AXWin.frame) else { return }
        // Leave room above it for the strip.
        let top = NSScreen.screens.first.map { AXWin.flipped($0.visibleFrame).minY } ?? 0
        if frame.minY < top + Self.stripHeight { frame.origin.y = top + Self.stripHeight }
        groups.append(Group(windows: ids, active: ids.firstIndex(of: activeID) ?? 0))
        line(up: groups.count - 1, at: frame)
        refresh()
        save()
    }

    func ungroup(_ app: NSRunningApplication) {
        let ids = Set(standardWindows(app).compactMap { AXWin.id($0) })
        for g in groups.indices.reversed() where !ids.isDisjoint(with: groups[g].windows) { dissolve(g) }
        refresh()
        save()
    }

    /// Ends a group, bringing its parked windows back, fanned out a little from where the group was.
    private func dissolve(_ g: Int) {
        guard let frame = activeFrame(of: g) ?? groups[g].frame else { groups.remove(at: g); return }
        placedAt = Date()
        var offset: CGFloat = 0
        for id in groups[g].windows where id != groups[g].windows[groups[g].active] && !minimized.contains(id) {
            offset += 28
            if let element = elements[id] { AXWin.setFrame(element, frame.offsetBy(dx: offset, dy: offset)) }
        }
        groups.remove(at: g)
    }

    /// Every parked window back on screen (Pier quitting).
    func unparkAll() {
        for g in groups.indices.reversed() { dissolve(g) }
    }

    // MARK: Tabs

    private func select(_ id: WinID) {
        guard let g = group(holding: id), let element = elements[id] else { return }
        let frame = activeFrame(of: g)
        if minimized.remove(id) != nil {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        groups[g].active = groups[g].windows.firstIndex(of: id) ?? 0
        if let frame { line(up: g, at: frame) }
        AXWin.bringForward(element)
        refresh()
        save()
    }

    /// The tab's ×: Pier closes the window itself, so the group updates at once. It's the window's own close
    /// button, so an app still asks about unsaved work; a hidden tab is brought into view first so that
    /// question shows where you can see it.
    private func closeTab(_ id: WinID) {
        guard let g = group(holding: id), let element = elements[id] else { return }
        let frame = activeFrame(of: g)
        takeOut(id)                       // the next tab takes its place; a group of one ends
        elements[id] = nil
        placedAt = Date()
        if minimized.remove(id) != nil {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let frame { AXWin.setFrame(element, frame) }
        if let button = AXWin.element(element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        refresh()
        save()
    }

    /// Every couple of seconds while there are groups: a window no longer among its app's windows has
    /// gone (Chrome hides closed windows for reuse instead of destroying them, so no close is reported).
    private func validate() {
        guard Date() > pausedUntil else { return }   // asleep, locked, or just back: apps may not answer yet
        var changed = false
        var windowsByApp: [pid_t: [AXUIElement]] = [:]
        for id in groups.flatMap(\.windows) {
            guard let element = elements[id] else { continue }
            let pid = AXWin.pid(element)
            let windows = windowsByApp[pid] ?? AXWin.windows(of: pid)
            windowsByApp[pid] = windows
            // No windows at all usually means the app can't answer right now (the Mac asleep or locked,
            // the app busy), not that every window closed: skip it rather than break the group.
            guard !windows.isEmpty else { continue }
            let alive = windows.contains { AXWin.id($0) == id }
            if !alive {
                takeOut(id)
                elements[id] = nil
                minimized.remove(id)
                changed = true
            }
        }
        if changed { refresh(); save() }
    }

    /// A tab dragged off the strip: that window leaves the group, landing under the pointer.
    private func pullOut(_ id: WinID) {
        guard let g = group(holding: id), let element = elements[id], let frame = activeFrame(of: g) else { return }
        let groupID = groups[g].id
        takeOut(id)
        let mouse = AXWin.flipped(NSEvent.mouseLocation)
        placedAt = Date()
        if minimized.remove(id) != nil {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXWin.setFrame(element, CGRect(x: mouse.x - frame.width / 2, y: mouse.y - 12, width: frame.width, height: frame.height))
        AXWin.bringForward(element)
        // What's left of the group stays where it was, its next window showing.
        if let g = groups.firstIndex(where: { $0.id == groupID }) { line(up: g, at: frame) }
        refresh()
        save()
    }

    /// Takes a window out of whatever group it's in. What's left shows in the group's spot; a group left
    /// with one window ends, and that window comes back on screen there (it may have been parked).
    private func takeOut(_ id: WinID) {
        guard let g = group(holding: id) else { return }
        let activeID = groups[g].windows[groups[g].active]
        groups[g].windows.removeAll { $0 == id }
        groups[g].active = groups[g].windows.firstIndex(of: activeID) ?? 0
        guard let frame = groups[g].frame else { if groups[g].windows.count < 2 { groups.remove(at: g) }; return }
        if groups[g].windows.count < 2 {
            placedAt = Date()
            for left in groups[g].windows {
                if let element = elements[left] {
                    if minimized.remove(left) == nil { AXWin.setFrame(element, frame) }
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                }
            }
            groups.remove(at: g)
        } else if activeID == id {
            line(up: g, at: frame)   // the one showing went: the next takes its place
        }
    }

    /// The chosen tab at `frame` and in front; every other tab parked off the screen's corner.
    private func line(up g: Int, at frame: CGRect) {
        placedAt = Date()
        groups[g].frame = frame
        let activeID = groups[g].windows[groups[g].active]
        let screen = NSScreen.screens.first { AXWin.flipped($0.frame).contains(CGPoint(x: frame.midX, y: frame.midY)) }
            ?? NSScreen.screens.first
        let corner = screen.map { AXWin.flipped($0.frame) }.map { CGPoint(x: $0.maxX - 1, y: $0.maxY - 1) } ?? .zero
        for id in groups[g].windows where !minimized.contains(id) {
            guard let element = elements[id] else { continue }
            if id == activeID {
                AXWin.setFrame(element, frame)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            } else {
                AXWin.setFrame(element, CGRect(origin: corner, size: frame.size))   // parked: out of sight
            }
        }
    }

    // MARK: Following your moves

    fileprivate func handle(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXUIElementDestroyedNotification:
            // That window closed. (Chrome keeps closed windows around for reuse, so the window list can't
            // be trusted to say; the element itself is matched instead.)
            if let id = elements.first(where: { CFEqual($0.value, element) })?.key {
                takeOut(id)
                elements[id] = nil
                minimized.remove(id)
                refresh()
                save()
            } else {
                forgetClosed()
            }
        case kAXFocusedWindowChangedNotification:
            // A parked tab got focus some other way (⌘`, a menu, or the app handing focus over when the
            // showing window closed): swap it into the group's spot, as if its tab were clicked.
            guard let id = AXWin.id(element), group(holding: id).map({ groups[$0].windows[groups[$0].active] != id }) == true
            else { restack(); return }
            select(id)
        case kAXWindowMiniaturizedNotification:
            guard let id = AXWin.id(element), let g = group(holding: id) else { return }
            minimized.insert(id)   // it stays in the strip, dimmed; the next tab comes forward
            if groups[g].windows[groups[g].active] == id,
               let next = groups[g].windows.firstIndex(where: { !minimized.contains($0) }) {
                groups[g].active = next
                if let element = elements[groups[g].windows[next]] { AXWin.bringForward(element) }
            }
            refresh()
        case kAXWindowDeminiaturizedNotification:
            guard let id = AXWin.id(element), minimized.remove(id) != nil, let g = group(holding: id) else { return }
            let frame = activeFrame(of: g)
            groups[g].active = groups[g].windows.firstIndex(of: id) ?? 0
            if let frame { line(up: g, at: frame) }
            refresh()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // The tab showing moved or resized: the strip follows. (The others are parked, nothing to drag.)
            guard Date().timeIntervalSince(placedAt) > 0.3, let id = AXWin.id(element), let g = group(holding: id),
                  groups[g].windows[groups[g].active] == id else { return }
            refresh()
        default:
            break
        }
    }

    // MARK: Strips

    /// One strip per group, just above the window showing, stacked right over it.
    private func refresh() {
        for (id, strip) in strips where !groups.contains(where: { $0.id == id }) {
            strip.orderOut(nil)
            strips[id] = nil
        }
        for group in groups {
            guard let g = groups.firstIndex(where: { $0.id == group.id }), let frame = activeFrame(of: g) else { continue }
            if !isParked(frame) { groups[g].frame = frame }   // follows your moves of the window showing
            let tabs = group.windows.compactMap { id -> TabStripPanel.Tab? in
                guard let element = elements[id] else { return nil }
                return .init(id: id, title: AXWin.title(element),
                             icon: NSRunningApplication(processIdentifier: AXWin.pid(element))?.icon,
                             minimized: minimized.contains(id))
            }
            let strip = strips[group.id] ?? TabStripPanel()
            strips[group.id] = strip
            strip.show(tabs: tabs, active: group.windows[group.active],
                       select: { [weak self] in self?.select($0) },
                       close: { [weak self] in self?.closeTab($0) },
                       pullOut: { [weak self] in self?.pullOut($0) },
                       ungroup: { [weak self] in
                           guard let self, let g = self.groups.firstIndex(where: { $0.id == group.id }) else { return }
                           self.dissolve(g)
                           self.refresh()
                           self.save()
                       })
            // Flush on the window's top edge, overlapping its rounded corners a touch so they join.
            strip.place(CGRect(x: frame.minX, y: frame.minY - Self.stripHeight + 1, width: frame.width, height: Self.stripHeight))
        }
        restack()
    }

    /// Each strip sits directly above its window in the window order, so other apps cover it as they
    /// cover the window.
    private func restack() {
        for group in groups {
            guard let strip = strips[group.id] else { continue }
            strip.order(.above, relativeTo: Int(group.windows[group.active]))
        }
    }

    // MARK: Helpers

    private func group(holding id: WinID) -> Int? { groups.firstIndex { $0.windows.contains(id) } }

    /// Where the group shows: the window showing, else the spot remembered (never a parked window's).
    private func activeFrame(of g: Int) -> CGRect? {
        let id = groups[g].windows[groups[g].active]
        if !minimized.contains(id), let frame = elements[id].flatMap(AXWin.frame), !isParked(frame) { return frame }
        return groups[g].frame
    }

    /// At a screen's bottom-right corner, where hidden tabs are parked.
    private func isParked(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let s = AXWin.flipped(screen.frame)
            return abs(frame.minX - (s.maxX - 1)) < 3 && abs(frame.minY - (s.maxY - 1)) < 3
        }
    }

    private func standardWindows(_ app: NSRunningApplication) -> [AXUIElement] {
        AXWin.windows(of: app.processIdentifier).filter(AXWin.isStandard)
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, tabCallback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func adopt(_ id: WinID, _ element: AXUIElement) {
        elements[id] = element
        if let observer = observers[AXWin.pid(element)] {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func forgetClosed() {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(list.compactMap { $0[kCGWindowNumber as String] as? WinID })
        let gone = groups.flatMap(\.windows).filter { !alive.contains($0) }
        gone.forEach { takeOut($0); elements[$0] = nil; minimized.remove($0) }
        if !gone.isEmpty { refresh(); save() }
    }

    // MARK: Saving

    /// ~/Library/Application Support/Pier/tabs.json. Window ids change when an app restarts, so each is
    /// saved with its app and title and matched again.
    private struct Saved: Codable {
        struct Ref: Codable { var bundle: String; var title: String }
        var groups: [[Ref]]
        var active: [Int]
    }

    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pier/tabs.json")

    private func save() {
        let saved = Saved(groups: groups.map { group in
            group.windows.compactMap { id in
                elements[id].map { .init(bundle: NSRunningApplication(processIdentifier: AXWin.pid($0))?.bundleIdentifier ?? "",
                                         title: AXWin.title($0)) }
            }
        }, active: groups.map(\.active))
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        var used = Set<WinID>()
        for (refs, active) in zip(saved.groups, saved.active) {
            var ids: [WinID] = []
            for ref in refs {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ref.bundle }) else { continue }
                let windows = standardWindows(app)
                guard let match = windows.first(where: { AXWin.title($0) == ref.title && !used.contains(AXWin.id($0) ?? 0) })
                        ?? windows.first(where: { !used.contains(AXWin.id($0) ?? 0) }),
                      let id = AXWin.id(match) else { continue }
                observe(app.processIdentifier)
                adopt(id, match)
                used.insert(id)
                ids.append(id)
            }
            if ids.count > 1 { groups.append(Group(windows: ids, active: min(active, ids.count - 1))) }
        }
    }
}

/// Accessibility calls back on the main run loop.
private let tabCallback: AXObserverCallback = { _, element, notification, me in
    guard let me else { return }
    let groups = Unmanaged<TabGroups>.fromOpaque(me).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { groups.handle(name, element) }
}

// MARK: - The strip

/// The tabs above a group: click one to show it, drag it off the strip to take it out.
final class TabStripPanel: NSPanel {
    struct Tab: Identifiable { let id: WinID; let title: String; let icon: NSImage?; var minimized = false }

    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal                      // stacked with ordinary windows, right over its own
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }

    func show(tabs: [Tab], active: WinID, select: @escaping (WinID) -> Void, close: @escaping (WinID) -> Void,
              pullOut: @escaping (WinID) -> Void, ungroup: @escaping () -> Void) {
        hosting.rootView = AnyView(TabStrip(tabs: tabs, active: active, select: select, close: close, pullOut: pullOut, ungroup: ungroup))
    }

    func place(_ axRect: CGRect) {
        setFrame(AXWin.flipped(axRect), display: true)
        if !isVisible { orderFrontRegardless() }
    }
}

/// A tab bar like a title bar's own: solid, the window's colour, sitting flush on top of it.
private struct TabStrip: View {
    let tabs: [TabStripPanel.Tab]
    let active: WinID
    let select: (WinID) -> Void
    let close: (WinID) -> Void
    let pullOut: (WinID) -> Void
    let ungroup: () -> Void
    @State private var dragging: WinID?
    @State private var offset: CGSize = .zero
    @State private var hovered: WinID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 && tab.id != active && tabs[index - 1].id != active {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14)
                }
                HStack(spacing: MT.Space.s6) {
                    // × on the showing tab and on any you hover, as in a browser.
                    Button { close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.1), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .opacity(tab.id == active || hovered == tab.id ? 1 : 0)
                    .help("Close Window")
                    .accessibilityLabel("Close \(tab.title)")
                    if let icon = tab.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text(tab.title.isEmpty ? "Untitled" : tab.title)
                        .font(.system(size: 11.5, weight: tab.id == active ? .semibold : .regular))
                        .foregroundStyle(tab.id == active ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
                .opacity(tab.minimized ? 0.45 : 1)   // minimized: still in the group, click to bring it back
                .padding(.horizontal, MT.Space.s10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(tab.id == active ? 0.14 : hovered == tab.id ? 0.07 : 0))
                        .padding(.vertical, 3)
                }
                .contentShape(.rect)
                .offset(dragging == tab.id ? offset : .zero)
                .zIndex(dragging == tab.id ? 1 : 0)
                .onHover { hovered = $0 ? tab.id : nil }
                .onTapGesture { select(tab.id) }
                // Drag a tab down (or up) off the strip to take its window out of the group.
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { dragging = tab.id; offset = $0.translation }
                    .onEnded { value in
                        dragging = nil
                        offset = .zero
                        if abs(value.translation.height) > TabGroups.stripHeight { pullOut(tab.id) }
                    })
                .contextMenu {
                    Button("Take Out of Group") { pullOut(tab.id) }
                    Button("Ungroup All") { ungroup() }
                }
                .help(tab.title)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
