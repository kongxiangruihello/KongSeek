import AppKit
import KongSeekCore

/// Keeps the names of the files inside the .zip archives found by the name index,
/// and takes single files out of an archive to open, preview or copy them.
/// (Ported from KongFetch 4.10; the list of archives now comes from the index
/// instead of a separate walk of the disk.)
final class ArchiveService {
    let index = ArchiveIndex()
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "KongSeek.archives", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var unreadable = 0
    /// Called on main when a scan starts or ends.
    var onChange: (() -> Void)?

    /// Archives larger than this are not opened for their table of contents.
    static let maximumArchiveSize = 4_000_000_000
    /// Entries kept per archive.
    static let maximumEntries = 50_000

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        queue.async { [index] in index.load(from: cacheURL) }
    }

    /// Rescans every two hours with the archive paths `source` provides; `nil` stops and forgets everything.
    func configure(source: ((@escaping ([String]) -> Void) -> Void)?) {
        timer?.invalidate()
        timer = nil
        guard let source else {
            generation += 1
            isScanning = false
            queue.async { [index, cacheURL] in
                index.prune { _ in false }
                try? index.save(to: cacheURL)
            }
            onChange?()
            return
        }
        let run = { [weak self] in
            source { paths in DispatchQueue.main.async { self?.scan(paths) } }
        }
        run()
        let timer = Timer(timeInterval: 2 * 3600, repeats: true) { _ in run() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads the table of contents of archives that are new or changed, and forgets
    /// archives that are no longer in `paths`.
    func scan(_ paths: [String]) {
        generation += 1
        let current = generation
        isScanning = true
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
            var seen = Set<String>()
            var failed = 0
            for path in paths {
                guard current == self.generation else { return }
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                // Reading an iCloud placeholder would download it; skip until it is local.
                if let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded { continue }
                seen.insert(path)
                let size = values.fileSize ?? 0
                let modified = values.contentModificationDate ?? .distantPast
                guard size <= Self.maximumArchiveSize, !self.index.isCurrent(path: path, size: size, modified: modified) else { continue }
                let names: [String]
                do {
                    names = try ZipReader.entries(at: url, limit: Self.maximumEntries).filter(ZipReader.isListable).map(\.name)
                } catch {
                    failed += 1
                    names = []
                }
                self.index.update(.init(path: path, size: size, modified: modified.timeIntervalSince1970, names: names))
            }
            guard current == self.generation else { return }
            self.index.prune { seen.contains($0) }
            try? self.index.save(to: self.cacheURL)
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                self.isScanning = false
                self.lastScan = Date()
                self.unreadable = failed
                self.onChange?()
            }
        }
    }

    var statusText: String {
        if isScanning { return "正在读取压缩包目录… 已收录 \(index.archiveCount) 个压缩包" }
        var text = "已收录 \(index.archiveCount.formatted()) 个压缩包、\(index.entryCount.formatted()) 个文件"
        if let lastScan { text += " · 扫描于 \(lastScan.formatted(date: .omitted, time: .shortened))" }
        if unreadable > 0 { text += " · \(unreadable) 个无法读取（加密或格式不支持）" }
        return text
    }

    // MARK: - Taking files out

    private static let extractLock = NSLock()
    private static var extracted: [String: URL] = [:]

    /// The folder that holds files taken out of archives (cleared by macOS like other caches).
    static var extractionFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.kongxiangrui.KongSeek/压缩包中的文件", isDirectory: true)
    }

    /// Extracts one file into KongSeek's cache (once per archive version) and calls
    /// `completion` on main with its location.
    static func extract(inner: String, from archive: String, maximumSize: UInt64 = 1_000_000_000,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        let modified = IndexService.modificationTime(archive)
        let key = "\(archive)\u{0}\(modified)\u{0}\(inner)"
        DispatchQueue.global(qos: .userInitiated).async {
            extractLock.lock()
            let cached = extracted[key]
            extractLock.unlock()
            if let cached, FileManager.default.fileExists(atPath: cached.path) {
                DispatchQueue.main.async { completion(.success(cached)) }
                return
            }
            do {
                let url = URL(fileURLWithPath: archive)
                guard let entry = try ZipReader.entries(at: url).first(where: { $0.name == inner }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let folder = extractionFolder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(6)))
                let destination = folder.appendingPathComponent(entry.fileName)
                try ZipReader.extract(entry, from: url, to: destination, maximumSize: maximumSize)
                extractLock.lock()
                extracted[key] = destination
                extractLock.unlock()
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
