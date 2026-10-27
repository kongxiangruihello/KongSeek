import Foundation

/// The sentence around a search hit, for "拷贝引文" (0.18).
public enum Quotation {
    /// Text as PDFs give it, tidied for quoting: line breaks inside Chinese text
    /// removed, other runs of whitespace made one space.
    public static func clean(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        var previous: Character?
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, let previous {
                // No space between two CJK characters or next to CJK punctuation.
                if !(isWide(previous) || isWide(character)) { result.append(" ") }
            }
            pendingSpace = false
            result.append(character)
            previous = character
        }
        return result
    }

    static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
                || (0x20000...0x3134F).contains(scalar.value) || "“”‘’…—".unicodeScalars.contains(scalar)
        }
    }

    static let enders: Set<Character> = ["。", "！", "？", "；", "!", "?", ";"]
    static let closers: Set<Character> = ["”", "’", "」", "』", "）", ")", "\"", "'"]

    /// The whole sentence containing the first of `needles` (also in traditional or
    /// simplified form), at most about `limit` characters, with "……" where it was cut.
    public static func sentence(in source: String, needles: [String], limit: Int = 300) -> String? {
        let text = Array(clean(source))
        let joined = String(text)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var best: Range<String.Index>?
        for needle in needles.flatMap(SearchText.scriptVariants) where !needle.isEmpty {
            if let range = joined.range(of: clean(needle), options: options), best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        guard let match = best else { return nil }
        let matchStart = joined.distance(from: joined.startIndex, to: match.lowerBound)
        let matchEnd = joined.distance(from: joined.startIndex, to: match.upperBound)

        var start = matchStart
        while start > 0 && !enders.contains(text[start - 1]) { start -= 1 }
        var end = matchEnd
        while end < text.count && !enders.contains(text[end]) { end += 1 }
        if end < text.count { end += 1 } // keep the full stop
        while end < text.count && closers.contains(text[end]) { end += 1 }
        // A closing quote of the previous sentence is not part of this one.
        while start < matchStart && (text[start] == " " || closers.contains(text[start])) { start += 1 }

        var cutBefore = false, cutAfter = false
        let half = max(20, limit / 2)
        if matchStart - start > half { start = matchStart - half; cutBefore = true }
        if end - matchEnd > half { end = matchEnd + half; cutAfter = true }
        let body = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        return (cutBefore ? "……" : "") + body + (cutAfter ? "……" : "")
    }
}
