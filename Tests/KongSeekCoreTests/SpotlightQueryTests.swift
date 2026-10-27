import XCTest
@testable import KongSeekCore

final class SpotlightQueryTests: XCTestCase {
    func testWordsPhrasesAndFilters() {
        XCTAssertNil(SpotlightQuery.content(for: SearchQuery("")))
        XCTAssertNil(SpotlightQuery.content(for: SearchQuery("ext:pdf")), "full-text search needs a word")
        XCTAssertNil(SpotlightQuery.content(for: SearchQuery("学而 ext:../pdf")), "invalid queries are not run")

        XCTAssertEqual(SpotlightQuery.content(for: SearchQuery("学而")),
                       "(kMDItemTextContent == \"学而*\"cdw || kMDItemDisplayName == \"*学而*\"cd)")
        XCTAssertEqual(SpotlightQuery.content(for: SearchQuery("\"不亦说乎\" ext:pdf,docx -ext:txt")),
                       "(kMDItemTextContent == \"*不亦说乎*\"cd || kMDItemDisplayName == \"*不亦说乎*\"cd)"
                           + " && (kMDItemFSName == \"*.docx\"c || kMDItemFSName == \"*.pdf\"c)"
                           + " && kMDItemFSName != \"*.txt\"c")
    }

    func testTypeDateSizeAndTag() throws {
        let pdfWeek = try XCTUnwrap(SpotlightQuery.content(for: SearchQuery("最近一周的 PDF 仁")))
        XCTAssertTrue(pdfWeek.contains("kMDItemContentTypeTree == \"com.adobe.pdf\""), pdfWeek)
        XCTAssertTrue(pdfWeek.contains("kMDItemFSContentChangeDate >= $time.today(-6)"), pdfWeek)
        XCTAssertTrue(pdfWeek.hasPrefix("(kMDItemTextContent == \"仁*\"cdw"), pdfWeek)

        let docs = try XCTUnwrap(SpotlightQuery.content(for: SearchQuery("文档 王阳明")))
        XCTAssertTrue(docs.contains("(kMDItemContentTypeTree == \"public.text\" || "), docs)

        let other = try XCTUnwrap(SpotlightQuery.content(for: SearchQuery("昨天 大于10MB 标签:工作 讲稿")))
        XCTAssertTrue(other.contains("kMDItemFSContentChangeDate >= $time.today(-1) && kMDItemFSContentChangeDate < $time.today"), other)
        XCTAssertTrue(other.contains("kMDItemFSSize > 10000000"), other)
        XCTAssertTrue(other.contains("kMDItemUserTags == \"工作\"cd"), other)
    }

    func testEscaping() {
        XCTAssertEqual(SpotlightQuery.escape("a\"b*c\\d"), "a\\\"b\\*c\\\\d")
    }

    func testExclusionRulesForSpotlightResults() {
        let home = "/Users/kong"
        let roots = [home, home + "/Library/Mobile Documents/com~apple~CloudDocs", "/Applications"]
        let rules = ExclusionRules(excludedPaths: [home + "/Library"], excludedNames: ["node_modules", ".git"], includeHidden: false)
        XCTAssertFalse(rules.excludes(path: home + "/Documents/讲稿.docx", roots: roots))
        XCTAssertFalse(rules.excludes(path: home + "/课程/build/讲义.pdf", roots: roots))
        XCTAssertTrue(rules.excludes(path: home + "/Library/Caches/x.txt", roots: roots))
        XCTAssertFalse(rules.excludes(path: home + "/Library/Mobile Documents/com~apple~CloudDocs/论文.pdf", roots: roots))
        XCTAssertTrue(rules.excludes(path: home + "/project/node_modules/a/readme.md", roots: roots))
        XCTAssertTrue(rules.excludes(path: home + "/.config/notes.txt", roots: roots))
        XCTAssertTrue(rules.excludes(path: "/Volumes/外置盘/资料.pdf", roots: roots), "outside every root")
        var hidden = rules
        hidden.includeHidden = true
        XCTAssertFalse(hidden.excludes(path: home + "/.config/notes.txt", roots: roots))
    }
}
