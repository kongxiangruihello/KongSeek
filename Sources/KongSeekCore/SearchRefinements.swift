import Foundation

/// 邻近搜索 (0.36, after Recoll's proximity searches with slack): whether the words of a
/// full-text search stand close together — within a number of characters, or on one
/// page — rather than anywhere in a book.
public enum Proximity {
    /// The pages (or the one text) where every word occurs, each word by any of its
    /// forms, within `distance` characters of the others (nil: anywhere on the page).
    /// Returns the 0-based index of the first such page.
    public static func firstPage(_ pages: [String], words: [[String]], distance: Int?) -> Int? {
        let forms = words.map { $0.map(SearchText.fold).filter { !$0.isEmpty } }.filter { !$0.isEmpty }
        guard !forms.isEmpty else { return nil }
        for (index, page) in pages.enumerated() where matches(page, forms: forms, distance: distance) {
            return index
        }
        return nil
    }

    /// Words given as their folded forms.
    static func matches(_ page: String, forms: [[String]], distance: Int?) -> Bool {
        let text = Array(SearchText.fold(page))
        // Each occurrence: where it starts and ends, and which word it is.
        var occurrences: [(start: Int, end: Int, word: Int)] = []
        for (word, variants) in forms.enumerated() {
            var found = false
            for variant in variants {
                let needle = Array(variant)
                guard needle.count <= text.count else { continue }
                var position = 0
                while position + needle.count <= text.count {
                    if text[position] == needle[0], Array(text[position..<(position + needle.count)]) == needle {
                        occurrences.append((position, position + needle.count, word))
                        found = true
                    }
                    position += 1
                }
            }
            if !found { return false }
        }
        guard let distance else { return true }
        // The shortest stretch holding every word; the characters between them must be at most `distance`.
        occurrences.sort { $0.start < $1.start }
        var counts = [Int](repeating: 0, count: forms.count)
        var covered = 0
        var left = 0
        for right in occurrences.indices {
            if counts[occurrences[right].word] == 0 { covered += 1 }
            counts[occurrences[right].word] += 1
            while covered == forms.count {
                let window = occurrences[left...right]
                let end = window.map { $0.end }.max() ?? 0
                // Letters in the window that belong to none of the words.
                var shortest: [Int: Int] = [:]
                for item in window { shortest[item.word] = min(shortest[item.word] ?? Int.max, item.end - item.start) }
                let wordLetters = shortest.values.reduce(0, +)
                if end - occurrences[left].start - wordLetters <= distance { return true }
                counts[occurrences[left].word] -= 1
                if counts[occurrences[left].word] == 0 { covered -= 1 }
                left += 1
            }
        }
        return false
    }
}

/// 筛选按钮 (0.36, after Recoll's Query Fragments): buttons under the search field that
/// add a piece of syntax to the search, or take it out again. "PDF=ext:pdf" lines.
public struct FilterFragments: Equatable, Sendable {
    public struct Fragment: Equatable, Sendable {
        public var title: String
        public var text: String
    }

    public private(set) var fragments: [Fragment] = []

    public static let standardLines = [
        "PDF=ext:pdf",
        "Word=ext:docx,doc,pages",
        "幻灯片=ext:pptx,ppt,key",
        "电子书=ext:pdf,epub,mobi,azw3,djvu",
        "图片=ext:jpg,jpeg,png,heic,gif,tiff",
        "文件夹=folder:",
        "本周=dm:thisweek",
        "打开过=打开过:",
    ]

    public static var standard: FilterFragments { FilterFragments(lines: standardLines) }

