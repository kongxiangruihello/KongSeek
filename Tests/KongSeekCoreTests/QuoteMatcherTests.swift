import XCTest
@testable import KongSeekCore

/// 引文查证 and 书内全部命中 (0.21).
final class QuoteMatcherTests: XCTestCase {
    private let pages = [
        "前言\n本书据阮元校刻本。",
        "子曰：“學而時習之，不亦說乎？有朋自遠方來，\n不亦樂乎？人不知而不慍，不亦君子乎？”",
        "有子曰：其為人也孝弟，而好犯上者，鮮矣。",
    ]

    func testExactAcrossScriptsAndPunctuation() {
        let match = QuoteMatcher.best(in: pages, quote: "有朋自远方来，不亦乐乎")
        XCTAssertEqual(match?.unit, 1)
        XCTAssertEqual(match?.exact, true)
        XCTAssertTrue(match?.excerpt.contains("有朋自遠方來") ?? false, match?.excerpt ?? "")
    }

    func testNearMatch() {
        // One character misremembered: 悦 for 说.
        let match = QuoteMatcher.best(in: pages, quote: "学而时习之，不亦悦乎")
        XCTAssertEqual(match?.unit, 1)
        XCTAssertEqual(match?.exact, false)
        XCTAssertGreaterThan(match?.score ?? 0, 0.6)
        XCTAssertNil(QuoteMatcher.best(in: pages, quote: "知之为知之，不知为不知"))
    }

    func testProbes() {
        XCTAssertEqual(QuoteMatcher.probes("有朋自远方来，不亦乐乎？"), ["有朋自远方", "自远方来不", "来不亦乐乎"])
        XCTAssertEqual(QuoteMatcher.probes("学而"), ["学而"])
    }

    func testPageHits() {
        let hits = PageHits.find(in: ["甲乙", "克己复\n礼为仁。一日克己复礼", "丙", "克己復禮"], firstPage: 10, words: ["克己复礼"])
        XCTAssertEqual(hits.map(\.page), [11, 13])
        XCTAssertEqual(hits.map(\.count), [2, 1])
        XCTAssertTrue(hits[0].snippet.hasPrefix("克己复礼"), hits[0].snippet)
    }

    func testManuscriptQuotes() {
        let manuscript = """
        孔子说“学而时习之，不亦说乎”，又说“仁”。朱熹注云：“学之为言效也。人性皆善，而觉有先后，后觉者必效先觉之所为。”
        又见《论语》“学而”篇。同书又云：“学而时习之，不亦说乎？”（重复）
        「克己复礼为仁。一日克己复礼，天下归仁焉。」
        """
        let quotes = ManuscriptQuotes.extract(from: manuscript)
        XCTAssertEqual(quotes.map(\.text), ["学而时习之，不亦说乎", "学之为言效也。人性皆善，而觉有先后，后觉者必效先觉之所为。", "克己复礼为仁。一日克己复礼，天下归仁焉。"])
        XCTAssertTrue(quotes[1].context.hasSuffix("朱熹注云："), quotes[1].context)
        let nested = ManuscriptQuotes.extract(from: "他说：“子曰：‘学而时习之，不亦说乎？’此之谓也。”")
        XCTAssertEqual(nested.map(\.text), ["子曰：‘学而时习之，不亦说乎？’此之谓也。"])
    }
}
