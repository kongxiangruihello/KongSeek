import XCTest
@testable import KongSeekCore
import KongSeekTestSupport

final class MatchHighlighterTests: XCTestCase {
    /// The highlighted text of `name` for `words`.
    private func marked(_ name: String, _ words: [String]) -> [String] {
        MatchHighlighter.ranges(in: name, words: words).map { (name as NSString).substring(with: $0) }
    }

    func testLiteralMatches() {
        XCTAssertEqual(marked("年度合同汇总.xlsx", ["合同"]), ["合同"])
        XCTAssertEqual(marked("Report-final REPORT.pdf", ["report"]), ["Report", "REPORT"])
        XCTAssertEqual(marked("Café menu.pdf", ["cafe"]), ["Café"])
    }

    func testPinyinFullSpellingAndInitials() {
        XCTAssertEqual(marked("论语译注.pdf", ["lyyz"]), ["论语译注"])
        XCTAssertEqual(marked("论语译注.pdf", ["lunyu"]), ["论语"])
        XCTAssertEqual(marked("论语译注.pdf", ["yizhu"]), ["译注"])
        XCTAssertEqual(marked("重庆火锅.jpg", ["chongqing"]), ["重庆"])
        XCTAssertEqual(marked("银行流水 2024.xlsx", ["yinhang"]), ["银行"])
        XCTAssertEqual(marked("年度报告 final.docx", ["ndbg"]), ["年度报告"])
        XCTAssertEqual(marked("合同abc.txt", ["hetong"]), ["合同"])
        XCTAssertEqual(marked("期末考试_学生名单.xlsx", ["xsmd"]), ["学生名单"])
        // A partial syllable marks the character it falls in.
        XCTAssertEqual(marked("论语译注.pdf", ["unyu"]), ["论语"])
    }

    func testAbbreviation() {
        XCTAssertEqual(marked("report.pdf", ["rpt"]), ["r", "p", "t"])
    }

    func testMultipleWordsAndNoMatch() {
        XCTAssertEqual(marked("论语译注 2024.pdf", ["lunyu", "2024"]), ["论语", "2024"])
        XCTAssertEqual(marked("论语译注.pdf", ["zzz"]), [])
        XCTAssertEqual(marked("论语译注.pdf", []), [])
    }

    /// For every name in a synthetic tree and every pinyin query that matches it,
    /// the highlighter must find characters whose own pinyin covers the query.
    func testPinyinMappingCoversIndexMatches() throws {
        let root = try SyntheticTree.temporaryDirectory("highlight")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try SyntheticTree.create(at: root, files: 800, seed: 9)
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        var checked = 0
        var unmapped: [String] = []
        for query in ["hetong", "ht", "lunyu", "ly", "ndbg", "jianggao", "chongqing", "cq", "yinhang", "xsmd", "kecheng"] {
            for hit in index.search([query]) {
                let name = index.name(of: hit.id)
                guard SearchText.containsCJK(name), NameMatcher.fuzzyScore(name, query) == nil else { continue }
                checked += 1
                if MatchHighlighter.pinyinRanges(in: name, word: query)?.isEmpty != false {
                    unmapped.append("\(query) → \(name)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 200)
        XCTAssertTrue(unmapped.isEmpty, "\(unmapped.count) not highlighted:\n" + unmapped.prefix(15).joined(separator: "\n"))
    }
}