    public init(lines: [String]) {
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == "＝" }) else { continue }
            let title = line[..<separator].trimmingCharacters(in: .whitespaces)
            let text = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !text.isEmpty, title.count <= 12 else { continue }
            fragments.append(Fragment(title: title, text: text))
        }
    }

    public var lines: [String] { fragments.map { $0.title + "=" + $0.text } }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Whether the search holds every token of the fragment.
    public static func isActive(_ fragment: Fragment, in query: String) -> Bool {
        let present = Set(tokens(query).map { $0.lowercased() })
        let wanted = tokens(fragment.text).map { $0.lowercased() }
        return !wanted.isEmpty && wanted.allSatisfy(present.contains)
    }

    /// The search with the fragment added at the end, or taken out when it is there.
    public static func toggled(_ fragment: Fragment, in query: String) -> String {
        let wanted = Set(tokens(fragment.text).map { $0.lowercased() })
        let parts = tokens(query)
        if isActive(fragment, in: query) {
            return parts.filter { !wanted.contains($0.lowercased()) }.joined(separator: " ")
        }
        return (parts + tokens(fragment.text).filter { token in !parts.contains { $0.lowercased() == token.lowercased() } }).joined(separator: " ")
    }
}

/// 合并重复副本 (0.36, after Recoll, which hides results with the same MD5): results
/// whose content is the same, grouped so only the best placed shows, with the others
/// as its copies. Same size first, then the given content hash.
public enum CopyGroups {
    /// For each path that leads a group (the first of the group in `files`' order),
    /// the others; files with no copy are left out.
    public static func group(_ files: [(path: String, size: Int64)], hash: (String, Int64) -> String?) -> [String: [String]] {
        var bySize: [Int64: [String]] = [:]
        var order: [String: Int] = [:]
        for (position, file) in files.enumerated() where file.size > 0 {
            bySize[file.size, default: []].append(file.path)
            order[file.path] = position
        }
        var result: [String: [String]] = [:]
        for (size, paths) in bySize where paths.count > 1 {
            var byHash: [String: [String]] = [:]
            for path in paths {
                if let key = hash(path, size) { byHash[key, default: []].append(path) }
            }
            for group in byHash.values where group.count > 1 {
                let sorted = group.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                result[sorted[0]] = Array(sorted.dropFirst())
            }
        }
        return result
    }

    /// Head, tail and size; the whole file too when it is small enough to read quickly.
    public static func contentHash(_ path: String, size: Int64) -> String? {
        guard let quick = DuplicateFinder.quickHash(path, size: size) else { return nil }
        if size <= 131_072 || size > 20_000_000 { return quick }
        return DuplicateFinder.fullHash(path)
    }
}

/// 按书目信息搜索 (0.38): 作者:、出版社:、年: — a book's details as its file name
/// gives them (a site's long name), as its EPUB package says, or as confirmed in
/// 补全书目信息. Where a book has no such detail, its file name is looked in instead
/// ("论语译注 杨伯峻 中华书局 1980.pdf"). Authors may be named by another name in
/// 同义词与别名 (朱子 for 朱熹).
public struct BookFilter: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public var text: String
        public var excluded: Bool
    }

    public var authors: [Term] = []
    public var publishers: [Term] = []
    public var yearFrom: Int?
    public var yearTo: Int?

    public init() {}

    public var isActive: Bool { !authors.isEmpty || !publishers.isEmpty || yearFrom != nil || yearTo != nil }

    /// "1980", "1980..1995", ">=2000", "<1949", "1980-1990" as inclusive bounds.
    public static func yearRange(_ text: String) -> (from: Int?, to: Int?)? {
        let value = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "年", with: "")
        func year(_ part: String) -> Int? {
            guard part.count == 4, let number = Int(part), (1000...2999).contains(number) else { return nil }
            return number
        }
        for separator in ["..", "–", "—", "-", "~", "至"] {
            if let range = value.range(of: separator), range.lowerBound != value.startIndex {
                guard let low = year(String(value[..<range.lowerBound])), let high = year(String(value[range.upperBound...])), low <= high else { return nil }
                return (low, high)
            }
        }
        for (op, kind) in [(">=", 0), ("<=", 1), (">", 2), ("<", 3)] where value.hasPrefix(op) {
            guard let number = year(String(value.dropFirst(op.count))) else { return nil }
            switch kind {
            case 0: return (number, nil)
            case 1: return (nil, number)
            case 2: return (number + 1, nil)
            default: return (nil, number - 1)
            }
        }
        guard let number = year(value) else { return nil }
        return (number, number)
    }

    /// The first year (1000–2999) written in a file name.
    static func year(inName name: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])(1[0-9]{3}|2[0-9]{3})(?![0-9])"),
              let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) else { return nil }
        return Int((name as NSString).substring(with: match.range(at: 1)))
    }

    /// Whether a book passes: `details` from its name, package or confirmed record (nil
    /// when nothing is known), `fileName` to fall back on.
    public func accepts(details: EbookName?, fileName: String, aliases: SearchAliases = .none) -> Bool {
        let foldedName = SearchText.fold(fileName)
        func matches(_ term: Term, in field: String?) -> Bool {
            let forms = ([term.text] + aliases.alternatives(for: term.text)).map(SearchText.fold)
            let haystack = field.map(SearchText.fold) ?? foldedName
            let found = forms.contains { !$0.isEmpty && haystack.contains($0) }
            return found != term.excluded
        }
        for term in authors where !matches(term, in: details?.authors) { return false }
        for term in publishers where !matches(term, in: details?.publisher) { return false }
        if yearFrom != nil || yearTo != nil {
            guard let year = details?.year.flatMap({ Int($0.prefix(4)) }) ?? Self.year(inName: fileName) else { return false }
            if let yearFrom, year < yearFrom { return false }
            if let yearTo, year > yearTo { return false }
        }
        return true
    }
}

