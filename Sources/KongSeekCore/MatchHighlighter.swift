import Foundation

/// Finds which characters of a file name explain a match, for highlighting:
/// literal text first, then pinyin (full spelling or initials), then an
/// abbreviation such as `rpt` for "report".
public enum MatchHighlighter {
    /// UTF-16 ranges in `name` to highlight for `words`, merged and sorted.
    public static func ranges(in name: String, words: [String]) -> [NSRange] {
        var result: [NSRange] = []
        for word in words where !word.isEmpty {
            var literal = literalRanges(in: name, word: word)
            if literal.isEmpty && SearchText.containsCJK(word) {
                // 繁简: the conversion keeps positions, so ranges in the simplified name fit the original.
                literal = literalRanges(in: SearchText.simplifiedChinese(name), word: SearchText.simplifiedChinese(word))
            }
            if !literal.isEmpty {
                result += literal
            } else if let pinyin = pinyinRanges(in: name, word: word) {
                result += pinyin
            } else {
                result += abbreviationRanges(in: name, word: word)
            }
        }
        return merge(result)
    }

    static func literalRanges(in name: String, word: String) -> [NSRange] {
        let source = name as NSString
        var found: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: searchRange)
            if range.location == NSNotFound || range.length == 0 { break }
            found.append(range)
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return found
    }

    /// Letters of an ASCII word found in order, as 3.2 highlighted abbreviations.
    static func abbreviationRanges(in name: String, word: String) -> [NSRange] {
        guard word.count >= 2, word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return [] }
        let source = name as NSString
        var ranges: [NSRange] = []
        var start = 0
        for ch in word {
            let range = source.range(of: String(ch), options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: source.length - start))
            if range.location == NSNotFound { return [] }
            ranges.append(range)
            start = range.location + range.length
        }
        return ranges
    }

    /// One character of the stem with the Latin letters it contributes to the
    /// pinyin forms, and whether it starts a new syllable/word ("part").
    struct Unit {
        let range: NSRange
        let latin: String
        let startsPart: Bool
    }

    /// Ranges of the characters whose pinyin matches `word`, or nil if the word
    /// is not a pinyin match (or the name's pinyin could not be mapped back).
    static func pinyinRanges(in name: String, word: String) -> [NSRange]? {
        let folded = SearchText.fold(word)
        guard folded.count >= 2, folded.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }) else { return nil }
        let stem = (name as NSString).deletingPathExtension
        guard SearchText.containsCJK(stem), let units = pinyinUnits(stem) else { return nil }
        let full = units.map(\.latin).joined()
        let starts = units.filter(\.startsPart)
        let initials = String(starts.compactMap(\.latin.first))
        // Only trust the mapping when it rebuilds exactly the forms the index uses.
        guard [full, initials] == Pinyin.forms(stem) else { return nil }

        if let match = full.range(of: folded) {
            let lower = full.distance(from: full.startIndex, to: match.lowerBound)
            let upper = lower + folded.count
            var offset = 0
            var ranges: [NSRange] = []
            for unit in units {
                let end = offset + unit.latin.count
                if !unit.latin.isEmpty && end > lower && offset < upper { ranges.append(unit.range) }
                offset = end
            }
            return ranges
        }
        if let match = initials.range(of: folded) {
            let lower = initials.distance(from: initials.startIndex, to: match.lowerBound)
            return starts[lower..<(lower + folded.count)].map(\.range)
        }
        return nil
    }

    /// Splits a name into units the way `Pinyin.forms` reads it: each Han
    /// character is one syllable (phrase readings applied); Latin letters and
    /// digits stay as they are; anything else separates words. A space (a new
    /// part) comes before every Han character that follows a letter or another
    /// Han character. Returns nil for names this mapping does not cover.
    static func pinyinUnits(_ stem: String) -> [Unit]? {
        enum Kind { case han, letter, digit, separator }
        var characters: [(char: Character, range: NSRange, kind: Kind)] = []
        var offset = 0
        for ch in stem {
            let length = ch.utf16.count
            let kind: Kind
            if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first, (0x3400...0x9fff).contains(scalar.value) {
                kind = .han
            } else if ch.isLetter {
                kind = .letter
            } else if ch.isNumber {
                kind = .digit
            } else {
                kind = .separator
            }
            characters.append((ch, NSRange(location: offset, length: length), kind))
            offset += length
        }

        // Syllables for each run of Han characters, with phrase readings.
        var syllables: [Int: String] = [:]
        var i = 0
        while i < characters.count {
            guard characters[i].kind == .han else { i += 1; continue }
            var j = i
            while j < characters.count && characters[j].kind == .han { j += 1 }
            let run = String(characters[i..<j].map(\.char))
            var pieces = Pinyin.transformLatin(run).split(separator: " ").map(String.init)
            guard pieces.count == j - i else { return nil }
            let runChars = Array(run)
            for item in Pinyin.phraseReadings {
                let phrase = Array(item.phrase)
                let reading = item.reading.split(separator: " ").map(String.init)
                guard reading.count == phrase.count, phrase.count <= runChars.count else { continue }
                for start in 0...(runChars.count - phrase.count) where Array(runChars[start..<(start + phrase.count)]) == phrase {
                    for k in 0..<phrase.count { pieces[start + k] = reading[k] }
                }
            }
            for (k, piece) in pieces.enumerated() {
                guard !piece.isEmpty, piece.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) else { return nil }
                syllables[i + k] = piece
            }
            i = j
        }

        var units: [Unit] = []
        var previous: Kind?
        for (index, item) in characters.enumerated() {
            let latin: String
            switch item.kind {
            case .han:
                latin = syllables[index] ?? ""
            case .letter, .digit:
                latin = SearchText.fold(String(item.char))
                guard latin.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }) else { return nil }
            case .separator:
                latin = ""
            }
            let startsPart: Bool
            switch item.kind {
            case .separator:
                startsPart = false
            case .han:
                startsPart = previous == nil || previous == .separator || previous == .han || previous == .letter
            case .letter, .digit:
                startsPart = previous == nil || previous == .separator
            }
            units.append(Unit(range: item.range, latin: latin, startsPart: startsPart))
            previous = item.kind
        }
        return units
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
