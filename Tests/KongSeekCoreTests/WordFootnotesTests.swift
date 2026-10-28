import XCTest
@testable import KongSeekCore
@testable import KongSeekText

/// 0.30: source footnotes after the quotations of a Word manuscript.
final class WordFootnotesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("footnotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private func makeDocx(_ body: String, extra: [String: String] = [:]) throws -> URL {
        let url = folder.appendingPathComponent("稿件-\(UUID().uuidString).docx")
        let zip = try ZipWriter(url: url)
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.utf8), as: "[Content_Types].xml")
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#.utf8), as: "word/_rels/document.xml.rels")
        try zip.add(Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(w)\"><w:body>\(body)</w:body></w:document>".utf8), as: "word/document.xml")
        for (name, xml) in extra { try zip.add(Data(xml.utf8), as: name) }
        try zip.finish()
        return url
    }

    private func part(_ name: String, of url: URL) throws -> String {
        let entry = try XCTUnwrap(try ZipReader.entries(at: url).first { $0.name == name })
        return String(decoding: try ZipReader.data(entry, from: url), as: UTF8.self)
    }

    private func wellFormed(_ xml: String) -> Bool { XMLParser(data: Data(xml.utf8)).parse() }

    private func text(_ xml: String) -> String {
        OfficeText.paragraphs(in: Data(xml.utf8), textElement: "w:t", paragraphElement: "w:p")
    }

    func testFootnoteAfterTheClosingMarkSplittingTheRun() throws {
        // The quotation ends inside a run, which carries bold; it also spans two runs.
        let body = #"<w:p><w:r><w:t>孔子说“学而时习之，</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">不亦说乎”，此之谓也。</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:t>又说“克己复礼为仁”。</w:t></w:r></w:p>"#
        let source = try makeDocx(body)
        let output = folder.appendingPathComponent("出.docx")
        let placement = try WordComments.write(source: source, destination: output, comments: [], footnotes: [
            .init(quote: "学而时习之，不亦说乎", text: "朱熹：《四书章句集注》，北京：中华书局，1983年，第47页。"),
            .init(quote: "克己复礼为仁", text: "杨伯峻：《论语译注》，北京：中华书局，1980年，第123页。"),
            .init(quote: "稿中没有这句", text: "x"),
        ])
        XCTAssertEqual(placement.footnotes, [true, true, false])
        XCTAssertEqual(placement.comments, [])

        let document = try part("word/document.xml", of: output)
        XCTAssertTrue(wellFormed(document))
        XCTAssertTrue(document.contains(#"<w:rPr><w:b/></w:rPr><w:t xml:space="preserve">不亦说乎”</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">，此之谓也。</w:t></w:r>"#),
                      "split after the closing mark, the second half keeps its bold")
        XCTAssertTrue(document.contains(#"克己复礼为仁”</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="2"/></w:r>"#))
        XCTAssertEqual(text(document).replacingOccurrences(of: "\n", with: ""), "孔子说“学而时习之，不亦说乎”，此之谓也。又说“克己复礼为仁”。", "the text is unchanged")

        let notes = try part("word/footnotes.xml", of: output)
        XCTAssertTrue(wellFormed(notes))
        XCTAssertTrue(notes.contains(#"w:type="separator" w:id="-1""#))
        XCTAssertTrue(notes.contains(#"<w:footnote w:id="1">"#))
        XCTAssertTrue(notes.contains("《四书章句集注》"))
        XCTAssertTrue(try part("[Content_Types].xml", of: output).contains("/word/footnotes.xml"))
        XCTAssertTrue(try part("word/_rels/document.xml.rels", of: output).contains("Target=\"footnotes.xml\""))
    }

    func testExistingFootnotesAreKeptAndNotDoubled() throws {
        let footnotes = "<w:footnotes xmlns:w=\"\(w)\"><w:footnote w:type=\"separator\" w:id=\"-1\"><w:p/></w:footnote><w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p/></w:footnote><w:footnote w:id=\"1\"><w:p><w:r><w:t>原有脚注</w:t></w:r></w:p></w:footnote></w:footnotes>"
        let styles = "<w:styles xmlns:w=\"\(w)\"><w:style w:type=\"paragraph\" w:styleId=\"a5\"><w:name w:val=\"footnote text\"/></w:style><w:style w:type=\"character\" w:styleId=\"a7\"><w:name w:val=\"footnote reference\"/></w:style></w:styles>"
        let body = #"<w:p><w:r><w:t>“学而时习之”</w:t></w:r><w:r><w:rPr><w:rStyle w:val="a7"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:t>，又“温故而知新”。</w:t></w:r></w:p>"#
        let source = try makeDocx(body, extra: ["word/footnotes.xml": footnotes, "word/styles.xml": styles])
        let output = folder.appendingPathComponent("出2.docx")
        let placement = try WordComments.write(source: source, destination: output, comments: [.init(anchor: "温故而知新", text: "核对")], footnotes: [
            .init(quote: "学而时习之", text: "已有脚注，不应再加"),
            .init(quote: "温故而知新", text: "《论语·为政》"),
        ])
        XCTAssertEqual(placement.footnotes, [false, true])
        XCTAssertEqual(placement.comments, [true])
        let document = try part("word/document.xml", of: output)
        XCTAssertTrue(wellFormed(document))
        XCTAssertTrue(document.contains(#"温故而知新”</w:t></w:r><w:r><w:rPr><w:rStyle w:val="a7"/></w:rPr><w:footnoteReference w:id="2"/></w:r>"#), "the document's own footnote style")
        let notes = try part("word/footnotes.xml", of: output)
        XCTAssertTrue(wellFormed(notes))
        XCTAssertTrue(notes.contains("原有脚注"))
        XCTAssertTrue(notes.contains(#"<w:footnote w:id="2"><w:p><w:pPr><w:pStyle w:val="a5"/></w:pPr>"#))
        XCTAssertFalse(notes.contains("不应再加"))
    }

    /// 0.31: found although spaces, punctuation and character forms differ.
    func testFootnoteFoundDespiteSmallDifferences() throws {
        let body = #"<w:p><w:r><w:t xml:space="preserve">子曰：“學而時習之， 不亦說乎？”有朋自遠方來。</w:t></w:r></w:p>"#
        let source = try makeDocx(body)
        let output = folder.appendingPathComponent("出3.docx")
        let placement = try WordComments.write(source: source, destination: output, comments: [], footnotes: [
            .init(quote: "学而时习之，不亦说乎？", text: "《论语注疏》"),
        ])
        XCTAssertEqual(placement.footnotes, [true])
        let document = try part("word/document.xml", of: output)
        XCTAssertTrue(wellFormed(document))
        XCTAssertTrue(document.contains(#"不亦說乎？”</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:t xml:space="preserve">有朋自遠方來。</w:t></w:r>"#),
                      "after the question mark and the closing quotation mark")
    }
}
