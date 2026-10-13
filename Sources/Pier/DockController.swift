import AppKit
import SwiftUI
import MacToolsKit

@MainActor
final class DockController {
    let model = DockModel()
    let downloads = DownloadsModel()
    let nowPlaying = NowPlaying()
    let reorder = Reorder()
    /// Where each app tile sits, for working out the drop spot during a drag.
    var tileFrames: [String: CGRect] = [:]
    private let panel = DockPanel()
    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
    private let downloadsPopup = Popup(interactive: true)   // Downloads or the open-apps grid
    enum Grid { case downloads, openApps }
    private var grid: Grid?
    private let hoverPopup = Popup(interactive: false)
    private var size: CGSize = .zero

    // Hover card bookkeeping: which tile the pointer is on, and whether it's on the card itself.
    private var hoveredID: String?
    private var cardHovered = false
    private var hoverTask: Task<Void, Never>?

    init() {
        hosting.sizingOptions = []
        // Clear headroom above the glass, so a bouncing or hovered icon isn't clipped by the window edge.
        hosting.rootView = AnyView(DockView(controller: self).fixedSize().padding(.top, 12)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.fit($0) })
        panel.contentView = hosting
        fit(hosting.fittingSize)
        panel.orderFrontRegardless()
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
            downloadsPopup.show(DownloadsGrid(model: downloads, close: close), above: screenRect(frame))
        case .openApps:
            downloadsPopup.show(OpenAppsGrid(model: model, close: close), above: screenRect(frame))
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
