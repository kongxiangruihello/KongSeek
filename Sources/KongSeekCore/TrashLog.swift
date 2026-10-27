import Foundation

/// What KongSeek moved to the Trash, and from where (0.24), so a file can be put back
/// to its folder later — not only right after with ⌘Z. Only KongSeek's own moves are
/// recorded; the Trash itself is never emptied by KongSeek.
public struct TrashLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// Where the file was.
        public var original: String
        /// Where it is in the Trash (the name may have got a number there).
        public var trashed: String
        public var date: Date
        /// Which feature moved it: 搜索窗口, 空间分析, 查找重复, 书库体检, 文件清单.
        public var source: String
        public var size: Int64
        /// Set when put back from KongSeek.
        public var restored: Date?

        public init(id: UUID = UUID(), original: String, trashed: String, date: Date = Date(), source: String, size: Int64, restored: Date? = nil) {
            self.id = id
            self.original = original
            self.trashed = trashed
            self.date = date
            self.source = source
            self.size = size
            self.restored = restored
        }

        public var name: String { (original as NSString).lastPathComponent }
        public var folder: String { (original as NSString).deletingLastPathComponent }
    }

    public enum State: Equatable, Sendable {
        /// Still in the Trash; can be put back.
        case inTrash
        /// Put back from KongSeek.
        case restored
        /// No longer in the Trash: emptied, or put back from Finder.
        case gone
    }

    public enum PutBackFailure: Error, Equatable {
        case notInTrash
        /// Something with that name is at the original place again.
        case occupied
        case cannotMove(String)
    }

    /// Entries kept: three months, at most this many.
    public static let limit = 2_000
    public static let keepDays = 90

    /// Newest first.
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.date > $1.date }
    }

    public mutating func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public func state(of entry: Entry, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> State {
        if entry.restored != nil { return .restored }
        return fileExists(entry.trashed) ? .inTrash : .gone
    }

    /// Moves the file back where it was (recreating the folder if it was removed).
    public mutating func putBack(_ id: UUID, fileManager: FileManager = .default) -> Result<Entry, PutBackFailure> {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .failure(.notInTrash) }
        let entry = entries[index]
        guard entry.restored == nil, fileManager.fileExists(atPath: entry.trashed) else { return .failure(.notInTrash) }
        guard !fileManager.fileExists(atPath: entry.original) else { return .failure(.occupied) }
        do {
            try fileManager.createDirectory(atPath: entry.folder, withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: entry.trashed, toPath: entry.original)
        } catch {
            return .failure(.cannotMove(error.localizedDescription))
        }
        entries[index].restored = Date()
        return .success(entries[index])
    }

    /// Drops entries older than `keepDays` and those whose file left the Trash
    /// more than a week ago (they cannot be put back any more).
    public mutating func prune(now: Date = Date(), fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var kept: [Entry] = []
        for entry in entries {
            let left = entry.restored != nil || !fileExists(entry.trashed)
            if entry.date < oldest || (entry.date < weekAgo && left) { continue }
            kept.append(entry)
        }
        entries = kept
    }

    // MARK: Storage

    public static func load(from url: URL) -> TrashLog {
        guard let data = try? Data(contentsOf: url) else { return TrashLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TrashLog.self, from: data)) ?? TrashLog()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
