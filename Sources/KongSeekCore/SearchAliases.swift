import Foundation

/// 同义词与别名 (0.35, after Recoll's synonyms and ZeroLaunch-rs's keyword aliases):
/// names that stand for the same person or book — 阳明 for 王守仁, 朱子 for 朱熹 — so
/// a search for one finds files named with another. Lines such as
/// "王守仁=王阳明=阳明" make a group whose names all stand for each other; a line
/// "四书>论语,孟子,大学,中庸" lets the first name stand for the others but not the
/// reverse (论语 does not bring up 孟子).
public struct SearchAliases: Equatable, Sendable {
    struct Rule: Equatable, Sendable {
        var names: [String]
        /// For "a>b,c": only `names[0]` expands, to the rest.
        var oneWay: Bool
    }

    private(set) var rules: [Rule] = []
    /// Folded name → rule indices, and full pinyin → folded name, for lookups.
    private var byName: [String: [Int]] = [:]
    private var byPinyin: [String: String] = [:]

    public static let none = SearchAliases()

    /// Common names in Chinese intellectual history: 字、号、尊称 of thinkers, and
    /// other names of classics. Each can be changed in 设置 › 通用.
    public static let standardLines = [
        "孔子=孔丘=仲尼=孔夫子",
        "老子=李耳=老聃",
        "庄子=庄周",
        "墨子=墨翟",
        "荀子=荀况=荀卿=孙卿",
        "韩非子=韩非",
        "周敦颐=周濂溪=濂溪=周茂叔",
        "张载=张横渠=横渠",
        "程颢=程明道=明道",
        "程颐=程伊川=伊川",
        "朱熹=朱子=朱晦庵=晦庵=朱元晦=朱文公",
        "陆九渊=陆象山=象山=陆子静",
        "王守仁=王阳明=阳明=王伯安=阳明子",
        "王艮=王心斋=心斋",
        "李贽=李卓吾=卓吾",
        "刘宗周=刘蕺山=蕺山",
        "黄宗羲=黄梨洲=梨洲",
        "顾炎武=顾亭林=亭林",
        "王夫之=王船山=船山",
        "戴震=戴东原=东原",
        "章学诚=章实斋=实斋",
        "苏轼=苏东坡=东坡",
        "康有为=康南海=康长素",
        "梁启超=梁任公=任公=饮冰室主人",
        "谭嗣同=谭复生",
        "严复=严几道",
        "章太炎=章炳麟",
        "鲁迅=周树人",
        "胡适=胡适之",
        "钱穆=钱宾四",
        "四书章句集注=四书集注",
        "诗经=毛诗",
        "尚书=书经",
        "周易=易经",
        "左传=春秋左传=左氏传",
        "史记=太史公书",
        "资治通鉴=通鉴",
        "四书>论语,孟子,大学,中庸",
        "五经>诗经,尚书,礼记,周易,春秋",
    ]

    public static var standard: SearchAliases { SearchAliases(lines: standardLines) }

    public init() {}

    /// Lines as above; "=" or "＝" between names of a group, ">" or "＞" before the
    /// names a one-way line stands for, which are separated by commas or 、.
    public init(lines: [String]) {
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            let arrow = text.firstIndex(where: { $0 == ">" || $0 == "＞" })
            var names: [String]
            if let arrow {
                let head = text[..<arrow].trimmingCharacters(in: .whitespaces)
                let tail = Self.split(String(text[text.index(after: arrow)...]), by: ",，、;；=＝ ")
                names = [head] + tail
            } else {
                names = Self.split(text, by: "=＝,，、;； ")
            }
            var seen = Set<String>()
            names = names.filter { !$0.isEmpty && seen.insert(SearchText.fold($0)).inserted }
            guard names.count > 1, !names[0].isEmpty else { continue }
            rules.append(Rule(names: names, oneWay: arrow != nil))
        }
        for (index, rule) in rules.enumerated() {
            for (position, name) in rule.names.enumerated() where !rule.oneWay || position == 0 {
                let key = SearchText.fold(name)
                byName[key, default: []].append(index)
                if let spelling = Pinyin.forms(name).first, spelling.count >= 4, byPinyin[spelling] == nil { byPinyin[spelling] = key }
            }
        }
    }

    private static func split(_ text: String, by separators: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: separators)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The lines, normalized, for the settings editor.
    public var lines: [String] {
        rules.map { rule in
            rule.oneWay ? rule.names[0] + ">" + rule.names.dropFirst().joined(separator: ",") : rule.names.joined(separator: "=")
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// The other names `word` stands for: by the name itself (繁简 alike), or by its
    /// full pinyin ("yangming" for 阳明).
    public func alternatives(for word: String) -> [String] {
        var key = SearchText.fold(word)
        if byName[key] == nil, let named = byPinyin[key] { key = named }
        guard let indices = byName[key] else { return [] }
        var seen: Set<String> = [key]
        var result: [String] = []
        for index in indices {
            for name in rules[index].names where seen.insert(SearchText.fold(name)).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// The word lists to search besides `words` itself: each word replaced by one of
    /// its alternatives, at most `limit` lists (one word changed at a time first).
    public func expansions(of words: [String], limit: Int = 12) -> [[String]] {
        guard !rules.isEmpty else { return [] }
        let options = words.map { alternatives(for: $0) }
        var result: [[String]] = []
        // One word changed at a time.
        for (position, alternatives) in options.enumerated() {
            for alternative in alternatives {
                var list = words
                list[position] = alternative
                result.append(list)
                if result.count >= limit { return result }
            }
        }
        // Two words changed (for "阳明 朱子"), while there is room.
        let changing = options.indices.filter { !options[$0].isEmpty }
        if changing.count >= 2 {
            for a in 0..<changing.count {
                for b in (a + 1)..<changing.count {
                    for first in options[changing[a]] {
                        for second in options[changing[b]] {
                            var list = words
                            list[changing[a]] = first
                            list[changing[b]] = second
                            result.append(list)
                            if result.count >= limit { return result }
                        }
                    }
                }
            }
        }
        return result
    }
}
