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
    /// Asks for 正文索引管理 (from the settings).
    static let openManager = Notification.Name("KongSeekOpenBookTextManager")

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

    /// Changes reported by FSEvents (0.38): when e-books, text files or folders changed,
    /// a pass runs about half a minute later (only new and changed books are read), so a
    /// book just downloaded can be searched within a minute.
    func noteChanges(_ paths: [String], service: IndexService) {
        guard Preferences.bookTextIndex, timer != nil else { return }
        let relevant = paths.contains { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return Self.extensions.contains(ext) || ext.isEmpty
        }
        guard relevant else { return }
        pendingPass?.invalidate()
        pendingPass = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self, weak service] _ in
            guard let self, let service else { return }
            if self.running { self.passAgain = true } else { self.refresh(service: service) }
        }
    }

    private var pendingPass: Timer?
    /// A change came in during a pass: run once more when it ends.
    private var passAgain = false
    private weak var lastService: IndexService?

    func refresh(service: IndexService) {
        lastService = service
        guard Preferences.bookTextIndex, !running else { return }
        running = true
        let flag = CancelFlag()
        cancel = flag
        let wanted = Preferences.indexUncoveredFolders ? Self.extensions.union(Self.documentExtensions) : Self.extensions
        service.fileEntries(under: nil, minimumSize: 1, extensions: wanted) { [weak self] entries in
            guard let self else { return }
            self.queue.async { self.process(entries, cancel: flag) }
        }
    }

    func stop() {
        cancel.cancel()
    }

    /// Reads every book again (0.43: 重建正文索引).
    func rebuild(service: IndexService) {
        stop()
        let index = self.index
        queue.async { [weak self] in
            index.removeAll()
            self?.coverage = nil
            DispatchQueue.main.async { self?.uncoveredFolderCount = 0 }
            DispatchQueue.main.async {
                self?.running = false
                self?.refresh(service: service)
            }
        }
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
        // Documents (0.39): only those in folders Spotlight does not index.
        let documents = entries.filter { Self.documentExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        let uncovered = documents.isEmpty ? [] : uncoveredFolders(documents, cancel: cancel)
        // Folders the reader left out (0.43).
        let excluded = Preferences.bookTextExcluded.map(Paths.canonical)
        for entry in entries where !excluded.contains(where: { Paths.isWithin(entry.path, $0) }) {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            if Self.documentExtensions.contains(ext) {
                guard uncovered.contains((entry.path as NSString).deletingLastPathComponent) else { continue }
            } else {
                guard Self.extensions.contains(ext) else { continue }
            }
            keep.insert(entry.path)
            if index.isCurrent(path: entry.path, size: entry.size, modified: entry.modified) || !entry.isLocal { continue }
            todo.append(entry)
        }
        index.prune(keeping: keep)
        let start = CFAbsoluteTimeGetCurrent()
        defer { if !todo.isEmpty { IndexService.recordTiming("正文索引读取", since: start, detail: "\(todo.count) 个文件") } }
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

    // MARK: Folders Spotlight does not index (0.39)

    static let documentExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "pptx", "odt"]
    private var coverage: (checked: Date, uncovered: Set<String>)?

    /// Folders holding documents Spotlight does not know: up to three documents of each
    /// folder are asked about with mdls; a folder where none is known is left to
    /// KongSeek. Checked once a day.
    private func uncoveredFolders(_ documents: [FileEntry], cancel: CancelFlag) -> Set<String> {
        if let coverage, Date().timeIntervalSince(coverage.checked) < 86_400 { return coverage.uncovered }
        var byFolder: [String: [String]] = [:]
        for document in documents where document.isLocal {
            byFolder[(document.path as NSString).deletingLastPathComponent, default: []].append(document.path)
        }
        var samples: [(folder: String, path: String)] = []
        for (folder, paths) in byFolder {
            let sorted = paths.sorted()
            let step = max(1, sorted.count / 3)
            for index in stride(from: 0, to: sorted.count, by: step).prefix(3) { samples.append((folder, sorted[index])) }
        }
        var known: [String: Bool] = [:]
        var position = 0
        while position < samples.count {
            if cancel.isCancelled { return coverage?.uncovered ?? [] }
            let batch = Array(samples[position..<min(samples.count, position + 150)])
            let output = Self.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemFSName"] + batch.map { $0.path })
            for (sample, isKnown) in zip(batch, SpotlightCoverage.indexed(mdlsOutput: output, count: batch.count)) {
                known[sample.folder] = (known[sample.folder] ?? false) || isKnown
            }
            position += 150
        }
        let uncovered = Set(known.filter { !$0.value }.map { $0.key })
        coverage = (Date(), uncovered)
        let count = uncovered.count
        DispatchQueue.main.async { [weak self] in self?.uncoveredFolderCount = count }
        return uncovered
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Folders whose documents KongSeek reads itself, for 状态与诊断.
    /// How many folders Spotlight does not index hold documents read here; main thread
    /// (0.44: copied from `coverage`, which belongs to the queue).
    private(set) var uncoveredFolderCount = 0

    private func read(_ entry: FileEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let ext = url.pathExtension.lowercased()
        if Self.documentExtensions.contains(ext) {
            // A document in a folder Spotlight does not index (0.39).
            do {
                let read = try DocumentText.read(url, maximumPages: 3_000)
                if read.pages.allSatisfy({ $0.isEmpty }) {
                    index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: "没有文字")
                } else {
                    try index.store(path: entry.path, size: entry.size, modified: entry.modified, pages: read.pages)
                }
            } catch DocumentText.Failure.noText(_) {
                index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: "扫描件")
            } catch {
                index.markUnreadable(path: entry.path, size: entry.size, modified: entry.modified, problem: "无法读取")
            }
            return
        }
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
            if !running {
                self.lastRun = Date()
                if self.passAgain, let service = self.lastService {
                    self.passAgain = false
                    self.refresh(service: service)
                }
            }
        }
    }

    /// Books whose text holds every word (each by any of its forms), for full-text
    /// search and 引文查证. Safe from any thread.
    func search(_ words: [[String]], limit: Int = 300, accept: (String) -> Bool = { _ in true }) -> [BookTextIndex.Hit] {
        guard Preferences.bookTextIndex else { return [] }
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            IndexService.recordTiming("正文索引搜索", since: start,
                                      detail: words.compactMap(\.first).joined(separator: " ") + "，\(index.summary.books) 本")
        }
        return index.search(words, limit: limit, accept: accept)
    }
}
