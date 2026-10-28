import Foundation

/// 补全书目信息 (0.28): details of a book the reader confirmed (looked up by ISBN or
/// title, or typed in), kept by KongSeek and used for references in place of what the
/// file name lacks. The files themselves are not changed.
public struct BookRecords: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var title: String?
        public var authors: String?
        public var place: String?
        public var publisher: String?
        public var year: String?
        public var isbn: String?
        /// Where it came from: "Google Books", "Open Library", "手动".
        public var source: String
        public var date: Date

        public init(title: String? = nil, authors: String? = nil, place: String? = nil, publisher: String? = nil,
                    year: String? = nil, isbn: String? = nil, source: String, date: Date = Date()) {
            self.title = title
            self.authors = authors
            self.place = place
            self.publisher = publisher
            self.year = year
            self.isbn = isbn
            self.source = source
            self.date = date
        }
    }

    public private(set) var records: [String: Record] = [:]

    public init() {}

    public func record(for path: String) -> Record? { records[path] }

    public mutating func set(_ record: Record, for path: String) { records[path] = record }

    public mutating func remove(_ path: String) { records.removeValue(forKey: path) }

    public mutating func move(from old: String, to new: String) {
        guard let record = records.removeValue(forKey: old) else { return }
        records[new] = record
    }

    /// The file name's details with the confirmed record's in their place (empty fields keep the name's).
    public func apply(to name: EbookName, path: String) -> EbookName {
        guard let record = records[path] else { return name }
        var result = name
        func given(_ value: String?) -> String? {
            value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        }
        if let title = given(record.title) { result.title = title }
        if let authors = given(record.authors) { result.authors = authors }
        if let place = given(record.place) { result.place = place }
        if let publisher = given(record.publisher) { result.publisher = publisher }
        if let year = given(record.year) { result.year = year }
        if let isbn = given(record.isbn) { result.isbn = isbn }
        return result
    }

    // MARK: Storage, shared by the app and ks

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KongSeek/book-records.json")
    }

    public static func load(from url: URL) -> BookRecords {
        guard let data = try? Data(contentsOf: url) else { return BookRecords() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BookRecords.self, from: data)) ?? BookRecords()
    }

    public func save(to url: URL = BookRecords.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        Self.cache.reset()
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BookRecords?
        private var stamp: Date?

        func current(_ url: URL) -> BookRecords {
            lock.lock()
            defer { lock.unlock() }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let value, stamp == modified { return value }
            let loaded = BookRecords.load(from: url)
            value = loaded
            stamp = modified
            return loaded
        }

        func reset() {
            lock.lock()
            value = nil
            stamp = nil
            lock.unlock()
        }
    }

    private static let cache = Cache()

    /// The records on disk, read again when the file changes (the app and ks share it).
    public static func current() -> BookRecords {
        cache.current(defaultURL)
    }
}

/// Looking a book up online (0.28): the answers of Google Books and Open Library, read
/// into candidates for the reader to confirm. Only the parsing is here; the app fetches.
public enum BookLookup {
    public struct Candidate: Equatable, Sendable, Identifiable {
        public var id: String { [source, title, authors ?? "", publisher ?? "", year ?? "", isbn ?? ""].joined(separator: "|") }
        public var title: String
        public var authors: String?
        public var place: String?
        public var publisher: String?
        public var year: String?
        public var isbn: String?
        public var source: String

        public init(title: String, authors: String? = nil, place: String? = nil, publisher: String? = nil, year: String? = nil, isbn: String? = nil, source: String) {
            self.title = title
            self.authors = authors
            self.place = place
            self.publisher = publisher
            self.year = year
            self.isbn = isbn
            self.source = source
        }

        /// "杨伯峻 · 中华书局 · 1980"
        public var summary: String {
            [authors, [place, publisher].compactMap { $0 }.joined(separator: "："), year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// The first four-digit year in "2006-01-01", "1980年", "c1980".
    public static func year(_ text: String?) -> String? {
        guard let text, let range = text.range(of: #"(1[5-9]|20)\d\d"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: Google Books

    public static func googleQuery(isbn: String?, title: String, authors: String?) -> URL? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        let q: String
        if let isbn, !isbn.isEmpty { q = "isbn:" + isbn } else { q = "intitle:" + title + (authors.map { " inauthor:" + $0 } ?? "") }
        components?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: "8")]
        return components?.url
    }

    public static func googleBooks(_ data: Data) -> [Candidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let info = item["volumeInfo"] as? [String: Any], let title = info["title"] as? String else { return nil }
            let subtitle = (info["subtitle"] as? String).map { "：" + $0 } ?? ""
            let identifiers = info["industryIdentifiers"] as? [[String: Any]] ?? []
            let isbn = identifiers.first { $0["type"] as? String == "ISBN_13" }?["identifier"] as? String
                ?? identifiers.first { $0["type"] as? String == "ISBN_10" }?["identifier"] as? String
            return Candidate(title: title + subtitle, authors: (info["authors"] as? [String]).map { $0.joined(separator: "、") },
                             publisher: info["publisher"] as? String, year: year(info["publishedDate"] as? String), isbn: isbn, source: "Google Books")
        }
    }

    // MARK: Open Library

    public static func openLibraryQuery(isbn: String?, title: String, authors: String?) -> URL? {
        if let isbn, !isbn.isEmpty { return URL(string: "https://openlibrary.org/isbn/\(isbn).json") }
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        var items = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "limit", value: "8"),
                     URLQueryItem(name: "fields", value: "title,subtitle,author_name,publisher,publish_year,publish_place,isbn")]
        if let authors { items.append(URLQueryItem(name: "author", value: authors)) }
        components?.queryItems = items
        return components?.url
    }

    /// An edition (`/isbn/….json`) or search results (`/search.json`).
    public static func openLibrary(_ data: Data) -> [Candidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let docs = json["docs"] as? [[String: Any]] {
            return docs.compactMap { doc in
                guard let title = doc["title"] as? String else { return nil }
                let subtitle = (doc["subtitle"] as? String).map { "：" + $0 } ?? ""
                let years = (doc["publish_year"] as? [Int] ?? []).sorted()
                return Candidate(title: title + subtitle, authors: (doc["author_name"] as? [String]).map { $0.prefix(4).joined(separator: "、") },
                                 place: (doc["publish_place"] as? [String])?.first, publisher: (doc["publisher"] as? [String])?.first,
                                 year: years.first.map(String.init), isbn: (doc["isbn"] as? [String])?.first { $0.count == 13 }, source: "Open Library")
            }
        }
        guard let title = json["title"] as? String else { return [] }
        let subtitle = (json["subtitle"] as? String).map { "：" + $0 } ?? ""
        let by = (json["by_statement"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: " ./"))
        return [Candidate(title: title + subtitle, authors: by, place: (json["publish_places"] as? [String])?.first,
                          publisher: (json["publishers"] as? [String])?.first, year: year(json["publish_date"] as? String),
                          isbn: (json["isbn_13"] as? [String])?.first, source: "Open Library")]
    }
}
