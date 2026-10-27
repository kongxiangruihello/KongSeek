import Foundation

/// Compares two versions of a lecture deck or document unit by unit (slides, pages
/// or paragraphs), for "两版讲义对比" (0.20). Units are paired in order by how much
/// text they share, so inserted, removed and moved-on slides are told apart from
/// edited ones.
public enum VersionDiff {
    public enum Kind: String, Equatable, Sendable {
        case same, changed, added, removed
    }

    public struct Change: Equatable, Sendable {
        public var kind: Kind
        /// 1-based positions in the old and new version.
        public var old: Int?
        public var new: Int?
        /// For `changed`: how much of the text the two share (0…1).
        public var similarity: Double
        /// Lines only in the new / only in the old unit (for `changed`), or the
        /// unit's lines (for `added` / `removed`).
        public var addedLines: [String]
        public var removedLines: [String]
    }

    public struct Summary: Equatable, Sendable {
        public var same = 0, changed = 0, added = 0, removed = 0
    }

    /// Units that share at least this much count as the same unit, edited.
    public static let pairing = 0.45

    public static func compare(old: [String], new: [String]) -> [Change] {
        let a = old.map(signature), b = new.map(signature)
        let n = a.count, m = b.count
        // Similarity of every pair, then the best order-keeping pairing (weighted LCS).
        let pairsA = a.map(bigrams), pairsB = b.map(bigrams)
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n { for j in 0..<m { similarity[i][j] = a[i] == b[j] ? 1 : score(pairsA[i], pairsB[j]) } }
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    var value = max(best[i + 1][j], best[i][j + 1])
                    if similarity[i][j] >= pairing { value = max(value, best[i + 1][j + 1] + similarity[i][j]) }
                    best[i][j] = value
                }
            }
        }
        var changes: [Change] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, similarity[i][j] >= pairing, best[i][j] == best[i + 1][j + 1] + similarity[i][j] {
                let oldLines = lines(old[i]), newLines = lines(new[j])
                let identical = a[i] == b[j]
                let oldSet = Set(oldLines.map(normalized)), newSet = Set(newLines.map(normalized))
                changes.append(Change(kind: identical ? .same : .changed, old: i + 1, new: j + 1, similarity: identical ? 1 : similarity[i][j],
                                      addedLines: identical ? [] : newLines.filter { !oldSet.contains(normalized($0)) },
                                      removedLines: identical ? [] : oldLines.filter { !newSet.contains(normalized($0)) }))
                i += 1
                j += 1
            } else if i < n && (j >= m || best[i + 1][j] >= best[i][j + 1]) {
                changes.append(Change(kind: .removed, old: i + 1, new: nil, similarity: 0, addedLines: [], removedLines: lines(old[i])))
                i += 1
            } else {
                changes.append(Change(kind: .added, old: nil, new: j + 1, similarity: 0, addedLines: lines(new[j]), removedLines: []))
                j += 1
            }
        }
        // An edit whose lines did not change after normalizing (spacing, width) counts as unchanged.
        return changes.map { change in
            var change = change
            if change.kind == .changed && change.addedLines.isEmpty && change.removedLines.isEmpty { change.kind = .same; change.similarity = 1 }
            return change
        }
    }

    public static func summary(_ changes: [Change]) -> Summary {
        var summary = Summary()
        for change in changes {
            switch change.kind {
            case .same: summary.same += 1
            case .changed: summary.changed += 1
            case .added: summary.added += 1
            case .removed: summary.removed += 1
            }
        }
        return summary
    }

    // MARK: Pieces

    /// Text compared without spacing, case or width differences, in simplified characters.
    static func normalized(_ text: String) -> String {
        SearchText.fold(text).filter { !$0.isWhitespace }
    }

    static func signature(_ text: String) -> String { normalized(text) }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Dice coefficient of two texts' character pairs.
    static func score(_ a: String, _ b: String) -> Double {
        a == b ? 1 : score(bigrams(a), bigrams(b))
    }

    static func score(_ x: [String: Int], _ y: [String: Int]) -> Double {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var common = 0
        var counts = x
        for (pair, count) in y {
            let shared = min(count, counts[pair] ?? 0)
            common += shared
            counts[pair] = (counts[pair] ?? 0) - shared
        }
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        return Double(2 * common) / Double(total)
    }

    static func bigrams(_ text: String) -> [String: Int] {
        let characters = Array(text)
        guard characters.count > 1 else { return characters.isEmpty ? [:] : [String(characters): 1] }
        var result: [String: Int] = [:]
        for index in 0..<(characters.count - 1) { result[String(characters[index...index + 1]), default: 0] += 1 }
        return result
    }
}

/// Moving newly downloaded ebooks with site-style names into the ebook folder under
/// short names (0.20).
public enum DownloadTidy {
    public struct Plan: Equatable, Sendable {
        public var source: String
        public var newName: String
        public var destination: String
        /// Reading marks moved out of the name ("_已读"), kept as Finder tags.
        public var tags: [String]
    }

    /// Plans for the files whose names an ebook site wrote (others are left out),
    /// with names made unique within `folder` and among themselves.
    public static func plan(_ paths: [String], into folder: String, style: EbookName.Style = .full, exists: (String) -> Bool) -> [Plan] {
        var taken = Set<String>()
        var plans: [Plan] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension
            let split = EbookName.splitMark(url.deletingPathExtension().lastPathComponent)
            guard var name = EbookName.parse(split.stem) else { continue }
            name.mark = ""
            let stem = name.formatted(style)
            var candidate = stem + (ext.isEmpty ? "" : "." + ext)
            var number = 2
            while exists((folder as NSString).appendingPathComponent(candidate)) || taken.contains(candidate.lowercased()) {
                candidate = "\(stem) (\(number))" + (ext.isEmpty ? "" : "." + ext)
                number += 1
            }
            taken.insert(candidate.lowercased())
            plans.append(Plan(source: path, newName: candidate, destination: (folder as NSString).appendingPathComponent(candidate),
                              tags: EbookName.tag(forMark: split.mark).map { [$0] } ?? []))
        }
        return plans
    }
}
