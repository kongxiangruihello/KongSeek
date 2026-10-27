import Foundation

/// Where words occur in a PDF page's text, for highlighting (0.18.1). PDF text often
/// has line breaks or spaces inside a phrase ("克己复\n礼", "非礼勿 视"), so
/// whitespace is ignored while matching; traditional and simplified forms both count.
public enum TextLocator {
    /// UTF-16 ranges in `text` (for PDFPage.selection(for:)), in order, not overlapping.
    public static func ranges(of words: [String], in text: String) -> [NSRange] {
        // The text without whitespace, and for each of its UTF-16 units the unit in `text`.
        var stripped: [UInt16] = []
        var origin: [Int] = []
        var offset = 0
        for character in text {
            let units = Array(character.utf16)
            if !character.isWhitespace {
                for (index, unit) in units.enumerated() {
                    stripped.append(unit)
                    origin.append(offset + index)
                }
            }
            offset += units.count
        }
        let haystack = String(utf16CodeUnits: stripped, count: stripped.count) as NSString
        var found: [NSRange] = []
        for word in words.flatMap(SearchText.scriptVariants) {
            let needle = word.filter { !$0.isWhitespace }
            guard !needle.isEmpty else { continue }
            var search = NSRange(location: 0, length: haystack.length)
            while search.length > 0 {
                let hit = haystack.range(of: needle, options: [.caseInsensitive, .widthInsensitive], range: search)
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                let start = origin[hit.location]
                let end = origin[hit.location + hit.length - 1] + 1
                found.append(NSRange(location: start, length: end - start))
                let next = hit.location + hit.length
                search = NSRange(location: next, length: haystack.length - next)
            }
        }
        // Sorted, overlaps (a word found in both forms) dropped.
        var result: [NSRange] = []
        for range in found.sorted(by: { $0.location < $1.location }) where result.last.map({ NSMaxRange($0) <= range.location }) ?? true {
            result.append(range)
        }
        return result
    }
}
