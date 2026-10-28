import XCTest
@testable import KongSeekCore
@testable import KongSeekText

/// 0.34: quotations corrected as Word revisions; 常用本 chosen by rules.
final class RevisionsAndRulesTests: XCTestCase {
    private func describe(_ edits: [QuoteDiff.Edit]) -> String {
        edits.map { edit -> String in
            switch edit {
            case .keep(let character): return String(character)
            case .delete(let character): return "[-\(character)]"
            case .insert(let character): return "[+\(character)]"
            }
        }.joined()
    }

    func testCorrectionsTouchOnlyRealSlips() {
        // 异字: the wrong character out, the source's in, right after it.
        XCTAssertEqual(describe(QuoteDiff.corrections(quote: "人不知而不温，不亦君子乎？", source: "人不知而不愠，不亦君子乎")),
                       "人不知而不[-温][+愠]，不亦君子乎？")
        // 脱字 from a traditional source goes in simplified, before the punctuation; the
        // traditional forms of the rest are not "corrected".
        XCTAssertEqual(describe(QuoteDiff.corrections(quote: "学而时习之，不亦乎？", source: "學而時習之，不亦說乎")),
                       "学而时习之，不亦[+说]乎？")
        // 衍字.
        XCTAssertEqual(describe(QuoteDiff.corrections(quote: "三人行，则必有我师焉", source: "三人行，必有我师焉")),
                       "三人行，[-则]必有我师焉")
        // A quotation in traditional characters gets the source's characters as they are.
        XCTAssertEqual(describe(QuoteDiff.corrections(quote: "學而時習之，不亦乎", source: "學而時習之，不亦說乎")),
                       "學而時習之，不亦[+說]乎")
        // 通假 in the reader's table is left alone.
        let equivalents = CharacterEquivalents(lines: ["说=悦"])
        XCTAssertEqual(describe(QuoteDiff.corrections(quote: "不亦悦乎", source: "不亦说乎", equivalents: equivalents)), "不亦悦乎")
        XCTAssertFalse(WordComments.Correction(edits: QuoteDiff.corrections(quote: "不亦悦乎", source: "不亦说乎", equivalents: equivalents)).changes)
    }

    func testRevisionsInAWordCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("revisions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        // The first quotation spans two runs, the second bold; the third is in one run with other text.
        let body = #"<w:p><w:r><w:t>孔子说“人不知而</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>不温，不亦君子乎？”此之谓也。</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:t xml:space="preserve">又说“三人行，则必有我师焉”。</w:t></w:r></w:p>"#
        let source = folder.appendingPathComponent("稿.docx")
        let zip = try ZipWriter(url: source)
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.utf8), as: "[Content_Types].xml")
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#.utf8), as: "word/_rels/document.xml.rels")
        try zip.add(Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(w)\"><w:body>\(body)</w:body></w:document>".utf8), as: "word/document.xml")
        try zip.finish()

        let corrections = [
            WordComments.Correction(edits: QuoteDiff.corrections(quote: "人不知而不温，不亦君子乎？", source: "人不知而不愠，不亦君子乎")),
            WordComments.Correction(edits: QuoteDiff.corrections(quote: "三人行，则必有我师焉", source: "三人行，必有我师焉")),
            WordComments.Correction(edits: QuoteDiff.corrections(quote: "稿中没有的引文句子", source: "稿中没有的引文")),
        ]
        let output = folder.appendingPathComponent("改.docx")
        let placement = try WordComments.write(source: source, destination: output,
                                               comments: [.init(anchor: "人不知而不温，不亦君子乎", text: "异文")],
                                               footnotes: [], corrections: corrections, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(placement.comments, [true])
        XCTAssertEqual(placement.corrections, [true, true, false])

        let entry = try XCTUnwrap(try ZipReader.entries(at: output).first { $0.name == "word/document.xml" })
        let document = String(decoding: try ZipReader.data(entry, from: output), as: UTF8.self)
        XCTAssertTrue(XMLParser(data: Data(document.utf8)).parse(), "well-formed")
        XCTAssertTrue(document.contains(#"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">不</w:t></w:r><w:del w:id="#),
                      "the bold run split before the wrong character")
        XCTAssertTrue(document.contains(#"<w:r><w:rPr><w:b/></w:rPr><w:delText xml:space="preserve">温</w:delText></w:r></w:del><w:ins w:id="#))
        XCTAssertTrue(document.contains(#"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">愠</w:t></w:r></w:ins><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">，不亦君子乎？”此之谓也。</w:t></w:r>"#),
                      "the rest of the run keeps its bold")
        XCTAssertTrue(document.contains(#"<w:t>孔子说“人不知而</w:t>"#), "the run without changes is left as it was")
        XCTAssertTrue(document.contains(#"<w:delText xml:space="preserve">则</w:delText>"#))
        XCTAssertTrue(document.contains(#"w:author="KongSeek""#))
        // Revision ids differ from each other and from the comment's.
        let ids = try NSRegularExpression(pattern: #"<w:(?:ins|del) w:id="(\d+)""#).matches(in: document, range: NSRange(location: 0, length: (document as NSString).length))
            .map { (document as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertFalse(ids.contains("0"), "0 is the comment's id")
        // What Word shows once the revisions are accepted.
        let accepted = document.replacingOccurrences(of: #"<w:del\b.*?</w:del>"#, with: "", options: .regularExpression)
        XCTAssertTrue(OfficeText.paragraphs(in: Data(accepted.utf8), textElement: "w:t", paragraphElement: "w:p").contains("人不知而不愠，不亦君子乎？"))
    }

    func testEditionRules() {
        let rules = EditionRules(keywords: EditionRules.list("中华书局，上海古籍、 点校本"), formats: EditionRules.list("PDF, .epub"))
        XCTAssertEqual(rules.keywords, ["中华书局", "上海古籍", "点校本"])
        XCTAssertEqual(rules.formats, ["pdf", "epub"])
        XCTAssertEqual(rules.choose(["/书/论语译注 上海古籍.pdf", "/书/论语译注 中华书局.epub"]), "/书/论语译注 中华书局.epub", "keywords before formats")
        XCTAssertEqual(rules.choose(["/书/论语译注.epub", "/书/论语译注.pdf", "/书/论语译注.mobi"]), "/书/论语译注.pdf")
        XCTAssertEqual(rules.choose(["/书/论语译注 中華書局.epub", "/书/论语译注.epub"]), "/书/论语译注 中華書局.epub", "繁体 in the name matches")
        XCTAssertNil(rules.choose(["/书/论语译注 甲.pdf", "/书/论语译注 乙.pdf"]), "a tie is left to the reader")
        XCTAssertEqual(rules.choose(["/书/唯一.pdf"]), "/书/唯一.pdf")
    }
}
