import Foundation

/// The text of documents read for 引文查证 and 稿件引文核对, kept on disk (0.26) so a
/// book is read once, not again after every restart. An entry is used only while the
/// file's size and modification date, and the number of its pages KongSeek has
/// recognized, are what they were; the oldest entries go when the cache grows too big.
public struct TextCache: Sendable {
    public struct Stamp: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: Double
        /// Pages of a scan recognized by KongSeek when read (0 for documents with text).
        public var recognized: Int

        public init(size: Int64, modified: Date, recognized: Int) {
            self.size = size
            self.modified = modified.timeIntervalSince1970
            self.recognized = recognized
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var stamp: Stamp
        public var pages: [String]
        public var totalPages: Int
        public var firstPage: Int
        public var isPaged: Bool
        public var unit: String
        /// The PDF's own page numbers (0.27); nil in entries written before.
        public var labels: [String]?

        public init(path: String, stamp: Stamp, pages: [String], totalPages: Int, firstPage: Int, isPaged: Bool, unit: String, labels: [String]? = nil) {
            self.labels = labels
            self.path = path
            self.stamp = stamp
            self.pages = pages
            self.totalPages = totalPages
            self.firstPage = firstPage
            self.isPaged = isPaged
            self.unit = unit
        }
    }

    public let directory: URL
    public let maximumBytes: Int64

    public init(directory: URL, maximumBytes: Int64 = 300_000_000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// FNV-1a of the path: a short, stable file name.
    static func fileName(for path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".json"
    }

    private func url(for path: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: path))
    }

    public func load(path: String, stamp: Stamp) -> Entry? {
        let file = url(for: path)
        guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.path == path, entry.stamp == stamp else { return nil }
        // Used now: the last to be dropped when the cache is trimmed.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return entry
    }

    public func store(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: entry.path), options: .atomic)
    }

    public func remove(path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }

    /// Total size of the cache in bytes.
    public var size: Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    /// Removes the least recently used entries until the cache is under its limit.
    public func trim() {
        var entries = files().sorted { $0.used < $1.used }
        var total = entries.reduce(0) { $0 + $1.size }
        while total > maximumBytes, !entries.isEmpty {
            let oldest = entries.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    public func clear() {
        for file in files() { try? FileManager.default.removeItem(at: file.url) }
    }

    private func files() -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}
