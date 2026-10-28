import Foundation

/// KongSeek's own full-text index (0.37, after ripgrep-all's text cache and sist2's
/// e-book extraction): the text of books Spotlight does not read — EPUB, Mobipocket and
/// Kindle files, text files in GB18030 — kept as plain UTF-8 files (pages separated by
/// form feeds) and searched directly, so full-text search and 引文查证 reach them too.
/// Thread-safe.
public final class BookTextIndex {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: Double
        /// The text file's name in the index folder; empty when the book had no readable text.
        public var file: String
        public var pages: Int
        public var characters: Int
        /// Why there is no text ("DRM"), if so.
        public var problem: String?
    }

    public struct Hit: Equatable, Sendable {
        public var path: String
        /// How often the words occur (up to 100 each), to rank by.
        public var count: Int
    }

    public static let pageSeparator = "\u{0C}"
    /// The `problem` of a text file Spotlight reads itself (UTF-8): not a problem, just not indexed here.
    public static let readBySpotlight = "UTF-8"

    public let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    public func load() {
        let loaded = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        lock.lock()
        entries = loaded
        lock.unlock()
    }

    public func saveManifest() throws {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: manifestURL, options: .atomic)
    }

    public var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    public func entry(for path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    /// Books with text, and their characters.
    public var summary: (books: Int, characters: Int, problems: Int) {
        lock.lock()
        defer { lock.unlock() }
        let withText = entries.values.filter { !$0.file.isEmpty }
        let problems = entries.values.filter { $0.problem != nil && $0.problem != Self.readBySpotlight }.count
        return (withText.count, withText.reduce(0) { $0 + $1.characters }, problems)
    }

    /// Whether the book was read as it is now (or found unreadable as it is now).
    public func isCurrent(path: String, size: Int64, modified: Date) -> Bool {
        guard let entry = entry(for: path) else { return false }
        return entry.size == size && abs(entry.modified - modified.timeIntervalSince1970) < 0.001
    }

    public func store(path: String, size: Int64, modified: Date, pages: [String]) throws {
        let text = pages.joined(separator: Self.pageSeparator)
        var entry = Entry(size: size, modified: modified.timeIntervalSince1970, file: "", pages: pages.count, characters: text.count, problem: nil)
        if !text.isEmpty {
            entry.file = TextCache.fileName(for: path).replacingOccurrences(of: ".json", with: ".txt")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent(entry.file), options: .atomic)
        }
        lock.lock()
        entries[path] = entry
        lock.unlock()
    }

    /// Remembers that the book has no text KongSeek can read, so it is not tried again until it changes.
    public func markUnreadable(path: String, size: Int64, modified: Date, problem: String) {
        lock.lock()
        entries[path] = Entry(size: size, modified: modified.timeIntervalSince1970, file: "", pages: 0, characters: 0, problem: problem)
        lock.unlock()
    }

    public func remove(_ path: String) {
        lock.lock()
        let removed = entries.removeValue(forKey: path)
        lock.unlock()
        if let file = removed?.file, !file.isEmpty { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
    }

    /// Forgets books no longer among `paths` (deleted, moved, or in folders no longer indexed).
    public func prune(keeping paths: Set<String>) {
        for path in self.paths where !paths.contains(path) { remove(path) }
    }

    /// The book's text by page (EPUB: by content file).
    public func pages(for path: String) -> [String]? {
        guard let entry = entry(for: path), !entry.file.isEmpty,
              let data = try? Data(contentsOf: directory.appendingPathComponent(entry.file)) else { return nil }
        return String(decoding: data, as: UTF8.self).components(separatedBy: Self.pageSeparator)
    }

    /// Books whose text holds every word, by any of its forms; most occurrences first.
    public func search(_ words: [[String]], limit: Int = 300, accept: (String) -> Bool = { _ in true }) -> [Hit] {
        let needles: [[Data]] = words.map { forms in
            var all: [String] = []
            for form in forms {
                for variant in SearchText.scriptVariants(form) + [form.lowercased(), form.capitalized] where !variant.isEmpty && !all.contains(variant) {
                    all.append(variant)
                }
            }
            return all.map { Data($0.utf8) }
        }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        lock.lock()
        let candidates = entries.filter { !$0.value.file.isEmpty }.map { (path: $0.key, file: $0.value.file) }
        lock.unlock()
        let accepted = candidates.filter { accept($0.path) }
        let chunk = 16
        let chunkCount = (accepted.count + chunk - 1) / chunk
        var parts = [[Hit]](repeating: [], count: chunkCount)
        let folder = directory
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                var found: [Hit] = []
                for item in accepted[(c * chunk)..<min(accepted.count, (c + 1) * chunk)] {
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent(item.file), options: .alwaysMapped) else { continue }
                    var total = 0
                    var all = true
                    for forms in needles {
                        let count = forms.reduce(0) { $0 + BookTextIndex.occurrences(of: $1, in: data, upTo: 100) }
                        if count == 0 { all = false; break }
                        total += min(100, count)
                    }
                    if all { found.append(Hit(path: item.path, count: total)) }
                }
                output[c] = found
            }
        }
        return Array(parts.flatMap { $0 }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.path < $1.path }.prefix(limit))
    }

    static func occurrences(of needle: Data, in data: Data, upTo maximum: Int) -> Int {
        var count = 0
        var start = data.startIndex
        while count < maximum, start < data.endIndex, let range = data.range(of: needle, in: start..<data.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    // MARK: Which files

    /// Whether KongSeek indexes this file's text itself: e-books Spotlight does not read,
    /// and text files that are not UTF-8 (GB18030), which Spotlight may not decode.
    public static func wants(_ path: String, firstBytes: () -> Data?) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if EbookText.supports(ext) { return true }
        guard ext == "txt", let head = firstBytes(), !head.isEmpty else { return false }
        return !isUTF8(head)
    }

    /// UTF-8, allowing a character cut off at the end of the sample.
    public static func isUTF8(_ data: Data) -> Bool {
        if String(data: data, encoding: .utf8) != nil { return true }
        for cut in 1...3 where data.count > cut {
            if String(data: data.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
