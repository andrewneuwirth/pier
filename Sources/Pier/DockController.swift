import AppKit
import SwiftUI
import MacToolsKit

@MainActor
final class DockController {
    let model = DockModel()
    let downloads = DownloadsModel()
    let nowPlaying = NowPlaying()
    let reorder = Reorder()
    let sendBox = SendBox()
    var trashFrame: CGRect = .zero
    var linksFrame: CGRect = .zero
    var projectLinksFrame: CGRect = .zero
    /// Where each app tile sits, for working out the drop spot during a drag.
    var tileFrames: [String: CGRect] = [:]
    private let panel = DockPanel()
    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
    private let downloadsPopup = Popup(interactive: true)   // Downloads or the open-apps grid
    enum Grid { case downloads, openApps, links, projectLinks }
    private var grid: Grid?
    private let hoverPopup = Popup(interactive: false)
    private var size: CGSize = .zero

    // Hover card bookkeeping: which tile the pointer is on, and whether it's on the card itself.
    private var hoveredID: String?
    private var cardHovered = false
    private var hoverTask: Task<Void, Never>?
    /// After a right-click, no hover card for that tile until the pointer leaves it.
    private var suppressedID: String?
    private let menuTarget = MenuTarget()
    private let escCloser = EscCloser()

    init() {
        hosting.sizingOptions = []
        // Clear headroom above the glass, so a bouncing or hovered icon isn't clipped by the window edge.
        hosting.rootView = AnyView(DockView(controller: self).fixedSize().padding(.top, 12)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.fit($0) })
        panel.contentView = hosting
        hosting.acceptDrops()
        hosting.dropRouter = barDrops()
        fit(hosting.fittingSize)
        panel.orderFrontRegardless()
        // Right-clicking an app: its own Dock menu items plus Pier's. Elsewhere on the bar, Pier's menu.
        hosting.rightClick = { [weak self] point in
            guard let self, let item = self.item(at: point) else { return nil }
            return self.menu(for: item)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.fit(self.size) } }
        }
    }

    /// The display the bar lives on, chosen in Show On. Unplugged (the TV), it falls back to the
    /// display with the menu bar, and returns when it's connected again.
    private(set) var screenName = UserDefaults.standard.string(forKey: "screenName")
        ?? NSScreen.screens.first?.localizedName ?? ""
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.localizedName == screenName } ?? NSScreen.screens.first
    }

    func show(on name: String) {
        screenName = name
        UserDefaults.standard.set(name, forKey: "screenName")
        model.tileSize = DockModel.maxTile   // re-fit for the new width
        fit(size)
    }

    /// Bottom centre of the chosen display, 6pt above the edge. Too wide for the screen,
    /// or narrower than it needs to be after an app quits: resize the tiles, which lays out again
    /// and lands back here.
    private func fit(_ newSize: CGSize) {
        guard newSize.width > 0, let screen else { return }
        let room = screen.frame.width - 2 * MT.Space.s8
        let tile = model.tileSize
        let wanted = min(DockModel.maxTile, max(DockModel.minTile, (tile * room / newSize.width).rounded(.down)))
        if (newSize.width > room && wanted < tile) || (newSize.width < room && wanted > tile) {
            model.tileSize = wanted
        }
        size = newSize
        panel.setFrame(NSRect(x: (screen.frame.midX - newSize.width / 2).rounded(), y: screen.frame.minY + 6,
                              width: newSize.width, height: newSize.height), display: true)
    }

    /// A SwiftUI `.global` frame inside the bar, in screen coordinates.
    func screenRect(_ frame: CGRect) -> NSRect {
        NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Hover card

    func hoverChanged(_ item: AppItem, inside: Bool, frame: CGRect) {
        if suppressedID == item.id {
            if !inside { suppressedID = nil }
            return
        }
        hoverTask?.cancel()
        if inside {
            hoveredID = item.id
            guard !downloadsPopup.isVisible else { return }
            let delay: Duration = hoverPopup.isVisible ? .zero : .milliseconds(350)   // glide between tiles
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.hoveredID == item.id else { return }
                self.showCard(for: item, at: self.screenRect(frame))
            }
        } else {
            if hoveredID == item.id { hoveredID = nil }
            scheduleCardClose()
        }
    }

    /// Hovering the MEM ring: which apps are using the memory.
    func memoryHover(_ inside: Bool, frame: CGRect) {
        hoverTask?.cancel()
        let id = "memory"
        if inside {
            hoveredID = id
            guard !downloadsPopup.isVisible else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.hoveredID == id else { return }
                self.hoverPopup.show(MemoryCard(model: self.model, controller: self), above: self.screenRect(frame))
            }
        } else {
            if hoveredID == id { hoveredID = nil }
            scheduleCardClose()
        }
    }

    private func showCard(for item: AppItem, at anchor: NSRect) {
        let app = model.running[item.id]
        let previews = WindowPreviews()
        if let app { Task { await previews.load(pid: app.processIdentifier) } }
        hoverPopup.show(HoverCard(item: item, app: app, previews: previews, controller: self), above: anchor)
    }

    func cardHover(_ inside: Bool) {
        cardHovered = inside
        if !inside { scheduleCardClose() } else { hoverTask?.cancel() }
    }

    private func scheduleCardClose() {
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))   // time to move from the tile onto the card
            guard !Task.isCancelled, let self, self.hoveredID == nil, !self.cardHovered else { return }
            self.hoverPopup.close()
        }
    }

    func closeCard() {
        hoverTask?.cancel()
        cardHovered = false
        hoverPopup.close()
    }

    // MARK: Right-click menu

    private func menu(for item: AppItem) -> NSMenu {
        suppressedID = item.id
        closeCard()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = escCloser
        // Windows first, read directly; then the app's actions (from the Dock, remembered); then Pier's.
        let windows = model.running[item.id].map { app in DockMenus.windows(of: app).map { ($0, app) } } ?? []
        for (window, app) in windows {
            menu.addItem(menuTarget.item(window.title) { DockMenus.raise(window.element, of: app) })
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        let actions = DockMenus.actions(item, windowTitles: Set(windows.map(\.0.title)))
        add(actions, path: [], to: menu, of: item)
        if !actions.isEmpty { menu.addItem(.separator()) }
        addPierItems(for: item, to: menu)
        return menu
    }

    private func add(_ entries: [DockMenus.Entry], path: [String], to menu: NSMenu, of item: AppItem) {
        for entry in entries {
            if entry.title.isEmpty { menu.addItem(.separator()); continue }
            let path = path + [entry.title]
            if entry.children.isEmpty {
                menu.addItem(menuTarget.item(entry.title, enabled: entry.enabled) { DockMenus.press(path, of: item) })
            } else {
                let parent = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                add(entry.children, path: path, to: submenu, of: item)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
    }

    /// The same items as AppMenu (which the overflow grid still uses).
    private func addPierItems(for item: AppItem, to menu: NSMenu) {
        if item != model.finder {
            let keep = NSMenuItem(title: "Keep in Pier", action: nil, keyEquivalent: "")
            let groups = NSMenu()
            for (index, name) in model.groupNames.enumerated() {
                groups.addItem(menuTarget.item(name) { [weak self] in self?.model.pin(item, toGroup: index) })
            }
            keep.submenu = groups
            menu.addItem(keep)
            if model.isPinned(item) {
                menu.addItem(menuTarget.item("Remove from Pier") { [weak self] in self?.model.unpin(item) })
            } else {
                menu.addItem(menuTarget.item("Hide from Pier") { [weak self] in self?.model.hide(item) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuTarget.item("Change Icon…") { [weak self] in self?.model.chooseIcon(for: item) })
        if model.hasCustomIcon(item) {
            menu.addItem(menuTarget.item("Use Original Icon") { [weak self] in self?.model.setIcon(nil, for: item) })
        }
        menu.addItem(.separator())
        menu.addItem(menuTarget.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) })
        if model.isRunning(item) {
            menu.addItem(.separator())
            menu.addItem(menuTarget.item("Quit") { [weak self] in self?.model.quit(item) })
        }
    }

    // MARK: Drops on the bar

    /// Files dropped on an app open with it; an app dropped on the bar pins before that tile; anything
    /// dropped on the Trash goes to the Trash.
    private func barDrops() -> FirstClickHostingView<AnyView>.DropRouter {
        .init(over: { [weak self] point in
            guard let self, let point else { return false }
            return self.trashFrame.contains(point) || self.linksFrame.contains(point)
                || self.projectLinksFrame.contains(point) || self.item(at: point) != nil
        }, drop: { [weak self] urls, point in
            guard let self, !urls.isEmpty else { return false }
            if self.linksFrame.contains(point) || self.projectLinksFrame.contains(point) {   // from a browser's address bar
                let kind: DockModel.LinkKind = self.linksFrame.contains(point) ? .quick : .projects
                urls.filter { !$0.isFileURL }.forEach { self.model.addLink($0, to: kind) }
                return true
            }
            if self.trashFrame.contains(point) {
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                return true
            }
            guard let target = self.item(at: point) else { return false }
            let apps = urls.filter { $0.pathExtension == "app" }
            if apps.isEmpty { self.model.open(target, files: urls) } else { apps.forEach { self.model.place($0, relativeTo: target) } }
            return true
        })
    }

    private func item(at point: CGPoint) -> AppItem? {
        guard let id = tileFrames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return (model.groups.flatMap { $0 } + model.recent + model.overflow + [model.finder]).first { $0.id == id }
    }

    // MARK: Reorder

    func dragChanged(_ item: AppItem, _ drag: DragGesture.Value) {
        guard item != model.finder else { return }   // Finder stays first
        closeCard()
        reorder.dragging = item.id
        reorder.offset = drag.translation
        reorder.removing = model.isPinned(item) && drag.translation.height < -60
        guard !reorder.removing else { reorder.target = nil; return }
        // Nearest pinned tile (or Finder) to the pointer; its left or right half says before or after.
        let targets = (model.groups.flatMap { $0 } + [model.finder]).filter { $0 != item }
        let nearest = targets.compactMap { t in tileFrames[t.id].map { (t, $0) } }
            .min { abs($0.1.midX - drag.location.x) < abs($1.1.midX - drag.location.x) }
        if let (target, frame) = nearest, abs(frame.midX - drag.location.x) < frame.width * 1.5 {
            reorder.target = (target.id, target != model.finder && drag.location.x > frame.midX)
        } else {
            reorder.target = nil
        }
    }

    func dragEnded(_ item: AppItem, _ drag: DragGesture.Value) {
        defer { reorder.dragging = nil; reorder.offset = .zero; reorder.target = nil; reorder.removing = false }
        guard item != model.finder else { return }
        if reorder.removing {
            model.unpin(item)
        } else if let target = reorder.target,
                  let targetItem = (model.groups.flatMap { $0 } + [model.finder]).first(where: { $0.id == target.id }) {
            model.place(item.url, relativeTo: targetItem, after: target.after)
        }
    }

    // MARK: Downloads

    func toggleGrid(_ kind: Grid, from frame: CGRect) {
        closeCard()
        // The outside-click monitor already closed it on mouse-down; don't reopen the same grid on that click.
        let sameJustClosed = grid == kind && Date().timeIntervalSince(downloadsPopup.closedAt) < 0.3
        if (downloadsPopup.isVisible && grid == kind) || sameJustClosed {
            downloadsPopup.close()
            return
        }
        grid = kind
        let close: () -> Void = { [weak self] in self?.downloadsPopup.close() }
        switch kind {
        case .downloads:
            downloads.refresh()
            let box = sendBox
            downloadsPopup.show(DownloadsGrid(model: downloads, sendBox: box, close: close), above: screenRect(frame),
                                drop: .init(over: { point in
                                    box.targeted = point.map { box.frame.contains($0) } ?? false
                                    return box.targeted
                                }, drop: { urls, point in
                                    guard box.frame.contains(point), let file = urls.first else { return false }
                                    box.file = file
                                    return true
                                }))
        case .openApps:
            downloadsPopup.show(OpenAppsGrid(model: model, close: close), above: screenRect(frame))
        case .links:
            downloadsPopup.show(LinksList(kind: .quick, model: model, controller: self, close: close), above: screenRect(frame))
        case .projectLinks:
            downloadsPopup.show(LinksList(kind: .projects, model: model, controller: self, close: close), above: screenRect(frame))
        }
    }

    // MARK: Pier

    func editGroups() {
        _ = GroupsFile.load()   // make sure there's a file to open
        NSWorkspace.shared.open(GroupsFile.url)
    }

    func quit() {
        SystemDock.restore()
        NSApp.terminate(nil)
    }
}

/// The tile being dragged, how far, and where it would land.
@MainActor @Observable
final class Reorder {
    var dragging: String?
    var offset: CGSize = .zero
    var target: (id: String, after: Bool)?
    var removing = false
}

/// The Downloads send box: what was dropped, whether a drag is over it, and where it is.
@MainActor @Observable
final class SendBox {
    var file: URL?
    var targeted = false
    var frame: CGRect = .zero
}

/// Runs a closure when an NSMenuItem is chosen.
@MainActor
final class MenuTarget: NSObject {
    private final class Box: NSObject { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }

    func item(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = Box(run)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) { (sender.representedObject as? Box)?.run() }
}

/// Pier is never the frontmost app, and a menu only hears the keyboard (Esc, arrows, Return) in the
/// active app. Activate while the menu is open (the older call: the cooperative one is refused
/// here), then give focus back to the app you were in unless the chosen item moved it elsewhere.
@MainActor
final class EscCloser: NSObject, NSMenuDelegate {
    private var previous: NSRunningApplication?

    func menuWillOpen(_ menu: NSMenu) {
        previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        let previous = previous
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
               let previous, previous.processIdentifier != getpid() { previous.activate() }
        }
    }
}
