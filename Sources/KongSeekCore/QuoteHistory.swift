import Foundation

/// 引文查证的历史记录 (0.33): the quotations looked up lately, each with what was found,
/// so a result can be seen again or its reference copied without looking it up again.
public struct QuoteHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var quote: String
        public var date: Date
        public var results: [ManuscriptSession.Source]
        /// Files only in iCloud that could not be checked.
        public var inCloud: Int

        public init(quote: String, date: Date = Date(), results: [ManuscriptSession.Source], inCloud: Int = 0) {
            self.quote = quote
            self.date = date
            self.results = results
            self.inCloud = inCloud
        }

        /// The quotation shortened for a menu: "学而时习之，不亦说乎…".
        public var title: String {
            let line = quote.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return line.count > 28 ? String(line.prefix(28)) + "…" : line
        }

        /// "完全一致 1 处" / "近似 2 处" / "未找到".
        public var summary: String {
            guard let best = results.first else { return "未找到" }
            let exact = results.filter { $0.score >= 1 }.count
            return exact > 0 ? "完全一致 \(exact) 处" : "近似 \(results.count) 处（最高 \(Int((best.score * 100).rounded()))%）"
        }
    }

    public static let limit = 100
    /// Results kept per quotation.
    public static let resultsKept = 20

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Adds a lookup; an earlier lookup of the same quotation (by its words) is replaced.
    public mutating func add(_ entry: Entry) {
        var entry = entry
        entry.results = Array(entry.results.prefix(Self.resultsKept))
        let key = ManuscriptSession.key(entry.quote)
        entries.removeAll { ManuscriptSession.key($0.quote) == key }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public func entry(for quote: String) -> Entry? {
        let key = ManuscriptSession.key(quote)
        return entries.first { ManuscriptSession.key($0.quote) == key }
    }

    public mutating func remove(_ quote: String) {
        let key = ManuscriptSession.key(quote)
        entries.removeAll { ManuscriptSession.key($0.quote) == key }
    }

    public mutating func removeAll() { entries = [] }

    // MARK: Storage

    public static func load(from url: URL) -> QuoteHistory {
        guard let data = try? Data(contentsOf: url) else { return QuoteHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(QuoteHistory.self, from: data)) ?? QuoteHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
