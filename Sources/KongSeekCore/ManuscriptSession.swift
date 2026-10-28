import Foundation

/// 稿件引文核对 kept between sessions (0.31): what each quotation of a manuscript was
/// found to be, so reopening the manuscript shows it again, and after the manuscript is
/// edited only new or changed quotations are checked.
public struct ManuscriptSession: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var path: String
        public var title: String
        public var page: Int?
        public var unit: String
        public var score: Double
        public var excerpt: String
        public var book: EbookName?
        public var label: String?

        public init(path: String, title: String, page: Int?, unit: String, score: Double, excerpt: String, book: EbookName?, label: String?) {
            self.path = path
            self.title = title
            self.page = page
            self.unit = unit
            self.score = score
            self.excerpt = excerpt
            self.book = book
            self.label = label
        }
    }

    public struct Checked: Codable, Equatable, Sendable {
        public var quote: String
        /// Nil when no source was found.
        public var source: Source?
        public var others: Int

        public init(quote: String, source: Source?, others: Int) {
            self.quote = quote
            self.source = source
            self.others = others
        }
    }

    public var manuscript: String
    public var saved: Date
    public var checked: [Checked]

    public init(manuscript: String, saved: Date = Date(), checked: [Checked]) {
        self.manuscript = manuscript
        self.saved = saved
        self.checked = checked
    }

    static func key(_ quote: String) -> String {
        String(QuoteMatcher.normalized(quote))
    }

    /// The earlier result for a quotation, matched by its words (punctuation, spacing and
    /// character forms aside), so a quotation the manuscript still has keeps its result.
    public func result(for quote: String) -> Checked? {
        let wanted = Self.key(quote)
        return checked.first { Self.key($0.quote) == wanted }
    }

    /// Passages pasted rather than read from a file (0.32) share one session under this name.
    public static let pasted = "〔粘贴的文字〕"

    /// This session with `newer` results added (0.33): those replace earlier results for the
    /// same quotation; the rest are kept, the most recent first, up to `limit`.
    public func merging(_ newer: [Checked], limit: Int = 1_000, saved date: Date = Date()) -> ManuscriptSession {
        var seen = Set<String>()
        var merged: [Checked] = []
        for item in newer + checked where seen.insert(Self.key(item.quote)).inserted {
            merged.append(item)
            if merged.count >= limit { break }
        }
        return ManuscriptSession(manuscript: manuscript, saved: date, checked: merged)
    }

    // MARK: Storage

    public static func url(for manuscript: String, in folder: URL) -> URL {
        folder.appendingPathComponent(TextCache.fileName(for: manuscript))
    }

    public static func load(for manuscript: String, in folder: URL) -> ManuscriptSession? {
        guard let data = try? Data(contentsOf: url(for: manuscript, in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let session = try? decoder.decode(ManuscriptSession.self, from: data), session.manuscript == manuscript else { return nil }
        return session
    }

    public func save(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(for: manuscript, in: folder), options: .atomic)
    }

    public static func remove(for manuscript: String, in folder: URL) {
        try? FileManager.default.removeItem(at: url(for: manuscript, in: folder))
    }
}
