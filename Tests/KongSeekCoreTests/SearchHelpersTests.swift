import XCTest
@testable import KongSeekCore

/// 0.35: 同义词与别名, 打开过:, 按查询记住选择, 搜不到时的建议, 预置收藏.
final class SearchHelpersTests: XCTestCase {
    func testAliases() {
        let aliases = SearchAliases(lines: ["王守仁=王阳明=阳明", "四书>论语,孟子,大学,中庸", "孤单", "  "])
        XCTAssertEqual(aliases.lines, ["王守仁=王阳明=阳明", "四书>论语,孟子,大学,中庸"], "a line with one name is dropped")
        XCTAssertEqual(aliases.alternatives(for: "阳明"), ["王守仁", "王阳明"])
        XCTAssertEqual(aliases.alternatives(for: "陽明"), ["王守仁", "王阳明"], "繁简 alike")
        XCTAssertEqual(aliases.alternatives(for: "yangming"), ["王守仁", "王阳明"], "by full pinyin")
        XCTAssertEqual(aliases.alternatives(for: "四书"), ["论语", "孟子", "大学", "中庸"])
        XCTAssertEqual(aliases.alternatives(for: "论语"), [], "a one-way line does not work backwards")
        XCTAssertEqual(aliases.alternatives(for: "传习录"), [])

        XCTAssertEqual(aliases.expansions(of: ["阳明", "传习录"]), [["王守仁", "传习录"], ["王阳明", "传习录"]])
        let both = aliases.expansions(of: ["阳明", "四书"])
        XCTAssertEqual(both.count, 12, "capped")
        XCTAssertEqual(both.first, ["王守仁", "四书"])
        XCTAssertTrue(both.contains(["王守仁", "论语"]), "two words changed together")
        XCTAssertTrue(SearchAliases.none.expansions(of: ["阳明"]).isEmpty)

        let standard = SearchAliases.standard
        XCTAssertEqual(standard.lines.count, SearchAliases.standardLines.count, "every standard line is valid")
        XCTAssertTrue(standard.alternatives(for: "朱子").contains("朱熹"))
        XCTAssertTrue(standard.alternatives(for: "船山").contains("王夫之"))
    }

    func testAliasesInFullText() throws {
        let aliases = SearchAliases(lines: ["王守仁=阳明"])
        let with = try XCTUnwrap(SpotlightQuery.content(for: SearchQuery("阳明 心学"), aliases: aliases))
        XCTAssertTrue(with.contains("王守仁"))
        XCTAssertFalse(try XCTUnwrap(SpotlightQuery.content(for: SearchQuery("阳明 心学"))).contains("王守仁"))
    }

    func testOtherWordsKeepTheFilters() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aliases-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let root = Paths.canonical(path)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["书/王守仁全集.pdf", "书/王守仁全集.txt", "书/阳明先生年谱.pdf", "书/论语义疏.pdf", "书/孟子.pdf"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        func names(_ query: SearchQuery) -> [String] {
            index.search(query).map { (index.path(of: $0.id) as NSString).lastPathComponent }.sorted()
        }
        let query = SearchQuery("阳明 ext:pdf")
        XCTAssertEqual(names(query), ["阳明先生年谱.pdf"])
        XCTAssertEqual(names(query.replacingWords(["王守仁"])), ["王守仁全集.pdf"], "ext: kept with the other name")

        // A name written with a homophone is found by its pinyin.
        let spelled = try XCTUnwrap(SpellingVariants.pinyinWords(["论语义书"]))
        XCTAssertEqual(spelled, ["lunyuyishu"])
        XCTAssertEqual(names(SearchQuery("x").replacingWords(spelled)), ["论语义疏.pdf"])
        // A word with one character left out finds the name, which is then checked.
        let gapHits = index.search(SearchQuery("论语义")).filter { SpellingVariants.withinOneEdit(index.name(of: $0.id), of: "论语义书") }
        XCTAssertEqual(gapHits.map { index.name(of: $0.id) }, ["论语义疏.pdf"])
    }

