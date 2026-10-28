import XCTest
@testable import KongSeekCore

/// 0.31: printed page numbers guessed from running heads; manuscript checks kept.
final class BookManuscriptTests: XCTestCase {
    func testCandidatesFromHeadsAndFeet() {
        XCTAssertEqual(PageNumberGuess.candidates(in: "学而第一\n子曰：学而时习之。\n……\n15"), [15])
        XCTAssertEqual(PageNumberGuess.candidates(in: "论语译注 · 23\n正文第一行有 3 个数字 12 和 45 等等内容\n正文\n结尾"), [23])
        XCTAssertEqual(PageNumberGuess.candidates(in: "1980年版\n正文"), [], "a year is not a page")
        XCTAssertEqual(PageNumberGuess.candidates(in: "— 7 —"), [7])
        XCTAssertEqual(PageNumberGuess.candidates(in: ""), [])
    }

    func testGuessFromSampledPages() throws {
        // Printed page = PDF page − 14 on most pages; a few have no number or a stray one.
        var pages: [(pdfPage: Int, text: String)] = []
        for pdfPage in stride(from: 30, through: 120, by: 6) {
            let text: String
            switch pdfPage % 4 {
            case 0: text = "\(pdfPage - 14)\n正文……\n正文"
            case 2: text = "论语译注\n正文……\n\(pdfPage - 14)"
            default: text = "正文\n正文"
            }
            pages.append((pdfPage, text))
        }
        pages.append((47, "第 3 章\n正文\n正文 9"))
        let guess = try XCTUnwrap(PageNumberGuess.guess(pages))
        XCTAssertEqual(guess.offset, 14)
        XCTAssertGreaterThanOrEqual(guess.agreeing, 10)
        XCTAssertEqual(guess.printed(forPDFPage: 29), 15)
        XCTAssertNil(PageNumberGuess.guess([(10, "3"), (20, "13")]), "two pages are too few")
        XCTAssertNil(PageNumberGuess.guess([(10, "x"), (20, "y"), (30, "z")]))

        XCTAssertEqual(PageNumberGuess.samplePages(total: 10, count: 24), Array(1...9))
        let spread = PageNumberGuess.samplePages(total: 500, count: 24)
        XCTAssertEqual(spread.count, 24)
        XCTAssertEqual(spread.first, 50)
        XCTAssertEqual(spread.last, 450)
    }

    func testSessionKeepsResultsByWording() throws {
        let book = EbookName(title: "论语译注", authors: "杨伯峻", publisher: "中华书局", year: "1980")
        let session = ManuscriptSession(manuscript: "/稿/论语讲稿.docx", saved: Date(timeIntervalSince1970: 1_800_000_000), checked: [
            .init(quote: "学而时习之，不亦说乎", source: .init(path: "/书/论语译注.pdf", title: "论语译注", page: 3, unit: "页", score: 1,
                                                          excerpt: "学而时习之，不亦说乎？", book: book, label: "1"), others: 2),
            .init(quote: "稿中臆造的一句话", source: nil, others: 0),
        ])
        XCTAssertEqual(session.result(for: "學而時習之, 不亦說乎")?.source?.page, 3, "punctuation and character forms aside")
        XCTAssertNotNil(session.result(for: "稿中臆造的一句话"))
        XCTAssertNil(session.result(for: "有朋自远方来"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try session.save(in: folder)
        XCTAssertEqual(ManuscriptSession.load(for: "/稿/论语讲稿.docx", in: folder), session)
        XCTAssertNil(ManuscriptSession.load(for: "/稿/别的稿子.docx", in: folder))
        ManuscriptSession.remove(for: "/稿/论语讲稿.docx", in: folder)
        XCTAssertNil(ManuscriptSession.load(for: "/稿/论语讲稿.docx", in: folder))
    }
}
