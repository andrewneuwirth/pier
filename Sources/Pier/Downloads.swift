import AppKit
import Observation
import QuickLookThumbnailing

struct DownloadItem: Identifiable, Equatable {
    let url: URL
    let added: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// ~/Downloads, newest first, kept live by watching the folder.
@MainActor @Observable
final class DownloadsModel {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    static let limit = 24

    private(set) var items: [DownloadItem] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    @ObservationIgnored private var watch: DispatchSourceFileSystemObject?

    init() {
        refresh()
        let fd = Darwin.open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = source
    }

    func refresh() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let fresh = urls.map { url -> DownloadItem in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return DownloadItem(url: url, added: v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast)
        }
        // Partial downloads (.crdownload, .download) are hidden until they finish.
        .filter { !["crdownload", "download", "part"].contains($0.url.pathExtension) }
        .sorted { $0.added > $1.added }
        .prefix(Self.limit)
        items = Array(fresh)
        for item in items where thumbnails[item.url] == nil { loadThumbnail(item.url) }
    }

    private func loadThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)   // until Quick Look answers
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnails[url] = image } }
        }
    }
}
