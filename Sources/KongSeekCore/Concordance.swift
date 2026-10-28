import Foundation

/// 出处汇编 (0.27): every place a word occurs in a document's pages, with the text
/// before and after it, for a list of passages to work from.
public enum Concordance {
    public struct Occurrence: Equatable, Sendable {
        /// Index into the pages given.
        public var unit: Int
        public var before: String
        public var match: String
        public var after: String

        /// "…before【match】after…".
        public var line: String { before + "【" + match + "】" + after }
    }

    /// The words of a query: quoted phrases kept whole, the rest split at spaces.
    public static func words(_ query: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" || character == "“" || character == "”" {
                if quoted, !current.isEmpty { words.append(current) }
                current = ""
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        // Filters such as ext:pdf or in:… are not words to look for.
        return words.filter { !$0.contains(":") && !$0.hasPrefix("-") }
    }

    public static func occurrences(in pages: [String], words: [String], context: Int = 30, limit: Int = 500) -> [Occurrence] {
        var found: [Occurrence] = []
        for (unit, page) in pages.enumerated() where !page.isEmpty {
            for range in TextLocator.ranges(of: words, in: page) {
                guard let span = Range(range, in: page) else { continue }
                let start = page.index(span.lowerBound, offsetBy: -context, limitedBy: page.startIndex) ?? page.startIndex
                let end = page.index(span.upperBound, offsetBy: context, limitedBy: page.endIndex) ?? page.endIndex
                func flat(_ text: Substring) -> String {
                    String(text).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                }
                found.append(Occurrence(unit: unit, before: (start > page.startIndex ? "…" : "") + flat(page[start..<span.lowerBound]),
                                        match: flat(page[span]), after: flat(page[span.upperBound..<end]) + (end < page.endIndex ? "…" : "")))
                if found.count >= limit { return found }
            }
        }
        return found
    }
}
