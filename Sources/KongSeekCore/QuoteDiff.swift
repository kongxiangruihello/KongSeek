import Foundation

/// 逐字异文 (0.26): a quotation compared character by character with the passage it was
/// found in, so a near match shows what differs — 异字 (a different character), 脱字 (in
/// the source, missing from the quotation) and 衍字 (in the quotation, not in the source).
/// Only letters and digits are compared; punctuation and spaces are ignored, and
/// traditional, simplified and variant forms of a character count as the same.
public enum QuoteDiff {
    public enum Segment: Equatable, Sendable {
        /// Agreeing text, as the source writes it.
        case same(String)
        /// 异字: the quotation has `quote` where the source has `source`.
        case changed(quote: String, source: String)
        /// 脱字: in the source, left out of the quotation.
        case missing(String)
        /// 衍字: in the quotation, not in the source.
        case extra(String)
        /// 通假字、古今字 (0.29): different characters the reader's table counts as the same
        /// word (说/悦, 莫/暮) — shown, but not an error.
        case equivalent(quote: String, source: String)
    }

    private enum Step { case same(Character), extra(Character), missing(Character) }

    public static func compare(quote: String, source: String, equivalents: CharacterEquivalents = .none) -> [Segment] {
        segments(steps(quote: quote, source: source)).map { segment in
            if case .changed(let quote, let source) = segment, equivalents.allEquivalent(quote, source) {
                return .equivalent(quote: quote, source: source)
            }
            return segment
        }
    }

    private static func steps(quote: String, source: String) -> [Step] {
        let q = Array(quote).filter { $0.isLetter || $0.isNumber }
        let s = Array(source).filter { $0.isLetter || $0.isNumber }
        guard !q.isEmpty || !s.isEmpty else { return [] }
        let qk = q.map { SearchText.fold(String($0)) }
        let sk = s.map { SearchText.fold(String($0)) }
        let n = q.count, m = s.count
        // lcs[i * width + j]: longest common subsequence of q[i...] and s[j...].
        let width = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * width + j] = qk[i] == sk[j] ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, qk[i] == sk[j] {
                steps.append(.same(s[j]))
                i += 1
                j += 1
            } else if j >= m || (i < n && lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) {
                steps.append(.extra(q[i]))
                i += 1
            } else {
                steps.append(.missing(s[j]))
                j += 1
            }
        }
        // The source passage may run on before and after the quotation: that is context, not 脱字.
        while let first = steps.first, case .missing = first { steps.removeFirst() }
        while let last = steps.last, case .missing = last { steps.removeLast() }
        return steps
    }

    /// Runs of steps as segments; a run of 衍字 next to a run of 脱字 is one 异字.
    private static func segments(_ steps: [Step]) -> [Segment] {
        var result: [Segment] = []
        var same = "", extra = "", missing = ""
        func flushDifference() {
            if !extra.isEmpty && !missing.isEmpty {
                result.append(.changed(quote: extra, source: missing))
            } else if !extra.isEmpty {
                result.append(.extra(extra))
            } else if !missing.isEmpty {
                result.append(.missing(missing))
            }
            extra = ""
            missing = ""
        }
        for step in steps {
            switch step {
            case .same(let character):
                flushDifference()
                same.append(character)
            case .extra(let character):
                if !same.isEmpty { result.append(.same(same)); same = "" }
                extra.append(character)
            case .missing(let character):
                if !same.isEmpty { result.append(.same(same)); same = "" }
                missing.append(character)
            }
        }
        flushDifference()
        if !same.isEmpty { result.append(.same(same)) }
        return result
    }

    /// Whether the segments show any difference (通假 included).
    public static func differs(_ segments: [Segment]) -> Bool {
        segments.contains { if case .same = $0 { return false } else { return true } }
    }

    /// Whether any difference is an error: 异字, 脱字 or 衍字, not 通假.
    public static func hasErrors(_ segments: [Segment]) -> Bool {
        segments.contains {
            switch $0 {
            case .same, .equivalent: return false
            case .changed, .missing, .extra: return true
            }
        }
    }

    /// "异文 2 处（悦/說、弟/悌）、脱 1 字、衍 1 字", or "文字相同（仅标点、字形不同）".
    public static func summary(_ segments: [Segment]) -> String {
        var changed: [String] = []
        var equivalent: [String] = []
        var missing = 0, extra = 0
        for segment in segments {
            switch segment {
            case .changed(let quote, let source): changed.append("\(quote)/\(source)")
            case .equivalent(let quote, let source): equivalent.append("\(quote)/\(source)")
            case .missing(let text): missing += text.count
            case .extra(let text): extra += text.count
            case .same: break
            }
        }
        var parts: [String] = []
        if !changed.isEmpty { parts.append("异文 \(changed.count) 处（\(changed.prefix(5).joined(separator: "、"))\(changed.count > 5 ? "…" : "")）") }
        if missing > 0 { parts.append("脱 \(missing) 字") }
        if extra > 0 { parts.append("衍 \(extra) 字") }
        if !equivalent.isEmpty {
            parts.append((parts.isEmpty ? "仅" : "另有") + "通假或古今字 \(equivalent.count) 处（\(equivalent.prefix(5).joined(separator: "、"))），不算错")
        }
        return parts.isEmpty ? "文字相同（仅标点、字形不同）" : parts.joined(separator: "、")
    }

    /// The quotation as the source writes it: its characters replaced, added or dropped
    /// to agree with the source, its own punctuation kept (for "按原文改正").
    public static func corrected(quote: String, source: String) -> String {
        var pending = steps(quote: quote, source: source)[...]
        var output = ""
        func emitMissing() {
            while let next = pending.first, case .missing(let character) = next {
                output.append(character)
                pending.removeFirst()
            }
        }
        for character in quote {
            guard character.isLetter || character.isNumber else {
                output.append(character)
                continue
            }
            guard let step = pending.first else { output.append(character); continue }
            pending.removeFirst()
            switch step {
            case .same(let sourceCharacter): output.append(sourceCharacter)
            case .extra: break
            case .missing(let sourceCharacter): output.append(sourceCharacter)
            }
            // What the quotation left out goes right after the character before it,
            // ahead of the quotation's punctuation.
            emitMissing()
        }
        emitMissing()
        return output
    }
}

