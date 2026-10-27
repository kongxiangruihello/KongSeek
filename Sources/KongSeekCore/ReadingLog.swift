import Foundation

/// Where each PDF was last read in KongSeek's reader (0.24): the page, how many pages
/// the book has, and when, newest first. Shown as "读到第 N 页 / 共 M 页" in 文件清单
/// and as 最近阅读 in the menu.
public struct ReadingLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        /// 1-based page.
        public var page: Int
        /// Pages in the document; 0 when not known (entries kept from before 0.24).
        public var pages: Int
        public var date: Date

        public init(path: String, page: Int, pages: Int, date: Date) {
            self.path = path
            self.page = page
            self.pages = pages
            self.date = date
        }

        /// "读到第 12 页 / 共 300 页"; "已读完" on the last page.
        public var progressText: String {
            guard pages > 0 else { return "读到第 \(page) 页" }
            if page >= pages && pages > 1 { return "已读完（共 \(pages) 页）" }
            return "读到第 \(page) 页 / 共 \(pages) 页"
        }

        /// 0…1, for sorting; 0 when the page count is not known.
        public var fraction: Double {
            pages > 0 ? min(1, Double(page) / Double(pages)) : 0
        }
    }

    public static let limit = 500

    /// Newest first.
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.date > $1.date }
        if self.entries.count > Self.limit { self.entries.removeLast(self.entries.count - Self.limit) }
    }

    /// Entries from the page-only record kept before 0.24 (path → page), dated long ago.
    public init(legacyPages: [String: Int]) {
        self.init(entries: legacyPages.sorted { $0.key < $1.key }.map { Entry(path: $0.key, page: $0.value, pages: 0, date: .distantPast) })
    }

    public func entry(for path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Records the page now being read; the entry moves to the front.
    public mutating func record(path: String, page: Int, pages: Int, date: Date = Date()) {
        guard page >= 1 else { return }
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, page: page, pages: pages, date: date), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(_ path: String) {
        entries.removeAll { $0.path == path }
    }

    /// The most recently read, skipping old undated entries and files `exists` rejects.
    public func recent(_ count: Int, exists: (String) -> Bool = { _ in true }) -> [Entry] {
        var found: [Entry] = []
        for entry in entries where found.count < count && entry.date > .distantPast && exists(entry.path) {
            found.append(entry)
        }
        return found
    }
}