/// 相关文件 (0.39): for one file, the other editions of the same book (by the title in
/// the name, as 查找重复 groups them) and other versions of the same document ("v2",
/// "副本", "终稿", dates), newest first.
public enum RelatedFiles {
    public struct Groups: Equatable, Sendable {
        public var editions: [String] = []
        public var versions: [String] = []
    }

    /// The extensions that count as the same kind of document as `path`.
    public static func familyExtensions(of path: String) -> Set<String> {
        let ext = (path as NSString).pathExtension.lowercased()
        switch DuplicateFinder.family(path) {
        case "slides": return ["ppt", "pptx", "key"]
        case "text": return ["doc", "docx", "pages", "rtf", "odt"]
        case "sheet": return ["xls", "xlsx", "numbers", "csv"]
        case "image": return ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
        default: return [ext]
        }
    }

    public static func find(for path: String, among files: [FileEntry]) -> Groups {
        let name = (path as NSString).lastPathComponent
        var groups = Groups()
        let others = files.filter { $0.path != path }.sorted { $0.modified > $1.modified }
        if DuplicateFinder.bookExtensions.contains((path as NSString).pathExtension.lowercased()), let key = DuplicateFinder.bookKey(name) {
            groups.editions = others.filter {
                DuplicateFinder.bookExtensions.contains(($0.path as NSString).pathExtension.lowercased()) && DuplicateFinder.bookKey($0.name) == key
            }.map(\.path)
        }
        let versionKey = DuplicateFinder.versionKey(name)
        let family = DuplicateFinder.family(path)
        let editions = Set(groups.editions)
        groups.versions = others.filter {
            !editions.contains($0.path) && DuplicateFinder.family($0.path) == family && DuplicateFinder.versionKey($0.name) == versionKey
        }.map(\.path)
        return groups
    }
}

/// 按命中次数排序 (0.41): how often the words of a full-text search occur in a document,
/// each by its 繁简 forms, so the books that dwell on a concept come before those that
/// mention it once.
public enum HitCount {
    public static func count(_ words: [String], in pages: [String], limit: Int = 10_000) -> Int {
        let needles = words.flatMap { word -> [String] in
            var forms: [String] = []
            for variant in SearchText.scriptVariants(word).map(SearchText.fold) where !variant.isEmpty && !forms.contains(variant) {
                forms.append(variant)
            }
            return forms
        }
        guard !needles.isEmpty else { return 0 }
        var total = 0
        for page in pages {
            let text = SearchText.fold(page)
            for needle in needles {
                var searchRange = text.startIndex..<text.endIndex
                while let found = text.range(of: needle, range: searchRange) {
                    total += 1
                    if total >= limit { return total }
                    searchRange = found.upperBound..<text.endIndex
                }
            }
        }
        return total
    }
}