/// 通假字、古今字 (0.29): pairs of characters that write the same word in classical texts
/// (说—悦, 莫—暮), so a quotation using one where the edition has the other is not marked
/// as an error. Starts with common examples; the reader adds or removes pairs.
public struct CharacterEquivalents: Equatable, Sendable {
    /// Folded (simplified) character → those counted as the same.
    private var pairs: [String: Set<String>] = [:]

    public static let none = CharacterEquivalents()

    /// Common examples from the Analects and other classics, as "通假/本字" lines.
    public static let standardLines = [
        "说=悦", "知=智", "女=汝", "弟=悌", "有=又", "共=拱", "归=馈", "亡=无",
        "被=披", "莫=暮", "内=纳", "反=返", "与=欤", "罔=惘", "辟=避",
    ]

    public static var standard: CharacterEquivalents { CharacterEquivalents(lines: standardLines) }

    public init() {}

    /// Lines such as "说=悦", "说 悦", "说悦" or "说＝悦"; other lines are ignored.
    public init(lines: [String]) {
        for line in lines {
            let characters = line.filter { $0.isLetter }.map { SearchText.fold(String($0)) }
            guard characters.count == 2, characters[0] != characters[1] else { continue }
            pairs[characters[0], default: []].insert(characters[1])
            pairs[characters[1], default: []].insert(characters[0])
        }
    }

    /// The pairs as lines, "说=悦", sorted.
    public var lines: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for (first, others) in pairs.sorted(by: { $0.key < $1.key }) {
            for second in others.sorted() where !seen.contains(second + "=" + first) {
                seen.insert(first + "=" + second)
                result.append(first + "=" + second)
            }
        }
        return result
    }

    public var isEmpty: Bool { pairs.isEmpty }

    public func areEquivalent(_ a: String, _ b: String) -> Bool {
        let x = SearchText.fold(a), y = SearchText.fold(b)
        return x == y || pairs[x]?.contains(y) == true
    }

    /// Whether two strings of the same length agree character by character, allowing the pairs.
    public func allEquivalent(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard !pairs.isEmpty, x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).allSatisfy { areEquivalent(String($0), String($1)) }
    }
}
