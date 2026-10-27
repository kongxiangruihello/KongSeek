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
}
