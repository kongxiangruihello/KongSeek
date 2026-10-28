import XCTest
import AppKit
import CoreText
@testable import KongSeekCore
@testable import KongSeekText

/// read_file's document reading (0.13).
final class DocumentTextTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doctext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A PDF with one page per entry: text drawn with Core Text, or (nil) only a shape, like a scan.
    private func makePDF(_ name: String, _ pages: [String?]) -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                context.textPosition = CGPoint(x: 20, y: 150)
                CTLineDraw(line, context)
            } else {
                context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testPDFPagesAndExcerpt() throws {
        let url = makePDF("lecture.pdf", ["page one alpha", "page two beta", "page three gamma"])
        let all = try DocumentText.read(url)
        XCTAssertTrue(all.isPaged)
        XCTAssertEqual(all.totalPages, 3)
        XCTAssertEqual(all.pages.count, 3)
        XCTAssertTrue(all.pages[1].contains("two beta"), all.pages[1])

        let second = try DocumentText.read(url, firstPage: 2, maximumPages: 1)
        XCTAssertEqual(second.firstPage, 2)
        XCTAssertEqual(second.pages.count, 1)
        XCTAssertTrue(second.pages[0].contains("beta"))
        let part = DocumentText.excerpt(second, maximumCharacters: 1000)
        XCTAssertTrue(part.text.hasPrefix("--- 第 2 页 ---"), part.text)
        XCTAssertEqual(part.nextPage, 3)

        // A small budget stops after the first page and says where to go on.
        let short = DocumentText.excerpt(all, maximumCharacters: 30)
        XCTAssertTrue(short.text.contains("alpha"))
        XCTAssertFalse(short.text.contains("beta"))
        XCTAssertEqual(short.nextPage, 2)
        XCTAssertNil(DocumentText.excerpt(all, maximumCharacters: 10_000).nextPage)
    }

    func testScannedPDFUsesRecognizedText() throws {
        let url = makePDF("scan.pdf", [nil, nil])
        XCTAssertThrowsError(try DocumentText.read(url)) { error in
            XCTAssertEqual(error as? DocumentText.Failure, .noText(pages: 2))
        }
        let store = OCRStore(directory: folder.appendingPathComponent("ocr"))
        try store.save(OCRRecord(path: url.path, size: 1, modified: Date(), pages: ["学而时习之", "不亦说乎"], totalPages: 2))
        let read = try DocumentText.read(url, ocr: store)
        XCTAssertEqual(read.pages, ["学而时习之", "不亦说乎"])
        XCTAssertEqual(read.recognizedPages, [1, 2])
        XCTAssertTrue(DocumentText.excerpt(read, maximumCharacters: 1000).text.contains("--- 第 1 页（识别文字） ---"))
    }

    func testTextLayer() throws {
        let typed = makePDF("typed.pdf", ["The Analects of Confucius, book one", "Learning and practising in due season", nil])
        XCTAssertEqual(DocumentText.textLayer(of: typed), DocumentText.TextLayer(hasText: true, pages: 3))
        let scan = makePDF("scan2.pdf", [nil, nil, nil, nil])
        XCTAssertEqual(DocumentText.textLayer(of: scan), DocumentText.TextLayer(hasText: false, pages: 4))
        // A typed cover on an otherwise scanned book is still a scan.
        let covered = makePDF("covered.pdf", ["Scanned and shared by some website, do not sell", nil, nil, nil, nil, nil])
        XCTAssertEqual(DocumentText.textLayer(of: covered)?.hasText, false)
        let junk = folder.appendingPathComponent("junk.pdf")
        try Data("not a pdf".utf8).write(to: junk)
        XCTAssertNil(DocumentText.textLayer(of: junk))
    }

    func testTextWordAndOffsets() throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text = folder.appendingPathComponent("旧讲稿.txt")
        try XCTUnwrap("子曰：学而时习之，不亦说乎？".data(using: gbk)).write(to: text)
        let plain = try DocumentText.read(text)
        XCTAssertFalse(plain.isPaged)
        XCTAssertEqual(plain.pages, ["子曰：学而时习之，不亦说乎？"])
        let first = DocumentText.excerpt(plain, maximumCharacters: 5)
        XCTAssertEqual(first.text, "子曰：学而")
        XCTAssertEqual(first.nextOffset, 5)
        let rest = DocumentText.excerpt(plain, offset: 5, maximumCharacters: 100)
        XCTAssertEqual(rest.text, "时习之，不亦说乎？")
        XCTAssertNil(rest.nextOffset)

        let docx = folder.appendingPathComponent("讲义.docx")
        let source = NSAttributedString(string: "有朋自远方来")
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: docx)
        XCTAssertTrue(try DocumentText.read(docx).pages[0].contains("有朋自远方来"))
    }

    func testFailures() throws {
        XCTAssertThrowsError(try DocumentText.read(folder.appendingPathComponent("missing.pdf"))) { XCTAssertEqual($0 as? DocumentText.Failure, .notFound) }
        XCTAssertThrowsError(try DocumentText.read(folder)) { XCTAssertEqual($0 as? DocumentText.Failure, .isFolder) }
        let odd = folder.appendingPathComponent("data.xyz")
        try Data([1, 2, 3]).write(to: odd)
        XCTAssertThrowsError(try DocumentText.read(odd)) { XCTAssertEqual($0 as? DocumentText.Failure, .unsupported("xyz")) }
    }

    // MARK: PowerPoint and Excel

    /// Zips `parts` (path inside the archive → XML) into `name`, as Office does.
    private func makeOffice(_ name: String, _ parts: [String: String]) throws -> URL {
        let source = folder.appendingPathComponent(name + "-parts")
        for (path, xml) in parts {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
        let output = folder.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-r", "-q", output.path, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return output
    }

    private func slide(_ paragraphs: [String]) -> String {
        let body = paragraphs.map { "<a:p><a:r><a:rPr lang=\"zh-CN\"/><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return #"<?xml version="1.0" encoding="UTF-8"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>"#
            + body + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
    }

    func testSlidesInNumberOrderWithNotes() throws {
        let notes = #"<?xml version="1.0" encoding="UTF-8"?><p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>先讲“学”字</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:txBody><a:p><a:fld type="slidenum"><a:t>1</a:t></a:fld></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"#
        let url = try makeOffice("《论语》导读.pptx", [
            "ppt/slides/slide1.xml": slide(["学而第一", "学而时习之"]),
            "ppt/slides/slide2.xml": slide(["为政第二"]),
            "ppt/slides/slide10.xml": slide(["尧曰第二十"]),
            "ppt/notesSlides/notesSlide1.xml": notes,
            "[Content_Types].xml": "<Types/>",
        ])
        let slides = try OfficeText.slides(of: url)
        XCTAssertEqual(slides, ["学而第一\n学而时习之\n【备注】先讲“学”字", "为政第二", "尧曰第二十"])

        let read = try DocumentText.read(url, firstPage: 2, maximumPages: 1)
        XCTAssertTrue(read.isPaged)
        XCTAssertEqual(read.totalPages, 3)
        XCTAssertEqual(read.pages, ["为政第二"])
        let part = DocumentText.excerpt(read, maximumCharacters: 1000)
        XCTAssertTrue(part.text.hasPrefix("--- 第 2 张幻灯片 ---"), part.text)
        XCTAssertEqual(part.nextPage, 3)

        guard case .found(let place) = ContentPreview.find(in: url, needles: ["为政"]) else { return XCTFail("not found") }
        XCTAssertEqual(place.page, 2)
    }

    func testSpreadsheetSharedStrings() throws {
        let url = try makeOffice("课表.xlsx", [
            "xl/sharedStrings.xml": #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2"><si><t>论语导读</t></si><si><r><t>星期</t></r><r><t>三</t></r></si></sst>"#,
        ])
        XCTAssertEqual(try OfficeText.spreadsheet(of: url), "论语导读\n星期三")
        XCTAssertEqual(try DocumentText.read(url).pages, ["论语导读\n星期三"])
    }

    /// 0.26: quotations in a manuscript's footnotes are checked too.
    func testWordFootnotesAndEndnotes() throws {
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let url = try makeOffice("稿件.docx", [
            "word/document.xml": "<w:document \(w)><w:body><w:p><w:r><w:t>正文</w:t></w:r></w:p></w:body></w:document>",
            "word/footnotes.xml": "<w:footnotes \(w)><w:footnote w:id=\"1\"><w:p><w:r><w:t>朱熹注：“学之为言</w:t></w:r><w:r><w:t>效也。”</w:t></w:r></w:p></w:footnote></w:footnotes>",
        ])
        let notes = try OfficeText.wordNotes(of: url)
        XCTAssertEqual(notes.footnotes, "朱熹注：“学之为言效也。”")
        XCTAssertEqual(notes.endnotes, "")
        XCTAssertEqual(ManuscriptQuotes.extract(from: notes.footnotes).map(\.text), ["学之为言效也。"])
    }
}
