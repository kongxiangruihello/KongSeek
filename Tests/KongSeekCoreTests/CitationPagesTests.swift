import XCTest
@testable import KongSeekCore
@testable import KongSeekText

/// 0.27: printed page numbers, Word comments on a manuscript, 出处汇编.
final class CitationPagesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("citepages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testPrintedPages() throws {
        var numbers = PageNumbers()
        // Nothing known: the PDF page; the PDF's own label when it differs.
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 29, label: nil).text, "29")
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 29, label: "29").source, .pdf)
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 3, label: "iii").text, "iii")
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 29, label: "15").description, "第 15 页（PDF 第 29 页）")

        // The reader says PDF 29 is page 15: every page is counted from there, before the PDF's labels.
        numbers.set(path: "/书/论语.pdf", pdfPage: 29, printedPage: 15)
        XCTAssertEqual(numbers.offset(for: "/书/论语.pdf"), 14)
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 100, label: "7").text, "86")
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 100, label: nil).source, .reader)
        // Front matter, before page 1: the label, else the PDF page.
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 5, label: "v").text, "v")
        XCTAssertEqual(numbers.printed(path: "/书/论语.pdf", pdfPage: 5, label: nil).text, "5")
        XCTAssertEqual(numbers.printed(path: "/书/孟子.pdf", pdfPage: 100, label: nil).text, "100", "other books are not affected")

        numbers.move(from: "/书/论语.pdf", to: "/新/论语.pdf")
        XCTAssertNil(numbers.offset(for: "/书/论语.pdf"))
        XCTAssertEqual(numbers.offset(for: "/新/论语.pdf"), 14)
        numbers.set(path: "/新/论语.pdf", pdfPage: 10, printedPage: 10)
        XCTAssertNil(numbers.offset(for: "/新/论语.pdf"), "the same numbers need no record")

        numbers.set(path: "/a.pdf", pdfPage: 20, printedPage: 1)
        let url = folder.appendingPathComponent("page-numbers.json")
        try numbers.save(to: url)
        XCTAssertEqual(PageNumbers.load(from: url), numbers)
    }

    func testCitationWithPrintedPage() {
        let book = EbookName(title: "论语译注", authors: "杨伯峻", publisher: "中华书局", year: "1980", place: "北京")
        XCTAssertTrue(Citation.make(.gbt7714, name: book, fallbackTitle: "", page: 29, pageLabel: "15").text.hasSuffix(": 15."))
        XCTAssertTrue(Citation.make(.gbt7714, name: book, fallbackTitle: "", page: 29).text.hasSuffix(": 29."))
        XCTAssertTrue(Citation.make(.footnote, name: book, fallbackTitle: "", page: 29, pageLabel: "iii").text.hasSuffix("第iii页。"))
    }

    private func makeDocx(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("稿件.docx")
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let zip = try ZipWriter(url: url)
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.utf8), as: "[Content_Types].xml")
        try zip.add(Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#.utf8), as: "word/_rels/document.xml.rels")
        try zip.add(Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"\(w)\"><w:body>\(body)</w:body></w:document>".utf8), as: "word/document.xml")
        try zip.finish()
        return url
    }

    private func part(_ name: String, of url: URL) throws -> String {
        let entry = try XCTUnwrap(try ZipReader.entries(at: url).first { $0.name == name })
        return String(decoding: try ZipReader.data(entry, from: url), as: UTF8.self)
    }

    private func isWellFormed(_ xml: String) -> Bool {
        XMLParser(data: Data(xml.utf8)).parse()
    }

    func testWordCommentsOnTheQuotationsParagraphs() throws {
        let body = #"<w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:t>孔子说“学而时习之，</w:t></w:r><w:r><w:t xml:space="preserve">不亦悦乎”。</w:t></w:r></w:p>"#
            + #"<w:p w:rsidR="00A1"><w:r><w:t>第二段没有引文。</w:t></w:r></w:p><w:p/>"#
            + #"<w:p><w:r><w:t>又说“克己复礼为仁，一日克己，天下归仁焉”。</w:t></w:r></w:p>"#
        let source = try makeDocx(body)
        let output = folder.appendingPathComponent("稿件（引文核对）.docx")
        let placed = try WordComments.write(source: source, destination: output, comments: [
            .init(anchor: "学而时习之，不亦悦乎", text: "近似 90%：异文 1 处（悦/說）\n出处：《论语注疏》第 3 页"),
            .init(anchor: "克己复礼为仁，一日克己，天下归仁焉", text: "脱 2 字"),
            .init(anchor: "这句话稿中没有", text: "未找到"),
        ], date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(placed, [true, true, false])

        let document = try part("word/document.xml", of: output)
        XCTAssertTrue(isWellFormed(document))
        XCTAssertTrue(document.contains(#"<w:pPr><w:jc w:val="both"/></w:pPr><w:commentRangeStart w:id="0"/>"#), "properties stay first")
        XCTAssertTrue(document.contains(#"<w:commentRangeEnd w:id="1"/><w:r><w:commentReference w:id="1"/></w:r></w:p>"#))
        XCTAssertFalse(document.contains(#"w:id="2""#))
        let comments = try part("word/comments.xml", of: output)
        XCTAssertTrue(isWellFormed(comments))
        XCTAssertTrue(comments.contains("异文 1 处（悦/說）"))
        XCTAssertTrue(comments.contains("出处：《论语注疏》第 3 页"))
        XCTAssertTrue(try part("[Content_Types].xml", of: output).contains("/word/comments.xml"))
        XCTAssertTrue(try part("word/_rels/document.xml.rels", of: output).contains("Target=\"comments.xml\""))
        // The original is untouched; the copy reads as Word text.
        XCTAssertFalse(try part("word/document.xml", of: source).contains("comment"))
        XCTAssertTrue(OfficeText.paragraphs(in: Data(document.utf8), textElement: "w:t", paragraphElement: "w:p").contains("克己复礼"))
    }

    func testConcordanceAndWordReport() throws {
        let pages = ["子曰：学而时习之，不亦说乎？\n有朋自远方来，不亦乐乎？", "", "君子务本，本立而道生。孝弟也者，其为仁之本与！"]
        let hits = Concordance.occurrences(in: pages, words: ["不亦"], context: 4)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].unit, 0)
        XCTAssertEqual(hits[0].line, "…时习之，【不亦】说乎？…")
        XCTAssertEqual(hits[1].line, "…远方来，【不亦】乐乎？")
        XCTAssertEqual(Concordance.occurrences(in: pages, words: ["本"], context: 2, limit: 2).count, 2)
        XCTAssertEqual(Concordance.occurrences(in: pages, words: ["學而"]).first?.match, "学而", "繁简 alike")
        XCTAssertEqual(Concordance.words("天理 \"格物 致知\" ext:pdf -草稿"), ["天理", "格物 致知"])

        let url = folder.appendingPathComponent("出处汇编.docx")
        try DocxWriter.write([.heading("“不亦”出处汇编", level: 1),
                              .paragraph([.init("《论语》第 1 页：", bold: true), .init("时习之，"), .init("不亦", highlight: true), .init("说乎 & <注>")])], to: url)
        let document = try part("word/document.xml", of: url)
        XCTAssertTrue(isWellFormed(document))
        XCTAssertEqual(OfficeText.paragraphs(in: Data(document.utf8), textElement: "w:t", paragraphElement: "w:p").replacingOccurrences(of: "\n", with: ""),
                       "“不亦”出处汇编《论语》第 1 页：时习之，不亦说乎 & <注>")
    }
}
