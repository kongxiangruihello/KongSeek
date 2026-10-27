import Foundation

/// Named file lists (0.24): a 文件清单 kept under a name, such as “本学期书单” or
/// “论文参考书”, to open again later. The list keeps the files' paths as they were
/// when saved; files moved or deleted since are reported, not silently dropped.
public struct SavedFileList: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var paths: [String]
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), name: String, paths: [String], created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.name = name
        self.paths = paths
        self.created = created
        self.updated = updated
    }
}

public struct SavedFileLists: Codable, Equatable, Sendable {
    /// Most recently updated first.
    public private(set) var lists: [SavedFileList] = []

    public init(lists: [SavedFileList] = []) {
        self.lists = lists.sorted { $0.updated > $1.updated }
    }

    public static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func list(named name: String) -> SavedFileList? {
        let key = Self.cleanName(name)
        return lists.first { $0.name == key }
    }

    /// Saves `paths` under `name`, replacing a list of the same name (keeping its
    /// creation date). Duplicate paths are kept once, in order.
    @discardableResult
    public mutating func save(name: String, paths: [String], date: Date = Date()) -> SavedFileList? {
        let key = Self.cleanName(name)
        guard !key.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        var list = SavedFileList(name: key, paths: unique, created: date, updated: date)
        if let index = lists.firstIndex(where: { $0.name == key }) {
            list.id = lists[index].id
            list.created = lists[index].created
            lists.remove(at: index)
        }
        lists.insert(list, at: 0)
        return list
    }

    public mutating func remove(id: UUID) {
        lists.removeAll { $0.id == id }
    }

    public mutating func rename(id: UUID, to name: String) -> Bool {
        let key = Self.cleanName(name)
        guard !key.isEmpty, let index = lists.firstIndex(where: { $0.id == id }),
              !lists.contains(where: { $0.name == key && $0.id != id }) else { return false }
        lists[index].name = key
        return true
    }

    /// Follows a file that was renamed or moved (e.g. by 批量重命名), in every list.
    public mutating func move(from old: String, to new: String) {
        for index in lists.indices {
            lists[index].paths = lists[index].paths.map { $0 == old ? new : $0 }
        }
    }

    // MARK: Storage

    public static func load(from url: URL) -> SavedFileLists {
        guard let data = try? Data(contentsOf: url) else { return SavedFileLists() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SavedFileLists.self, from: data)) ?? SavedFileLists()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
