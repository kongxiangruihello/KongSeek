import XCTest
@testable import KongSeekCore

/// 繁简通搜 (0.16).
final class ChineseScriptTests: XCTestCase {
    func testFoldingMeetsInSimplified() {
        XCTAssertEqual(SearchText.simplifiedChinese("華夏邊緣：歷史記憶與族群認同"), "华夏边缘：历史记忆与族群认同")
        XCTAssertEqual(SearchText.simplifiedChinese("中國官制史"), "中国官制史")
        XCTAssertEqual(SearchText.simplifiedChinese("论语 report"), "论语 report", "simplified text is unchanged")
        XCTAssertEqual(SearchText.fold("華夏"), SearchText.fold("华夏"))
        XCTAssertEqual(SearchText.fold("Report 學而"), "report 学而")
        // One character for one character: positions survive.
        let names = ["靜靜的思想之河", "黨史筆記", "經學成就述要"]
        for name in names {
            XCTAssertEqual((SearchText.simplifiedChinese(name) as NSString).length, (name as NSString).length, name)
        }
        XCTAssertEqual(Set(SearchText.scriptVariants("学而")), ["学而", "學而"])
        XCTAssertEqual(SearchText.scriptVariants("report"), ["report"])
    }

    func testIndexHighlightAndSnippets() throws {
        let root = Paths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["ebook/華夏邊緣：歷史記憶與族群認同.pdf", "ebook/中國官制史.pdf", "ebook/中国官制史研究.pdf", "ebook/其他.pdf"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        func names(_ text: String) -> [String] { index.search(SearchQuery(text)).map { index.name(of: $0.id) }.sorted() }
        XCTAssertEqual(names("华夏边缘"), ["華夏邊緣：歷史記憶與族群認同.pdf"])
        XCTAssertEqual(names("官制史"), ["中国官制史研究.pdf", "中國官制史.pdf"])
        XCTAssertEqual(names("中國"), ["中国官制史研究.pdf", "中國官制史.pdf"], "traditional input finds simplified names too")
        XCTAssertEqual(names("huaxia"), ["華夏邊緣：歷史記憶與族群認同.pdf"], "pinyin of traditional names")

        XCTAssertEqual(MatchHighlighter.ranges(in: "華夏邊緣.pdf", words: ["华夏"]), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(Snippet.find(in: "子曰：學而時習之", needles: ["学而"])?.text, "子曰：學而時習之")
        let store = OCRStore(directory: URL(fileURLWithPath: root).appendingPathComponent("ocr"))
        try store.save(OCRRecord(path: "/x/scan.pdf", size: 1, modified: Date(), pages: ["學而時習之"], totalPages: 1))
        XCTAssertEqual(store.search(["学而"]).map(\.path), ["/x/scan.pdf"])
    }

    // MARK: Variant characters (0.20)

    func testVariantsFoldTogether() {
        for (variant, standard) in [("峯", "峰"), ("綫裝書", "线装书"), ("説文解字", "说文解字"), ("羣書治要", "群书治要"), ("鷄", "鸡"), ("爲學", "为学")] {
            XCTAssertEqual(SearchText.fold(variant), SearchText.fold(standard), variant)
            XCTAssertEqual((SearchText.simplifiedChinese(variant) as NSString).length, (variant as NSString).length, variant)
        }
        XCTAssertEqual(SearchText.fold("论语 report"), "论语 report", "simplified text is unchanged")
    }

    func testVariantNamesFound() throws {
        let root = Paths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("variant-\(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["羣書治要.pdf", "説文解字注.pdf", "其他.pdf"])
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        func names(_ text: String) -> [String] { index.search(SearchQuery(text)).map { index.name(of: $0.id) }.sorted() }
        XCTAssertEqual(names("群书治要"), ["羣書治要.pdf"])
        XCTAssertEqual(names("说文"), ["説文解字注.pdf"])
    }
}
