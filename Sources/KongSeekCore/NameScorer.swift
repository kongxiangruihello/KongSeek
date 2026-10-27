import Foundation

/// Precomputed search keys of one name (folded name, extension boundary, pinyin),
/// for lists kept outside the name index such as files inside archives.
public struct NameKey: Sendable {
    let folded: [UInt8]
    let stemLength: Int
    let full: [UInt8]
    let initials: [UInt8]
    let ascii: Bool

    public init(_ name: String) {
        var cache = Pinyin.RunCache()
        self.init(name, cache: &cache)
    }

    init(_ name: String, cache: inout Pinyin.RunCache) {
        let derived = NameIndex.derive(name: name, isRoot: false, cache: &cache)
        folded = Array(derived.folded.utf8)
        stemLength = Int(derived.stemLength)
        full = Array(derived.pinyinFull.utf8)
        initials = Array(derived.pinyinInitials.utf8)
        ascii = derived.ascii
    }

    /// Keys for many names, sharing one pinyin cache.
    public static func keys(for names: [String]) -> [NameKey] {
        var cache = Pinyin.RunCache()
        return names.map { NameKey($0, cache: &cache) }
    }
}

/// Scores names exactly like the index's fuzzy-name mode (3.2 "名称：模糊"):
/// whole-name match, then per word a substring/abbreviation of the name or its pinyin.
public struct NameScorer {
    private let words: [PreparedWord]
    private let phrase: [UInt8]

    public init(words rawWords: [String]) {
        let kept = rawWords.filter { !$0.isEmpty }
        words = kept.map(PreparedWord.init)
        phrase = PreparedWord(kept.joined(separator: " ")).bytes
    }

    public var isEmpty: Bool { words.isEmpty }

    public func score(_ key: NameKey) -> Int? {
        if words.isEmpty { return 0 }
        return key.folded.withUnsafeBufferPointer { name -> Int? in
            let stem = UnsafeBufferPointer(rebasing: name[0..<min(name.count, key.stemLength)])
            let whole = phrase.withUnsafeBufferPointer { ByteMatch.equals(name, $0) || ByteMatch.equals(stem, $0) }
            if whole { return 2000 * words.count }
            return key.full.withUnsafeBufferPointer { full -> Int? in
                key.initials.withUnsafeBufferPointer { initials -> Int? in
                    var total = 0
                    for word in words {
                        let gained: Int? = word.bytes.withUnsafeBufferPointer { wordBytes in
                            if let s = Scoring.fuzzy(name, textIsASCII: key.ascii, allowsSubsequence: word.allowsSubsequence, wordBytes: wordBytes) {
                                return s + 200
                            }
                            return Scoring.pinyin(full: full, initials: initials, allowsPinyin: word.allowsPinyin, wordBytes: wordBytes)
                        }
                        guard let gained else { return nil }
                        total += gained
                    }
                    return total
                }
            }
        }
    }

    /// Convenience for one name.
    public static func score(_ name: String, words: [String]) -> Int? {
        NameScorer(words: words).score(NameKey(name))
    }
}

/// Names of the files inside .zip archives, so a search can find a file packed in
/// an archive. Thread-safe. (Adapted from KongFetch 4.10; scoring now matches the
/// name index, including pinyin.)
public final class ArchiveIndex {
    public struct Archive: Codable, Equatable {
        public var path: String
        public var size: Int
        public var modified: Double
        /// Paths inside the archive (files only).
        public var names: [String]

        public init(path: String, size: Int, modified: Double, names: [String]) {
            self.path = path
            self.size = size
            self.modified = modified
            self.names = names
        }
    }

    public struct Hit: Equatable {
        public var archive: String
        public var inner: String
        public var score: Int
    }

    private var archives: [String: Archive] = [:]
    /// Search keys of each entry's own file name, parallel to `names`.
    private var keys: [String: [NameKey]] = [:]
    private let lock = NSLock()

    public init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var archiveCount: Int { locked { archives.count } }
    public var entryCount: Int { locked { archives.values.reduce(0) { $0 + $1.names.count } } }

    public func isCurrent(path: String, size: Int, modified: Date) -> Bool {
        locked {
            guard let archive = archives[path] else { return false }
            return archive.size == size && abs(archive.modified - modified.timeIntervalSince1970) < 1
        }
    }

    public func update(_ archive: Archive) {
        let computed = NameKey.keys(for: archive.names.map { ($0 as NSString).lastPathComponent })
        locked {
            archives[archive.path] = archive
            keys[archive.path] = computed
        }
    }

    /// Forgets archives for which `keep` is false (deleted, or no longer indexed).
    public func prune(keeping keep: (String) -> Bool) {
        locked {
            archives = archives.filter { keep($0.key) }
            keys = keys.filter { archives[$0.key] != nil }
        }
    }

    /// Files inside archives whose own name (not folder) matches every word,
    /// scored like names in the index. `accept` filters by archive path and
    /// `acceptName` by the inner file name.
    public func search(_ words: [String], limit: Int = 100, accept: (String) -> Bool = { _ in true },
                       acceptName: (String) -> Bool = { _ in true }) -> [Hit] {
        let scorer = NameScorer(words: words)
        guard !scorer.isEmpty else { return [] }
        let snapshot = locked { archives.values.map { ($0, keys[$0.path] ?? []) } }
        var hits: [Hit] = []
        for (archive, entryKeys) in snapshot where accept(archive.path) && entryKeys.count == archive.names.count {
            for (index, key) in entryKeys.enumerated() {
                guard let score = scorer.score(key) else { continue }
                let inner = archive.names[index]
                guard acceptName((inner as NSString).lastPathComponent) else { continue }
                hits.append(Hit(archive: archive.path, inner: inner, score: score))
            }
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.inner < $1.inner }.prefix(limit))
    }

    public func save(to url: URL) throws {
        let data = try locked { try JSONEncoder().encode(Array(archives.values)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Archive].self, from: data) else { return }
        for archive in list { update(archive) }
    }
}
