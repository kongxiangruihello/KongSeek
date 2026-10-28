import Foundation

/// 引文查证 (0.21): where a quotation occurs in a text, allowing for differences
/// in punctuation, spacing, line breaks, traditional and simplified or variant
/// characters, and small wording slips.
public enum QuoteMatcher {
    /// Characters compared: folded (case, width, 繁简, 异体), letters and digits only.
    public static func normalized(_ text: String) -> [Character] {
        Array(SearchText.fold(text)).filter { $0.isLetter || $0.isNumber }
    }

    /// Up to three pieces of the quotation (start, middle, end), `length` characters
    /// each, to find candidate documents with a content search.
    public static func probes(_ quote: String, length: Int = 5) -> [String] {
        let chars = normalized(quote)
        guard chars.count > length else { return chars.isEmpty ? [] : [String(chars)] }
        var starts = [0, (chars.count - length) / 2, chars.count - length]
        starts = starts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return starts.map { String(chars[$0..<($0 + length)]) }
    }

    public struct Match: Equatable, Sendable {
        /// Index of the page (or unit) in the list given.
        public var unit: Int
        /// 1 for an exact match (after normalizing), otherwise the share of the
        /// quotation's character pairs found in order nearby.
        public var score: Double
        /// The passage in the page that matched, as it is written there.
        public var excerpt: String
        public var exact: Bool { score >= 1 }
    }

    /// The page that best contains the quotation, if any reaches `minimumScore`.
    public static func best(in pages: [String], quote: String, minimumScore: Double = 0.6) -> Match? {
        let target = normalized(quote)
        guard target.count >= 2 else { return nil }
        let pairs = bigrams(target)
        var best: Match?
        for (index, page) in pages.enumerated() {
            let text = normalized(page)
            guard text.count >= 2 else { continue }
            let score: Double
            if contains(text, target) {
                score = 1
            } else {
                let available = Set(bigrams(text))
                score = Double(pairs.filter { available.contains($0) }.count) / Double(max(1, pairs.count))
            }
            if score >= minimumScore, score > (best?.score ?? 0) {
                best = Match(unit: index, score: score, excerpt: excerpt(in: page, quote: quote))
                if score >= 1 { break }
            }
        }
        return best
    }

    /// The sentence(s) of `page` around the best-matching piece of the quotation.
    static func excerpt(in page: String, quote: String) -> String {
        for probe in probes(quote, length: 4) + probes(quote, length: 2) {
            if let sentence = Quotation.sentence(in: page, needles: [probe], limit: max(120, quote.count * 2)) { return sentence }
        }
        return String(Quotation.clean(page).prefix(120))
    }

    static func contains(_ text: [Character], _ target: [Character]) -> Bool {
        guard target.count <= text.count else { return false }
        let first = target[0]
        var index = 0
        while index <= text.count - target.count {
            if text[index] == first && Array(text[index..<(index + target.count)]) == target { return true }
            index += 1
        }
        return false
    }

    static func bigrams(_ chars: [Character]) -> [String] {
        guard chars.count > 1 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
    }
}

/// Every page of a document where the search words occur (书内全部命中, 0.21).
public enum PageHits {
    public struct Hit: Equatable, Sendable {
        /// 1-based page (or slide).
        public var page: Int
        public var count: Int
        public var snippet: String
    }

    public static func find(in pages: [String], firstPage: Int = 1, words: [String]) -> [Hit] {
        var hits: [Hit] = []
        for (offset, text) in pages.enumerated() {
            let ranges = TextLocator.ranges(of: words, in: text)
            guard let first = ranges.first else { continue }
            let ns = text as NSString
            let start = max(0, first.location - 40), end = min(ns.length, NSMaxRange(first) + 60)
            var snippet = Quotation.clean(ns.substring(with: NSRange(location: start, length: end - start)))
            if start > 0 { snippet = "…" + snippet }
            if end < ns.length { snippet += "…" }
            hits.append(Hit(page: firstPage + offset, count: ranges.count, snippet: snippet))
        }
        return hits
    }
}

/// The quotations in a manuscript (稿件引文核对, 0.23): text inside “…”, 「…」, 『…』,
/// ﹁…﹂, ‘…’ (‘…’ inside “…” stays part of it), long enough to be a quotation rather
/// than a term or a title, in order, without repeats.
public enum ManuscriptQuotes {
    public struct Quote: Equatable, Sendable {
        public var text: String
        /// About 20 characters before the quotation, to recognize where it is in the manuscript.
        public var context: String
    }

    /// At least this many letters (after removing punctuation) make a quotation.
    public static let minimumLength = 6

    public static func extract(from text: String, minimumLength: Int = minimumLength, maximumLength: Int = 400) -> [Quote] {
        let characters = Array(text)
        // Vertical-text brackets ﹁﹂﹃﹄ and single quotation marks standing on their own (0.26).
        let pairs: [Character: Character] = ["“": "”", "「": "」", "『": "』", "﹁": "﹂", "﹃": "﹄", "‘": "’", "\"": "\""]
        var quotes: [Quote] = []
        var seen = Set<String>()
        var index = 0
        while index < characters.count {
            let open = characters[index]
            guard let close = pairs[open] else { index += 1; continue }
            // The matching close mark, allowing one level of nesting of the same kind.
            var depth = 0, end = index + 1
            var found: Int?
            while end < characters.count && end - index <= maximumLength + 1 {
                let character = characters[end]
                if character == open && open != close { depth += 1 }
                if character == close {
                    if depth == 0 { found = end; break }
                    depth -= 1
                }
                if character == "\n" && open == "\"" { break }
                end += 1
            }
            guard let stop = found else { index += 1; continue }
            let inner = String(characters[(index + 1)..<stop]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(QuoteMatcher.normalized(inner))
            if key.count >= minimumLength, !seen.contains(key) {
                seen.insert(key)
                let before = String(characters[max(0, index - 20)..<index]).replacingOccurrences(of: "\n", with: " ")
                quotes.append(Quote(text: inner, context: before))
            }
            index = stop + 1
        }
        return quotes
    }
}
