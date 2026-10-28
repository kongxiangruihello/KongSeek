import Foundation

/// KongFolio, the PDF reading and annotation app (0.25): KongSeek opens PDFs there at
/// a page with the words marked, and shows the reading progress KongFolio keeps.
public enum KongFolioLink {
    public static let bundleIdentifier = "com.kongfolio.mac"

    /// A rectangle in PDF page coordinates (points, origin at the bottom left).
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// KongFolio's `SourceRef`, as its `kongfolio://source` links carry it. `path`,
    /// `fileName`, `page` and `rects` are required by KongFolio; `keep` (KongFolio 0.34)
    /// keeps the marks instead of letting them fade, and older KongFolio ignores it.
    struct Reference: Encodable {
        var path: String
        var fileName: String
        /// 0-based.
        var page: Int
        var rects: [[[Double]]]
        var anchor: String?
        var keep: Bool?
    }

    /// `kongfolio://source?ref=<base64 JSON>` opening `path` at `page` (1-based) with
    /// `rects` marked; `anchor` (text on the page) is used by KongFolio when no rects are given.
    public static func url(path: String, page: Int, rects: [Rect] = [], anchor: String? = nil, keep: Bool = true) -> URL? {
        guard path.hasPrefix("/"), page >= 1 else { return nil }
        // CGRect's Codable form, which KongFolio decodes: [[x, y], [width, height]].
        let boxes = rects.filter { $0.width > 0 && $0.height > 0 && $0.x.isFinite && $0.y.isFinite }
            .map { [[$0.x, $0.y], [$0.width, $0.height]] }
        let reference = Reference(path: path, fileName: (path as NSString).lastPathComponent, page: page - 1, rects: boxes,
                                  anchor: boxes.isEmpty ? anchor.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } : nil,
                                  keep: keep ? true : nil)
        guard let data = try? JSONEncoder().encode(reference) else { return nil }
        var components = URLComponents()
        components.scheme = "kongfolio"
        components.host = "source"
        components.queryItems = [URLQueryItem(name: "ref", value: data.base64EncodedString())]
        return components.url
    }

    /// The first KongFolio that keeps KongSeek's marks, reopens books where they were
    /// read, and records reading time and page counts.
    public static let linkedVersion = "0.34"

    /// Whether `version` (e.g. "0.33.0", "0.34.1") is `linkedVersion` or later.
    public static func isLinked(version: String) -> Bool {
        version.compare(linkedVersion, options: .numeric) != .orderedAscending
    }

    // MARK: Reading progress

    /// KongFolio keeps each file's progress in its preferences under this key.
    public static let progressPrefix = "KongFolio.progress."

    /// One file's progress as KongFolio stored it: {"visited": "0-3,7", "last": 7,
    /// "date": seconds since 1970, "pages": 300} — date and pages since KongFolio 0.34.
    public static func entry(path: String, stored: [String: Any]) -> ReadingLog.Entry? {
        guard let last = stored["last"] as? Int, last >= 0 else { return nil }
        let date = (stored["date"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        let visited = visitedCount(stored["visited"] as? String ?? "")
        // Before 0.34 nothing was stored for an unread file; a record with no page read is no progress.
        guard visited > 0 else { return nil }
        return ReadingLog.Entry(path: path, page: last + 1, pages: stored["pages"] as? Int ?? 0, date: date)
    }

    /// How many pages "0-3,7,9-10" names.
    public static func visitedCount(_ text: String) -> Int {
        var count = 0
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { count += 1 } else if bounds.count == 2, bounds[0] <= bounds[1] { count += bounds[1] - bounds[0] + 1 }
        }
        return count
    }

    /// Every file's progress from KongFolio's preferences (as `UserDefaults.dictionaryRepresentation`).
    public static func entries(from preferences: [String: Any]) -> [ReadingLog.Entry] {
        preferences.compactMap { key, value -> ReadingLog.Entry? in
            guard key.hasPrefix(progressPrefix), let stored = value as? [String: Any] else { return nil }
            return entry(path: String(key.dropFirst(progressPrefix.count)), stored: stored)
        }
    }
}

extension ReadingLog {
    /// This log with KongFolio's records merged in: for each file the more recent record
    /// wins; undated KongFolio records only fill in files this log does not know.
    public func merged(with others: [Entry]) -> ReadingLog {
        var byPath: [String: Entry] = [:]
        for entry in entries { byPath[entry.path] = entry }
        for other in others {
            if let mine = byPath[other.path] {
                if other.date > mine.date { byPath[other.path] = other }
            } else {
                byPath[other.path] = other
            }
        }
        return ReadingLog(entries: Array(byPath.values))
    }
}
