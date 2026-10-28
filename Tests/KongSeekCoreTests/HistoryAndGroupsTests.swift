import XCTest
@testable import KongSeekCore

/// 0.33: pasted passages keep their results, 引文查证的历史, results grouped by book.
final class HistoryAndGroupsTests: XCTestCase {
    private func source(_ path: String, score: Double = 1) -> ManuscriptSession.Source {
        ManuscriptSession.Source(path: path, title: (path as NSString).lastPathComponent, page: 3, unit: "页", score: score,
                                 excerpt: "学而时习之", book: nil, label: nil)
    }

    func testPastedPassagesAddToOneSession() throws {
        let earlier = ManuscriptSession(manuscript: ManuscriptSession.pasted, checked: [
            .init(quote: "学而时习之，不亦说乎？", source: source("/书/论语.pdf", score: 0.9), others: 0),
            .init(quote: "三人行，必有我师焉。", source: nil, others: 0),
        ])
        let merged = earlier.merging([.init(quote: "學而時習之，不亦說乎", source: source("/书/论语.pdf"), others: 1),
                                      .init(quote: "温故而知新，可以为师矣。", source: source("/书/论语.pdf"), others: 0)])
        XCTAssertEqual(merged.checked.map(\.quote), ["學而時習之，不亦說乎", "温故而知新，可以为师矣。", "三人行，必有我师焉。"],
                       "the newer result replaces the earlier one for the same words; the rest are kept")
        XCTAssertEqual(merged.result(for: "学而时习之不亦说乎")?.source?.score, 1)
        XCTAssertEqual(merged.merging([], limit: 2).checked.count, 2)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try merged.save(in: folder)
        XCTAssertEqual(ManuscriptSession.load(for: ManuscriptSession.pasted, in: folder)?.checked.count, 3)
    }

    func testQuoteHistory() throws {
        var history = QuoteHistory()
        history.add(.init(quote: "学而时习之，不亦说乎", date: Date(timeIntervalSince1970: 1_800_000_000), results: [source("/书/论语.pdf")]))
        history.add(.init(quote: "三人行，必有我师焉", results: [source("/书/甲.pdf", score: 0.8), source("/书/乙.pdf", score: 0.7)]))
        history.add(.init(quote: "不知命，无以为君子也", results: []))
        XCTAssertEqual(history.entries.map(\.summary), ["未找到", "近似 2 处（最高 80%）", "完全一致 1 处"])
        history.add(.init(quote: "學而時習之，不亦說乎？", results: [source("/书/论语.pdf")]))
        XCTAssertEqual(history.entries.count, 3, "the same quotation again replaces its earlier lookup")
        XCTAssertEqual(history.entries.first?.quote, "學而時習之，不亦說乎？")
        XCTAssertNotNil(history.entry(for: "学而时习之不亦说乎"))

        history.add(.init(quote: "很多结果的引文", results: (0..<30).map { source("/书/\($0).pdf", score: 0.7) }))
        XCTAssertEqual(history.entries.first?.results.count, QuoteHistory.resultsKept)
        XCTAssertEqual(QuoteHistory.Entry(quote: String(repeating: "子曰", count: 20), results: []).title.count, 29)

        for index in 0..<120 { history.add(.init(quote: "第\(index)句引文内容", results: [])) }
        XCTAssertEqual(history.entries.count, QuoteHistory.limit)
        XCTAssertEqual(history.entries.first?.quote, "第119句引文内容")

        history.remove("第119句引文内容")
        XCTAssertEqual(history.entries.count, QuoteHistory.limit - 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try history.save(to: url)
        XCTAssertEqual(QuoteHistory.load(from: url).entries.count, history.entries.count)
        history.removeAll()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testResultsGroupedByBook() {
        struct Row { var number: Int; var path: String? }
        let rows = [Row(number: 1, path: "/书/孟子.pdf"), Row(number: 2, path: "/书/论语.pdf"), Row(number: 3, path: nil),
                    Row(number: 4, path: "/书/论语.pdf"), Row(number: 5, path: "/书/大学.pdf")]
        let groups = BookGroups.make(rows) { $0.path }
        XCTAssertEqual(groups.map(\.path), ["/书/论语.pdf", "/书/孟子.pdf", "/书/大学.pdf", nil],
                       "the book quoted most first, then in the order first quoted, unsourced last")
        XCTAssertEqual(groups[0].items.map(\.number), [2, 4])
        XCTAssertEqual(groups[3].items.map(\.number), [3])
        XCTAssertTrue(BookGroups.make([Row]()) { $0.path }.isEmpty)
    }
}
