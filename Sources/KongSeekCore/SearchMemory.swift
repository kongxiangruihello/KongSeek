import Foundation

/// 按查询记住选择 (0.35, after ZeroLaunch-rs's per-query affinity): which file was
/// opened after typing a given query, so the same query puts it first next time —
/// "lunyu" brings up the lecture notes opened last time, not just any 论语.
public struct QueryChoices: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var path: String
        public var count: Int
        public var last: Date
    }

    public static let queryLimit = 1_000
    public static let choicesPerQuery = 5

    public private(set) var byQuery: [String: [Choice]] = [:]

    public init() {}

    /// The query as remembered: folded, spaces collapsed ("LunYu  " = "lunyu").
    public static func key(_ query: String) -> String {
        SearchText.fold(query).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public mutating func record(query: String, path: String, date: Date = Date()) {
        let key = Self.key(query)
        guard !key.isEmpty else { return }
        var choices = byQuery[key] ?? []
        if let index = choices.firstIndex(where: { $0.path == path }) {
            choices[index].count += 1
            choices[index].last = date
        } else {
            choices.append(Choice(path: path, count: 1, last: date))
        }
        choices.sort { $0.last > $1.last }
        byQuery[key] = Array(choices.prefix(Self.choicesPerQuery))
        if byQuery.count > Self.queryLimit {
            // Forget the queries not used for longest.
            let kept = byQuery.sorted { ($0.value.first?.last ?? .distantPast) > ($1.value.first?.last ?? .distantPast) }.prefix(Self.queryLimit * 4 / 5)
            byQuery = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
    }

    /// The files chosen for this query, to put first: the one opened most often,
    /// then the most recent.
    public func preferred(for query: String) -> [String] {
        (byQuery[Self.key(query)] ?? []).sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }.map(\.path)
    }

    public mutating func move(from old: String, to new: String) {
        for (key, choices) in byQuery {
            byQuery[key] = choices.map { choice in
                var choice = choice
                if choice.path == old { choice.path = new }
                return choice
            }
        }
    }

    public mutating func remove(_ path: String) {
        for (key, choices) in byQuery {
            let kept = choices.filter { $0.path != path }
            byQuery[key] = kept.isEmpty ? nil : kept
        }
    }

    public static func load(from url: URL) -> QueryChoices {
        guard let data = try? Data(contentsOf: url) else { return QueryChoices() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(QueryChoices.self, from: data)) ?? QueryChoices()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 搜不到时的建议 (0.35, after Recoll's spelling suggestions and ZeroLaunch-rs's
/// typo-tolerant matching): when a name search finds nothing, names that sound the
/// same (同音字: 论语义书 → 论语义疏) or differ in one character. Offered apart from
/// the results, never mixed in — Meilisearch's experience is that matching every
/// homophone as equal floods the results.
public enum SpellingVariants {
    /// The words with each Chinese one written in full pinyin, or nil when none is Chinese.
    public static func pinyinWords(_ words: [String]) -> [String]? {
        var changed = false
        let result = words.map { word -> String in
            guard SearchText.containsCJK(word), let spelling = Pinyin.forms(word).first, !spelling.isEmpty else { return word }
            changed = true
            return spelling
        }
        return changed ? result : nil
    }

    /// For a Chinese word of three or more characters: the word split around each
    /// character in turn, the character left out ("论语X疏" → ["论语", "疏"]), so
    /// a name with any character there matches.
    public static func gaps(_ word: String) -> [[String]] {
        let characters = Array(word)
        guard characters.count >= 3, SearchText.containsCJK(word) else { return [] }
        return characters.indices.map { index in
            [String(characters[..<index]), String(characters[(index + 1)...])].filter { !$0.isEmpty }
        }
    }

    /// Whether `name` holds `word` with at most one character different, missing or
    /// added (繁简 alike).
    public static func withinOneEdit(_ name: String, of word: String) -> Bool {
        let text = Array(SearchText.fold(name)), target = Array(SearchText.fold(word))
        guard !target.isEmpty else { return false }
        if text.count < target.count - 1 { return false }
        for length in [target.count, target.count - 1, target.count + 1] where length > 0 && length <= text.count {
            for start in 0...(text.count - length) where oneEdit(Array(text[start..<(start + length)]), target) {
                return true
            }
        }
        return false
    }

    /// Levenshtein distance ≤ 1.
    static func oneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        edits += (a.count - i) + (b.count - j)
        return edits <= 1
    }
}

/// 预置的收藏搜索 (0.35, after the bookmark sets shared for Everything): common
/// searches to add to 收藏 with one click.
public enum SavedSearchPresets {
    public struct Preset: Equatable, Sendable {
        public var name: String
        public var query: String
        public var detail: String
    }

    public static let all: [Preset] = [
        Preset(name: "最近下载的 PDF", query: "dc:7d ext:pdf", detail: "7 天内下载（创建）的 PDF"),
        Preset(name: "最近打开过的", query: "打开过:30d", detail: "30 天内从 KongSeek 打开过的文件"),
        Preset(name: "在读的书", query: "标签:在读", detail: "阅读状态为“在读”的文件"),
        Preset(name: "待读的书", query: "标签:待读", detail: "阅读状态为“待读”的文件"),
        Preset(name: "本周改过的讲义与文稿", query: "dm:thisweek ext:pptx,key,docx,pages,md", detail: "本周修改过的幻灯片和文稿"),
        Preset(name: "电子书", query: "ext:pdf,epub,mobi,azw3,djvu", detail: "PDF 与各种电子书格式"),
        Preset(name: "大文件", query: "size:>1gb", detail: "大于 1 GB 的文件"),
        Preset(name: "压缩包", query: "ext:zip,rar,7z", detail: "zip、rar、7z"),
        Preset(name: "同名文件", query: "dupe: file:", detail: "名称重复出现的文件"),
    ]
}
