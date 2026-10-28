import Foundation

/// 自动推测书上页码 (0.31): the page numbers printed in a book's running heads and feet,
/// read from the text of a sample of its pages (the PDF's text layer, or what KongSeek
/// recognized in a scan), give the difference between PDF pages and printed pages.
public enum PageNumberGuess {
    public struct Guess: Equatable, Sendable {
        /// PDF page minus printed page.
        public var offset: Int
        /// Pages whose printed number agrees with this offset.
        public var agreeing: Int
        /// Pages looked at.
        public var sampled: Int

        public func printed(forPDFPage page: Int) -> Int { page - offset }
    }

    /// Up to `count` pages spread over the body of a `total`-page book (its first and last
    /// tenth, often front matter and indexes, left out), 1-based.
    public static func samplePages(total: Int, count: Int = 24) -> [Int] {
        guard total > 0 else { return [] }
        let first = max(1, total / 10), last = max(first, total - total / 10)
        let span = last - first + 1
        guard span > count else { return Array(first...last) }
        return (0..<count).map { first + $0 * (span - 1) / max(1, count - 1) }
    }

    /// Numbers that could be the page number: on the first and last two lines, a short
    /// line's numbers, or a number at the start or end of a longer line (a running head
    /// "15 学而第一" or "论语译注 · 15"). Years and very long numbers are not page numbers.
    public static func candidates(in text: String) -> [Int] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let edges = Array(lines.prefix(2)) + (lines.count > 2 ? Array(lines.suffix(2)) : [])
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])([0-9]{1,4})(?![0-9])"#) else { return [] }
        var found: [Int] = []
        for line in edges {
            let text = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: text.length))
            let short = line.count <= 12
            for match in matches {
                let atEdge = match.range.location <= 2 || NSMaxRange(match.range) >= text.length - 2
                guard short || atEdge, let number = Int(text.substring(with: match.range(at: 1))) else { continue }
                if number < 1 || (number >= 1900 && number <= 2099) { continue }
                found.append(number)
            }
        }
        return found
    }

    /// The offset most pages agree on: at least 3 pages, and at least half of the pages
    /// where a number was found.
    public static func guess(_ pages: [(pdfPage: Int, text: String)]) -> Guess? {
        var votes: [Int: Int] = [:]
        var withNumbers = 0
        for page in pages {
            let offsets = Set(candidates(in: page.text).map { page.pdfPage - $0 }.filter { $0 >= -20 && $0 <= 500 })
            if !offsets.isEmpty { withNumbers += 1 }
            for offset in offsets { votes[offset, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : abs($0.key) > abs($1.key) }),
              best.value >= 3, Double(best.value) >= Double(withNumbers) * 0.5 else { return nil }
        return Guess(offset: best.key, agreeing: best.value, sampled: pages.count)
    }
}