    func testOpenedOperator() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let query = SearchQuery("论语 打开过:7d", now: now, calendar: calendar)
        XCTAssertTrue(query.valid)
        XCTAssertEqual(query.words, ["论语"])
        XCTAssertTrue(query.advanced.opened)
        XCTAssertTrue(query.advanced.acceptsOpened(at: now.addingTimeInterval(-86_400)))
        XCTAssertFalse(query.advanced.acceptsOpened(at: now.addingTimeInterval(-30 * 86_400)))
        XCTAssertFalse(query.advanced.acceptsOpened(at: nil), "never opened")
        XCTAssertEqual(query.advanced.descriptions, ["打开过：7d"])

        let ever = SearchQuery("打开过:")
        XCTAssertTrue(ever.valid)
        XCTAssertTrue(ever.advanced.acceptsOpened(at: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(ever.advanced.descriptions, ["打开过的"])
        XCTAssertTrue(SearchQuery("opened:thisweek").advanced.opened)
        XCTAssertFalse(SearchQuery("打开过:soon").valid)
        XCTAssertTrue(SearchQuery("论语").advanced.acceptsOpened(at: nil), "no filter, no condition")
    }

    func testQueryChoices() throws {
        var choices = QueryChoices()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        choices.record(query: "LunYu ", path: "/讲义/论语导读.pptx", date: start)
        choices.record(query: "lunyu", path: "/书/论语译注.pdf", date: start.addingTimeInterval(60))
        choices.record(query: "lunyu", path: "/书/论语译注.pdf", date: start.addingTimeInterval(120))
        XCTAssertEqual(choices.preferred(for: "  lunyu"), ["/书/论语译注.pdf", "/讲义/论语导读.pptx"], "opened most first")
        XCTAssertEqual(choices.preferred(for: "lunyu daodu"), [])

        choices.move(from: "/书/论语译注.pdf", to: "/新/论语译注.pdf")
        XCTAssertEqual(choices.preferred(for: "lunyu").first, "/新/论语译注.pdf")
        choices.remove("/讲义/论语导读.pptx")
        XCTAssertEqual(choices.preferred(for: "lunyu"), ["/新/论语译注.pdf"])

        for index in 0..<8 { choices.record(query: "mengzi", path: "/书/\(index).pdf", date: start.addingTimeInterval(Double(index))) }
        XCTAssertEqual(choices.preferred(for: "mengzi").count, QueryChoices.choicesPerQuery)
        XCTAssertTrue(choices.preferred(for: "mengzi").contains("/书/7.pdf"), "the latest kept")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("choices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try choices.save(to: url)
        XCTAssertEqual(QueryChoices.load(from: url), choices)
    }

    func testSpellingVariantsAndPresets() {
        XCTAssertNil(SpellingVariants.pinyinWords(["abc", "pdf"]))
        XCTAssertEqual(SpellingVariants.gaps("论语义书"), [["语义书"], ["论", "义书"], ["论语", "书"], ["论语义"]])
        XCTAssertEqual(SpellingVariants.gaps("论语"), [], "too short to guess")
        XCTAssertEqual(SpellingVariants.gaps("abcd"), [], "Latin words are matched by pinyin and abbreviations already")
        XCTAssertTrue(SpellingVariants.withinOneEdit("论语义疏（四库本）.pdf", of: "论语义书"), "one character different")
        XCTAssertTrue(SpellingVariants.withinOneEdit("論語義疏.pdf", of: "论语义书"), "繁简 alike")
        XCTAssertTrue(SpellingVariants.withinOneEdit("论语义.pdf", of: "论语义书"), "one character missing")
        XCTAssertTrue(SpellingVariants.withinOneEdit("论语之义书.pdf", of: "论语义书"), "one character added")
        XCTAssertFalse(SpellingVariants.withinOneEdit("论语集注.pdf", of: "论语义书"))

        for preset in SavedSearchPresets.all {
            XCTAssertTrue(SearchQuery(preset.query).valid, preset.query)
        }
        XCTAssertEqual(Set(SavedSearchPresets.all.map(\.query)).count, SavedSearchPresets.all.count)
    }
}
