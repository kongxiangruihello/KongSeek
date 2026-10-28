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
