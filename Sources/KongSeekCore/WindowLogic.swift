import Foundation

/// Decisions the app's windows make, kept here (0.26) so they are tested: the feature
/// guide's search, the words for a quotation check's result, the summary of
/// background work, and the name offered when a file list is saved.

/// 功能导览's search: every word of the query in the entry's text (繁简、大小写不分), or
/// the query the start of the title's pinyin, full or initials ("ywcz" → 引文查证).
public enum FeatureSearch {
    public static func matches(_ query: String, title: String, text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { SearchText.fold(String($0)) }
        guard !words.isEmpty else { return true }
        let haystack = SearchText.fold(title + " " + text)
        let pinyin = Pinyin.forms(title).map { SearchText.fold($0.replacingOccurrences(of: " ", with: "")) }
        let joined = words.joined()
        if pinyin.contains(where: { $0.hasPrefix(joined) }) { return true }
        return words.allSatisfy { word in haystack.contains(word) || pinyin.contains { $0.hasPrefix(word) } }
    }
}

/// How a quotation check's result is shown (引文查证, 稿件引文核对).
public enum QuoteVerdict {
    /// "完全一致", "近似 87%", or "未找到" for no match.
    public static func text(score: Double?) -> String {
        guard let score else { return "未找到" }
        return score >= 1 ? "完全一致" : "近似 \(Int((score * 100).rounded()))%"
    }

    /// "共 12 条引文：完全一致 8，近似 3，未找到 1" (+ "，待核对 n" while checking).
    /// `results` has one element per quotation: nil while not yet checked, `.some(nil)` when not found.
    public static func summary(_ results: [Double??]) -> String {
        var exact = 0, near = 0, missing = 0, waiting = 0
        for result in results {
            switch result {
            case .none: waiting += 1
            case .some(.none): missing += 1
            case .some(.some(let score)): if score >= 1 { exact += 1 } else { near += 1 }
            }
        }
        return "共 \(results.count) 条引文：完全一致 \(exact)，近似 \(near)，未找到 \(missing)" + (waiting > 0 ? "，待核对 \(waiting)" : "")
    }
}

/// The menu bar icon's tooltip while KongSeek works in the background.
public enum TaskSummary {
    public static func tooltip(_ tasks: [(title: String, detail: String)]) -> String {
        tasks.isEmpty ? "KongSeek" : "KongSeek 后台任务：\n" + tasks.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n")
    }
}

extension SavedFileLists {
    /// The name offered when a list is saved: the list's own name, or what was searched
    /// ("搜索“《论语》导读”的结果" → "《论语》导读"), or the folder's name.
    public static func suggestedName(heading: String) -> String {
        if heading.hasPrefix("清单：") { return String(heading.dropFirst(3)) }
        if heading.hasPrefix("搜索“"), heading.hasSuffix("”的结果") {
            return String(heading.dropFirst(3).dropLast(4))
        }
        let last = (heading as NSString).lastPathComponent
        return last.isEmpty ? heading : last
    }
}
