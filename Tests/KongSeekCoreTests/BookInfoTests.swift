import XCTest
import CoreGraphics
@testable import KongSeekCore
@testable import KongSeekText

/// Chinese titles from a book's own metadata when the file name gives pinyin (0.19).
final class BookInfoTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bookinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func pdf(_ name: String, title: String?, author: String?) -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testPinyinTitleTakesChineseMetadata() {
        let url = pdf("Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan -- 陆学艺, 王处辉主编 ; 王处辉 -- Di 1 ban, Nanning Shi, China, 2005 -- isbn13 9787219048849 -- .pdf",
                      title: "中国社会思想史资料选辑 先秦卷", author: "Administrator")
        let info = BookInfo.read(url)
        XCTAssertTrue(info.fromFileName)
        XCTAssertEqual(info.name.title, "中国社会思想史资料选辑 先秦卷")
        XCTAssertEqual(info.name.authors, "陆学艺、王处辉主编")
        XCTAssertEqual(info.name.year, "2005")
        XCTAssertEqual(info.titleSource, "PDF 文档信息")
    }

    func testOwnChineseNameKept() {
        let url = pdf("论语稽.pdf", title: "Microsoft Word - 论语稽 卷一.doc", author: "Administrator")
        let info = BookInfo.read(url)
        XCTAssertEqual(info.name.title, "论语稽", "a Chinese file name is not replaced")
        XCTAssertNil(info.name.authors, "a Latin author field is not trusted")
        XCTAssertEqual(BookInfo.cleanPDFTitle("Microsoft Word - 论语稽 卷一.doc"), "论语稽 卷一")
    }

    func testNoMetadataWhenNotAsked() {
        let url = pdf("Lun Yu Ji -- 2005 -- 9787219048849.pdf", title: "论语稽", author: nil)
        XCTAssertEqual(BookInfo.read(url, readMetadata: false).name.title, "Lun Yu Ji")
        XCTAssertEqual(BookInfo.read(url).name.title, "论语稽")
    }
}
