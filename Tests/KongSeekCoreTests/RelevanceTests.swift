import XCTest
@testable import KongSeekCore

/// 0.12 ordering: same matches as 3.2, better order.
final class RelevanceTests: XCTestCase {
    private func order(_ names: [String], _ words: [String]) -> [String] {
        names.map { ($0, Relevance.score(name: $0, words: words)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.0)
    }

    private let title = "孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编 -- 北京_高等教育出版社 -- 9787040500288 -- Anna’s Archive.pdf"

    func testPinyinOnSyllablesBeatsScatteredLettersAndLongTitles() {
        XCTAssertEqual(order([title, "论月.pdf", "论语稽.pdf", "论语.pdf"], ["lunyu"]),
                       ["论语.pdf", "论语稽.pdf", "论月.pdf", title])
        XCTAssertGreaterThan(Relevance.score(name: "论语古义.pdf", words: ["lunyu"]), Relevance.score(name: "论月.pdf", words: ["lunyu"]))
        XCTAssertGreaterThan(Relevance.score(name: "论语.pdf", words: ["ly"]), Relevance.score(name: "孔子与论语.pdf", words: ["ly"]))
    }

    func testLiteralPositions() {
        XCTAssertEqual(order(["myreports.txt", "final report.docx", "report.pdf"], ["report"]),
                       ["report.pdf", "final report.docx", "myreports.txt"])
        XCTAssertEqual(order(["年度合同.pdf", "合同.pdf"], ["合同"]).first, "合同.pdf")
        XCTAssertGreaterThan(Relevance.score(name: "report.pdf", words: ["rep"]), Relevance.score(name: "rupert.pdf", words: ["rpt"]))
        XCTAssertEqual(Relevance.score(name: "x.txt", words: []), 0)
    }

    func testCombinedKeepsBaseScoreAsTieBreak() {
        XCTAssertGreaterThan(Relevance.combined(relevance: 90, base: 0), Relevance.combined(relevance: 89, base: 99_999))
        XCTAssertGreaterThan(Relevance.combined(relevance: 90, base: 600), Relevance.combined(relevance: 90, base: 550))
    }

    func testIndexRefinesWithoutChangingMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relevance-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["书/" + title, "书/论月.pdf", "书/论语稽.pdf", "书/论语.pdf", "书/其他.pdf"])
        let index = NameIndex.build(roots: [Paths.canonical(root)], rules: .standard(home: root))
        let query = SearchQuery("lunyu")
        let hits = index.search(query)
        let refined = index.refined(hits, query: query)
        XCTAssertEqual(Set(refined.map(\.id)), Set(hits.map(\.id)), "same matches")
        let names = refined.sorted { $0.score > $1.score }.map { index.name(of: $0.id) }
        XCTAssertEqual(names, ["论语.pdf", "论语稽.pdf", "论月.pdf", title])
        // dupe: keeps its own order and scores.
        XCTAssertEqual(index.refined(hits, query: SearchQuery("dupe: lunyu")), hits)
    }
}
