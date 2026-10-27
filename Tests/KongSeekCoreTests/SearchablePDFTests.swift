import XCTest
import AppKit
import CoreText
import PDFKit
@testable import KongSeekCore
@testable import KongSeekText

/// 生成可搜索的 PDF (0.20).
final class SearchablePDFTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("searchable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A page that is only a picture of text, like a scan.
    private func scannedPDF() -> URL {
        let width = 1200, height = 800
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "KongSeek Searchable Copy",
                                                                       attributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black]))
        bitmap.textPosition = CGPoint(x: 80, y: 380)
        CTLineDraw(line, bitmap)
        let image = bitmap.makeImage()!
        let url = folder.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        // A second page with real text.
        pdf.beginPDFPage(nil)
        let typed = CTLineCreateWithAttributedString(NSAttributedString(string: "This page already has a text layer of its own.",
                                                                        attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        pdf.textPosition = CGPoint(x: 20, y: 200)
        CTLineDraw(typed, pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    func testTextLayerAdded() throws {
        let source = scannedPDF()
        let destination = SearchablePDF.destination(for: source)
        XCTAssertEqual(destination.lastPathComponent, "scan（可搜索）.pdf")
        let outcome = try SearchablePDF.make(from: source, to: destination)
        XCTAssertEqual(outcome.pages, 2)
        XCTAssertEqual(outcome.recognized, 1)
        XCTAssertEqual(outcome.alreadyText, 1)
        let made = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(made.pageCount, 2)
        let text = made.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Searchable"), text)
        XCTAssertFalse(made.findString("KongSeek", withOptions: .caseInsensitive).isEmpty)
        XCTAssertEqual(SearchablePDF.destination(for: source).lastPathComponent, "scan（可搜索 2）.pdf")
        XCTAssertThrowsError(try SearchablePDF.make(from: source, to: folder.appendingPathComponent("x.pdf"), isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("x.pdf").path))
    }
}
