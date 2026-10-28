import Foundation

/// A short passage around the first place a search word occurs, for the preview pane.
public struct Snippet: Equatable {
    /// The passage, with "…" where it was cut.
    public var text: String
    /// Where the matched word sits inside `text` (UTF-16 range, for attributed strings).
    public var highlight: NSRange

    /// Finds the first of `needles` in `source` and returns about `radius` characters either side.
    /// Matching ignores case, accents and full/half width. Whitespace runs are collapsed.
    public static func find(in source: String, needles: [String], radius: Int = 60) -> Snippet? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var best: Range<String.Index>?
        for needle in needles.flatMap(SearchText.scriptVariants) where !needle.isEmpty {
            if let range = source.range(of: needle, options: options), best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        guard let match = best else { return nil }
        let start = source.index(match.lowerBound, offsetBy: -radius, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(match.upperBound, offsetBy: radius, limitedBy: source.endIndex) ?? source.endIndex
        let before = collapse(String(source[start..<match.lowerBound]))
        let word = collapse(String(source[match]))
        let after = collapse(String(source[match.upperBound..<end]))
        let prefix = (start > source.startIndex ? "…" : "") + before
        let text = prefix + word + after + (end < source.endIndex ? "…" : "")
        return Snippet(text: text, highlight: NSRange(location: (prefix as NSString).length, length: (word as NSString).length))
    }

    /// Every place one of `needles` occurs (0.36: "全部命中"), in order, each with about
    /// `radius` characters either side; places inside the passage of the one before
    /// are not repeated. At most `limit`.
    public static func findAll(in source: String, needles: [String], radius: Int = 60, limit: Int = 50) -> [Snippet] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let variants = needles.flatMap(SearchText.scriptVariants).filter { !$0.isEmpty }
        guard !variants.isEmpty else { return [] }
        var result: [Snippet] = []
        var from = source.startIndex
        while from < source.endIndex && result.count < limit {
            var best: Range<String.Index>?
            for needle in variants {
                if let range = source.range(of: needle, options: options, range: from..<source.endIndex),
                   best == nil || range.lowerBound < best!.lowerBound {
                    best = range
                }
            }
            guard let match = best else { break }
            let start = source.index(match.lowerBound, offsetBy: -radius, limitedBy: source.startIndex) ?? source.startIndex
            let end = source.index(match.upperBound, offsetBy: radius, limitedBy: source.endIndex) ?? source.endIndex
            let before = collapse(String(source[start..<match.lowerBound]))
            let word = collapse(String(source[match]))
            let after = collapse(String(source[match.upperBound..<end]))
            let prefix = (start > source.startIndex ? "…" : "") + before
            result.append(Snippet(text: prefix + word + after + (end < source.endIndex ? "…" : ""),
                                  highlight: NSRange(location: (prefix as NSString).length, length: (word as NSString).length)))
            from = end > match.upperBound ? end : match.upperBound
        }
        return result
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
