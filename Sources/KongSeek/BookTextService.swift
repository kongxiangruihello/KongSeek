import AppKit
import KongSeekCore
import KongSeekText

/// Keeps KongSeek's own text index (0.37) of the books Spotlight does not read — EPUB,
/// Mobipocket / Kindle, GB18030 text — in step with the name index: after it loads,
/// then every six hours, the new and changed ones are read in the background, one at
/// a time, and books that are gone are forgotten. Files only in iCloud are skipped.
final class BookTextService {
    static let shared = BookTextService()
    /// Posted when the setting is turned on or off.
    static let settingChanged = Notification.Name("KongSeekBookTextSettingChanged")

    let index: BookTextIndex
    private let queue = DispatchQueue(label: "KongSeek.book-text", qos: .utility)
    private var cancel = CancelFlag()
    private var timer: Timer?
    /// Read on main: the book being read, and how far along.
    private(set) var current: String?
    private(set) var progress = (done: 0, total: 0)
    private(set) var running = false
    private(set) var lastRun: Date?

    static let extensions: Set<String> = EbookText.extensions.union(["txt"])
    /// Text files larger than this are left to Spotlight.
    static let textLimit = 30_000_000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        index = BookTextIndex(directory: support.appendingPathComponent("KongSeek/BookText", isDirectory: true))
        let index = self.index
        queue.async { index.load() }
    }

    /// Starts the first pass and the six-hourly ones.
    func start(service: IndexService) {
        guard timer == nil else { return }
        refresh(service: service)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self, weak service] _ in
            if let service { self?.refresh(service: service) }
        }
    }

    func refresh(service: IndexService) {
        guard Preferences.bookTextIndex, !running else { return }
        running = true
        let flag = CancelFlag()
        cancel = flag
        service.fileEntries(under: nil, minimumSize: 1, extensions: Self.extensions) { [weak self] entries in
            guard let self else { return }
            self.queue.async { self.process(entries, cancel: flag) }
        }
    }

    func stop() {
        cancel.cancel()
    }

    private func process(_ entries: [FileEntry], cancel: CancelFlag) {
        let index = self.index
        // No list (the name index not loaded yet): nothing to compare with, so nothing is forgotten.
        guard !entries.isEmpty else {
            publish(done: 0, total: 0, current: nil, running: false)
            return
        }
        var keep = Set<String>()
        var todo: [FileEntry] = []
        for entry in entries {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard Self.extensions.contains(ext) else { continue }
            keep.insert(entry.path)
            if index.isCurrent(path: entry.path, size: entry.size, modified: entry.modified) || !entry.isLocal { continue }
            todo.append(entry)
        }
        index.prune(keeping: keep)
        publish(done: 0, total: todo.count, current: nil, running: !todo.isEmpty)
        for (number, entry) in todo.enumerated() {
            if cancel.isCancelled || !Preferences.bookTextIndex { break }
            publish(done: number, total: todo.count, current: entry.path, running: true)
            autoreleasepool { read(entry) }
            if number % 20 == 19 { try? index.saveManifest() }
        }
        try? index.saveManifest()
        publish(done: todo.count, total: todo.count, current: nil, running: false)
    }

    private func read(_ entry: FileEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let ext = url.pathExtension.lowercased()
        if ext == "txt" {
            guard entry.size <= Int64(Self.textLimit), let data = try? Data(contentsOf: url) else {
                index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: BookTextIndex.readBySpotlight)
                return
            }
            guard !BookTextIndex.isUTF8(data.prefix(65_536)), let text = ContentPreview.decodeGB18030(data) else {
                index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: BookTextIndex.readBySpotlight)
                return
            }
            try? index.store(path: entry.path, size: entry.size, modified: entry.modified, pages: [text])
            return
        }
        do {
            let pages = try EbookText.read(url)
            if pages.isEmpty {
                index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: "没有文字")
            } else {
                try index.store(path: entry.path, size: entry.size, modified: entry.modified, pages: pages)
            }
        } catch EbookText.Failure.unsupported(let why) {
            index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: why)
        } catch {
            index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: "无法读取")
        }
    }

    private func publish(done: Int, total: Int, current: String?, running: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progress = (done, total)
            self.current = current
            self.running = running
            if !running { self.lastRun = Date() }
        }
    }

    /// Books whose text holds every word (each by any of its forms), for full-text
    /// search and 引文查证. Safe from any thread.
    func search(_ words: [[String]], limit: Int = 300, accept: (String) -> Bool = { _ in true }) -> [BookTextIndex.Hit] {
        guard Preferences.bookTextIndex else { return [] }
        return index.search(words, limit: limit, accept: accept)
    }
}