/// 条件标签 (0.42): the conditions of a search — operators (作者:、in:、dm: …), ext:,
/// exclusions, tags — each shown as a label to take out with one click.
public enum QueryChips {
    public struct Chip: Equatable, Sendable {
        /// "作者：杨伯峻", "排除：草稿".
        public var title: String
        /// The token as written in the search, to take out.
        public var token: String

        public init(title: String, token: String) {
            self.title = title
            self.token = token
        }
    }

    /// The search split at spaces, quoted parts kept whole, each token as written.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var closing: Character?
        for character in text {
            if let close = closing {
                current.append(character)
                if character == close { closing = nil }
                continue
            }
            if character == "\"" { closing = "\"" } else if character == "“" { closing = "”" }
            if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    public static func chips(for text: String) -> [Chip] {
        let names = AdvancedFilters.operatorNames + ["ext", "标签", "tag"]
        var chips: [Chip] = []
        for token in tokens(text) {
            let excluded = token.hasPrefix("-") && token.count > 1
            let body = excluded ? String(token.dropFirst()) : token
            let lowered = body.lowercased()
            if let name = names.first(where: { lowered.hasPrefix($0 + ":") || lowered.hasPrefix($0 + "：") }) {
                let value = String(body.dropFirst(name.count + 1)).replacingOccurrences(of: "\"", with: "")
                let label = label(for: name)
                chips.append(Chip(title: (excluded ? "非 " : "") + label + (value.isEmpty ? "" : "：" + value), token: token))
            } else if body.hasPrefix("#") && body.count > 1 {
                chips.append(Chip(title: "标签：" + body.dropFirst(), token: token))
            } else if excluded {
                chips.append(Chip(title: "排除：" + body.replacingOccurrences(of: "\"", with: ""), token: token))
            }
        }
        return chips
    }

    static func label(for name: String) -> String {
        switch name {
        case "path": return "路径含"
        case "in", "infolder": return "在"
        case "parent": return "直接在"
        case "size": return "大小"
        case "dm", "datemodified": return "修改"
        case "dc", "datecreated": return "创建"
        case "regex": return "正则"
        case "dupe": return "同名文件"
        case "file": return "只要文件"
        case "folder": return "只要文件夹"
        case "opened", "打开过": return "打开过"
        case "near", "相距": return "相距"
        case "samepage", "同页": return "同一页"
        case "author", "作者": return "作者"
        case "publisher", "出版社": return "出版社"
        case "year", "年", "年份": return "出版年"
        case "note", "备注": return "备注"
        case "ext": return "扩展名"
        case "标签", "tag": return "标签"
        default: return name
        }
    }

    /// The search without the chip's token (the first one as written).
    public static func removing(_ chip: Chip, from text: String) -> String {
        var parts = tokens(text)
        if let index = parts.firstIndex(of: chip.token) { parts.remove(at: index) }
        return parts.joined(separator: " ")
    }
}

/// 性能自检 (0.42): how long the last searches took, for 状态与诊断.
public struct TimingLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public var label: String
        public var milliseconds: Double
        public var detail: String
    }

    public private(set) var entries: [Entry] = []
    public let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    public mutating func add(_ label: String, milliseconds: Double, detail: String = "") {
        entries.append(Entry(label: label, milliseconds: milliseconds, detail: detail))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// "最近 12 次：平均 18 ms，最慢 95 ms（论语 作者:杨伯峻）", for one label.
    public func summary(_ label: String) -> String? {
        let matching = entries.filter { $0.label == label }
        guard let slowest = matching.max(by: { $0.milliseconds < $1.milliseconds }) else { return nil }
        let average = matching.reduce(0) { $0 + $1.milliseconds } / Double(matching.count)
        return "最近 \(matching.count) 次：平均 \(Int(average.rounded())) ms，最慢 \(Int(slowest.milliseconds.rounded())) ms"
            + (slowest.detail.isEmpty ? "" : "（\(slowest.detail)）")
    }

    /// The slowest of a label, for a warning when searches feel slow.
    public func slowest(_ label: String) -> Double {
        entries.filter { $0.label == label }.map(\.milliseconds).max() ?? 0
    }
}
