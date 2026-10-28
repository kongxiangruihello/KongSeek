import XCTest
@testable import KongSeekCore

/// 0.26: 逐字异文, the text cache, more quotation marks, and window decisions.
final class PolishTests: XCTestCase {
    func testDiffShowsChangedCharacter() {
        let segments = QuoteDiff.compare(quote: "学而时习之，不亦悦乎", source: "學而時習之，不亦說乎？")
        XCTAssertEqual(segments, [.same("學而時習之不亦"), .changed(quote: "悦", source: "說"), .same("乎")])
        XCTAssertTrue(QuoteDiff.differs(segments))
        XCTAssertEqual(QuoteDiff.summary(segments), "异文 1 处（悦/說）")
        XCTAssertEqual(QuoteDiff.corrected(quote: "学而时习之，不亦悦乎", source: "學而時習之，不亦說乎？"), "學而時習之，不亦說乎")
    }

    func testDiffShowsMissingAndExtra() {
        let missing = QuoteDiff.compare(quote: "克己复礼为仁，一日克己，天下归仁焉", source: "克己復禮為仁。一日克己復禮，天下歸仁焉。")
        XCTAssertEqual(missing, [.same("克己復禮為仁一日克己"), .missing("復禮"), .same("天下歸仁焉")])
        XCTAssertEqual(QuoteDiff.summary(missing), "脱 2 字")
        XCTAssertEqual(QuoteDiff.corrected(quote: "克己复礼为仁，一日克己，天下归仁焉", source: "克己復禮為仁。一日克己復禮，天下歸仁焉。"),
                       "克己復禮為仁，一日克己復禮，天下歸仁焉")

        let extra = QuoteDiff.compare(quote: "学而时习之矣", source: "學而時習之")
        XCTAssertEqual(extra, [.same("學而時習之"), .extra("矣")])
        XCTAssertEqual(QuoteDiff.summary(extra), "衍 1 字")
    }

    func testDiffIgnoresSurroundingContextAndScript() {
        let segments = QuoteDiff.compare(quote: "有朋自远方来", source: "子曰有朋自遠方來，不亦樂乎")
        XCTAssertEqual(segments, [.same("有朋自遠方來")])
        XCTAssertFalse(QuoteDiff.differs(segments))
        XCTAssertEqual(QuoteDiff.summary(segments), "文字相同（仅标点、字形不同）")
        XCTAssertEqual(QuoteDiff.compare(quote: "", source: ""), [])
    }

    func testTextCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("textcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TextCache(directory: folder, maximumBytes: 1_200)
        let stamp = TextCache.Stamp(size: 100, modified: Date(timeIntervalSince1970: 1_000), recognized: 0)
        let entry = TextCache.Entry(path: "/书/论语.pdf", stamp: stamp, pages: ["学而第一", "为政第二"], totalPages: 2, firstPage: 1, isPaged: true, unit: "页")
        XCTAssertNil(cache.load(path: entry.path, stamp: stamp))
        cache.store(entry)
        XCTAssertEqual(cache.load(path: entry.path, stamp: stamp), entry)
        // A changed file, or a scan recognized since, is read again.
        XCTAssertNil(cache.load(path: entry.path, stamp: .init(size: 101, modified: Date(timeIntervalSince1970: 1_000), recognized: 0)))
        XCTAssertNil(cache.load(path: entry.path, stamp: .init(size: 100, modified: Date(timeIntervalSince1970: 1_000), recognized: 5)))
        XCTAssertNotEqual(TextCache.fileName(for: "/a"), TextCache.fileName(for: "/b"))

        // Trimming drops the least recently used entries first.
        let big = String(repeating: "字", count: 200)
        for number in 0..<4 {
            cache.store(.init(path: "/书/\(number).pdf", stamp: stamp, pages: [big], totalPages: 1, firstPage: 1, isPaged: true, unit: "页"))
            let file = folder.appendingPathComponent(TextCache.fileName(for: "/书/\(number).pdf"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + number))], ofItemAtPath: file.path)
        }
        XCTAssertGreaterThan(cache.size, 1_200)
        cache.trim()
        XCTAssertLessThanOrEqual(cache.size, 1_200)
        XCTAssertNotNil(cache.load(path: "/书/3.pdf", stamp: stamp), "the most recently used stays")
        XCTAssertNil(cache.load(path: "/书/0.pdf", stamp: stamp))
        cache.clear()
        XCTAssertEqual(cache.size, 0)
    }

    func testMoreQuotationMarks() {
        let quotes = ManuscriptQuotes.extract(from: "﹁學而時習之，不亦說乎﹂一句，又如‘有朋自远方来，不亦乐乎’。他说：“子曰：‘克己复礼为仁’”")
        XCTAssertEqual(quotes.map(\.text), ["學而時習之，不亦說乎", "有朋自远方来，不亦乐乎", "子曰：‘克己复礼为仁’"])
        XCTAssertTrue(ManuscriptQuotes.extract(from: "it’s the student’s book, isn’t it").isEmpty)
    }

    func testFeatureSearch() {
        XCTAssertTrue(FeatureSearch.matches("ywcz", title: "引文查证", text: "找出处"))
        XCTAssertTrue(FeatureSearch.matches("yinwen", title: "引文查证", text: ""))
        XCTAssertTrue(FeatureSearch.matches("出處", title: "引文查证", text: "找出处和页码"))
        XCTAssertTrue(FeatureSearch.matches("引文 页码", title: "引文查证", text: "找出处和页码"))
        XCTAssertFalse(FeatureSearch.matches("重复", title: "引文查证", text: "找出处"))
        XCTAssertTrue(FeatureSearch.matches("  ", title: "任何", text: ""))
    }

    func testVerdictsAndSummaries() {
        XCTAssertEqual(QuoteVerdict.text(score: 1), "完全一致")
        XCTAssertEqual(QuoteVerdict.text(score: 0.866), "近似 87%")
        XCTAssertEqual(QuoteVerdict.text(score: nil), "未找到")
        XCTAssertEqual(QuoteVerdict.summary([.some(1), .some(0.8), .some(nil), nil]), "共 4 条引文：完全一致 1，近似 1，未找到 1，待核对 1")
        XCTAssertEqual(TaskSummary.tooltip([]), "KongSeek")
        XCTAssertEqual(TaskSummary.tooltip([(title: "文字识别", detail: "论语.pdf")]), "KongSeek 后台任务：\n文字识别：论语.pdf")
        XCTAssertEqual(SavedFileLists.suggestedName(heading: "搜索“《论语》导读”的结果"), "《论语》导读")
        XCTAssertEqual(SavedFileLists.suggestedName(heading: "清单：本学期书单"), "本学期书单")
        XCTAssertEqual(SavedFileLists.suggestedName(heading: "~/Documents/讲义"), "讲义")
    }
}
