import Foundation

/// 常用本 (0.28): of several editions of a book (中华书局本、上古本…), the one the reader
/// cites. It comes first in 引文查证, 稿件引文核对 and 出处汇编, so its page and
/// reference are the ones copied. One per book, by the title in the file name.
public struct PreferredEditions: Codable, Equatable, Sendable {
    /// Book key (or the path, for files that are not books) → preferred file.
    public private(set) var byBook: [String: String] = [:]

    public init() {}

    static func key(for path: String) -> String {
        DuplicateFinder.bookKey((path as NSString).lastPathComponent) ?? path
    }

    public func isPreferred(_ path: String) -> Bool {
        byBook[Self.key(for: path)] == path
    }

    /// The preferred edition of the book `path` is an edition of, if one is set.
    public func preferred(forBookOf path: String) -> String? {
        byBook[Self.key(for: path)]
    }

    /// Makes `path` the preferred edition of its book (replacing another edition).
    public mutating func prefer(_ path: String) {
        byBook[Self.key(for: path)] = path
    }

    public mutating func remove(_ path: String) {
        let key = Self.key(for: path)
        if byBook[key] == path { byBook.removeValue(forKey: key) }
    }

    public mutating func move(from old: String, to new: String) {
        guard isPreferred(old) else { return }
        remove(old)
        byBook[Self.key(for: new)] = new
    }

    /// Items in order: exact matches before near ones, and among equals the preferred
    /// editions first; otherwise the order given is kept.
    public func ordered<T>(_ items: [T], path: (T) -> String, exact: (T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            let exactA = exact(a.element), exactB = exact(b.element)
            if exactA != exactB { return exactA }
            let preferredA = isPreferred(path(a.element)), preferredB = isPreferred(path(b.element))
            if preferredA != preferredB { return preferredA }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Storage

    public static func load(from url: URL) -> PreferredEditions {
        guard let data = try? Data(contentsOf: url) else { return PreferredEditions() }
        return (try? JSONDecoder().decode(PreferredEditions.self, from: data)) ?? PreferredEditions()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
