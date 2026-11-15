import AppKit
import Quartz

/// Files by name, from the Spotlight index. Names only: no contents, which is what makes Finder's search noisy.
enum FileQuery {
    /// Spotlight can't leave folders out of a query, and most hits for a common word sit inside node_modules.
    /// So it is asked for the most recently changed first, and only this many are looked at: a specific name
    /// comes back whole, a broad one as its newest files.
    static let cap = 10_000
    /// A two-letter query can keep Spotlight busy for ten seconds; after this long it is told to stop,
    /// and whatever it has found by then is the answer.
    static let patience = 1.5

    /// Asked and ranked, both off the main thread.
    /// Name matches, plus what sits in folders whose path has the words: "acme app store" finds
    /// ~/Developer/Acme-iOS/marketing/app-store-screenshots, though no file name says so.
    @concurrent static func ranked(_ query: String, in folder: String? = nil, usage: SearchUsage) async -> (rows: [FileHit], total: Int)? {
        let words = FileRank.words(query), home = NSHomeDirectory()
        async let named = run(words, in: folder)
        async let folders = words.count >= 2 ? run(words, in: folder, anyWord: true) : []
        guard let named = await named else { return nil }
        var seen = Set(named.map(\.path))
        let more = FileRank.viaPath(words, folders: await folders ?? [], home: home).filter { seen.insert($0.path).inserted }
        return FileRank.rank(query, named + more, home: home, usage: usage)
    }

    /// Every file and folder whose name contains all the words, in `folder`, or else in your home folder (iCloud
    /// Drive and cloud storage included) and on other mounted volumes. nil when Spotlight would not run the query.
    /// Waits for Spotlight off the main thread; cancelling the task stops the query at once.
    /// `anyWord`: instead, folders whose name has any of the words.
    @concurrent static func run(_ words: [String], in folder: String? = nil, anyWord: Bool = false) async -> [FileHit]? {
        var text = words.map { word -> String in
            let safe = word.replacing(#/[\\"*]/#) { "\\" + $0.0 }   // the query language's own characters, taken literally
            return "kMDItemFSName == \"*" + safe + "*\"cd"
        }.joined(separator: anyWord ? " || " : " && ")
        if anyWord { text = "(" + text + ") && kMDItemContentType == \"public.folder\"" }
        let wanted = [kMDItemLastUsedDate, kMDItemFSContentChangeDate, kMDItemContentType] as CFArray
        guard !words.isEmpty, !Task.isCancelled,
              let made = MDQueryCreate(kCFAllocatorDefault, text as CFString, wanted, [kMDItemFSContentChangeDate] as CFArray) else { return nil }
        nonisolated(unsafe) let query = made   // MDQueryStop is the one call made from another thread, and it is meant to be
        MDQuerySetSortOptionFlagsForAttribute(query, kMDItemFSContentChangeDate, UInt32(kMDQueryReverseSortOrderFlag.rawValue))
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [])
            .map(\.path).filter { $0.hasPrefix("/Volumes/") }
        MDQuerySetSearchScope(query, (folder.map { [$0] } ?? [NSHomeDirectory()] + volumes) as CFArray, 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + patience) { MDQueryStop(query) }
        let ran = await withTaskCancellationHandler {
            MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        } onCancel: { MDQueryStop(query) }
        guard ran, !Task.isCancelled else { return nil }
        func value<T>(_ name: CFString, _ index: CFIndex) -> T? {
            MDQueryGetAttributeValueOfResultAtIndex(query, name, index).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() } as? T
        }
        return (0..<min(MDQueryGetResultCount(query), cap)).compactMap { i -> FileHit? in
            // The path has to be asked of the item itself: Spotlight hands back nothing for it in the query's own value list.
            guard let item = MDQueryGetResultAtIndex(query, i),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(item).takeUnretainedValue(), kMDItemPath) as? String else { return nil }
            let used: Date? = value(kMDItemLastUsedDate, i), changed: Date? = value(kMDItemFSContentChangeDate, i)
            let type: String? = value(kMDItemContentType, i)
            return FileHit(path: path, isFolder: type == "public.folder", date: [used, changed].compactMap { $0 }.max())
        }
    }
}

/// Quick Look for the selected file, beside the search popup. Shown without taking the keyboard,
/// so typing and the arrow keys stay with the search.
@MainActor
final class FilePreview: NSObject, QLPreviewPanelDataSource {
    private var url: URL?
    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        panel.dataSource = self
        panel.level = .popUpMenu   // the search popup's own level, or it would open behind it
        panel.reloadData()
        panel.orderFront(nil)
    }

    func close() {
        if isOpen { QLPreviewPanel.shared().orderOut(nil) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
