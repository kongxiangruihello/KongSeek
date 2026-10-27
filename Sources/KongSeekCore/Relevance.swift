import Foundation

/// Orders matches better than 3.2's scores alone (0.12). Which files match does
/// not change; only their order. Per query word, the best of:
///
///     literal at the start of the name                    90
///     literal at a word boundary, or in Chinese text      85
///     literal inside a word                               70
///     pinyin on syllable boundaries from the first one    82   lunyu → 论语稽
///     pinyin on syllable boundaries                       78
///     pinyin starting on a syllable, ending inside one    62   lunyu → 论月 (lun yue)
///     initials from the start / elsewhere                 74 / 68
///     pinyin not on a syllable boundary                   40
///     scattered letters (abbreviation)                    30
///     anything else 3.2 accepted (e.g. folder path)       20
///
/// plus up to 30 for how much of the name the query covers (论语.pdf beats a
/// 150-character book title that also contains 论语). A query equal to the whole
/// name (or name without extension) gets 1000.
public enum Relevance {
    public static func score(name: String, words rawWords: [String]) -> Int {
        var cache = Pinyin.RunCache()
        return score(name: name, words: rawWords, cache: &cache)
    }

    static func score(name: String, words rawWords: [String], cache: inout Pinyin.RunCache) -> Int {
        let words = rawWords.map(SearchText.fold).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        return score(rawName: name, folded: SearchText.fold(name), stem: SearchText.fold((name as NSString).deletingPathExtension),
                     foldedWords: words, cache: &cache)
    }

    /// As `score(name:words:)` with the name, its stem and the words already folded
    /// (the index keeps folded names, so searching does not fold them again).
    static func score(rawName name: String, folded: String, stem: String, foldedWords words: [String], cache: inout Pinyin.RunCache) -> Int {
        guard !words.isEmpty else { return 0 }
        let rawStem = (name as NSString).deletingPathExtension
        let phrase = words.joined(separator: " ")
        if folded == phrase || stem == phrase { return 1000 + 30 }

        // Pinyin: the name's syllables (and Latin words) with their offsets in the
        // joined spelling, so a match can be checked against syllable boundaries.
        var full = ""
        var starts = Set<Int>(), ends = Set<Int>()
        var initials = ""
        // Spelled from the name without extension, as 3.2's pinyin is.
        if SearchText.containsCJK(rawStem) {
            let latin = Pinyin.fastLatin(rawStem, cache: &cache) ?? Pinyin.transformLatin(rawStem)
            for token in latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                starts.insert(full.utf8.count)
                full += token
                ends.insert(full.utf8.count)
                if let first = token.first { initials.append(first) }
            }
        }
        let nameCharacters = Array(folded)
        let stemLength = max(1, stem.count)
        var total = 0
        var coverage = 0.0

        for word in words {
            var best = 0
            var covered = 0.0
            // Literal.
            if let range = folded.range(of: word) {
                let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
                if offset == 0 {
                    best = 90
                } else {
                    let previous = nameCharacters[offset - 1]
                    let boundary = !(previous.isLetter || previous.isNumber) || isCJK(previous) || word.first.map(isCJK) == true
                    best = boundary ? 85 : 70
                }
                covered = Double(word.count) / Double(stemLength)
            }
            // Pinyin and initials (ASCII letters/digits, 2+ characters, as 3.2).
            let pinyinWord = word.count >= 2 && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if pinyinWord && !full.isEmpty {
                let wordLength = word.utf8.count
                var searchStart = full.startIndex
                while let range = full.range(of: word, range: searchStart..<full.endIndex) {
                    let start = full.utf8.distance(from: full.utf8.startIndex, to: range.lowerBound)
                    let end = start + wordLength
                    let value: Int
                    if starts.contains(start) && ends.contains(end) {
                        value = start == 0 ? 82 : 78
                    } else if starts.contains(start) {
                        value = 62
                    } else {
                        value = 40
                    }
                    if value > best {
                        best = value
                        covered = Double(wordLength) / Double(max(1, full.utf8.count))
                    }
                    searchStart = full.index(after: range.lowerBound)
                }
                if let range = initials.range(of: word) {
                    let value = range.lowerBound == initials.startIndex ? 74 : 68
                    if value > best {
                        best = value
                        covered = Double(word.count) / Double(max(1, initials.count))
                    }
                }
            }
            // Scattered letters ("rpt" in report).
            if best == 0 && word.count >= 2 && isSubsequence(word, of: folded) {
                best = 30
                covered = Double(word.count) / Double(stemLength) / 2
            }
            total += best == 0 ? 20 : best
            coverage += covered
        }
        return total + Int((min(1, coverage) * 30).rounded())
    }

    /// Relevance first, then 3.2's score: one number to sort by.
    public static func combined(relevance: Int, base: Int) -> Int {
        relevance * 100_000 + min(max(base, 0), 99_999)
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }

    static func isSubsequence(_ word: String, of text: String) -> Bool {
        var iterator = word.makeIterator()
        var wanted = iterator.next()
        for character in text where character == wanted {
            wanted = iterator.next()
            if wanted == nil { return true }
        }
        return wanted == nil
    }
}

extension NameIndex {
    /// How many of the best matches (by 3.2's score) get the finer order.
    static let refinedLimit = 2_000

    /// Replaces each hit's score with `Relevance.combined` for the query's words
    /// and phrases (order of the array unchanged). Large result sets are refined
    /// for their best 2,000 by 3.2's score; the rest keep their score and so sort
    /// after them. dupe:, word-less and one-character queries are returned as they are.
    public func refined(_ hits: [SearchHit], query: SearchQuery) -> [SearchHit] {
        let words = (query.words + query.phrases).map(SearchText.fold).filter { !$0.isEmpty }
        guard !words.isEmpty, !query.advanced.dupe, !hits.isEmpty else { return hits }
        // A single character matches too much for order to mean anything, and is typed on the way to more.
        if words.count == 1 && words[0].count < 2 { return hits }
        // Only the best by 3.2's score are reordered (the window shows 200): typing
        // stays instant even when a short word matches tens of thousands of names.
        var selected = Array(hits.indices)
        if hits.count > Self.refinedLimit {
            selected = Array(selected.sorted { hits[$0].score != hits[$1].score ? hits[$0].score > hits[$1].score : $0 < $1 }.prefix(Self.refinedLimit))
        }
        var result = hits
        let chunk = 256
        let chunkCount = (selected.count + chunk - 1) / chunk
        var scores = [Int](repeating: 0, count: selected.count)
        scores.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                var cache = Pinyin.RunCache()
                for k in (c * chunk)..<min(selected.count, (c + 1) * chunk) {
                    let hit = hits[selected[k]]
                    let i = Int(hit.id)
                    let foldedName = folded.string(at: i)
                    let stemLength = min(foldedName.utf8.count, Int(stemLengths[i]))
                    let stem = String(decoding: foldedName.utf8.prefix(stemLength), as: UTF8.self)
                    let relevance = Relevance.score(rawName: names.string(at: i), folded: foldedName, stem: stem, foldedWords: words, cache: &cache)
                    output[k] = Relevance.combined(relevance: relevance, base: hit.score)
                }
            }
        }
        for (k, position) in selected.enumerated() {
            result[position] = SearchHit(id: hits[position].id, score: scores[k])
        }
        return result
    }
}
