import XCTest
@testable import KongSeekCore
@testable import KongSeekText

/// 0.37: the text of EPUB and Mobipocket books, and KongSeek's own text index.
final class BookTextTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("booktext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeEPUB() throws -> URL {
        let url = folder.appendingPathComponent("论语.epub")
        let zip = try ZipWriter(url: url)
        try zip.add(Data("application/epub+zip".utf8), as: "mimetype")
        try zip.add(Data(#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8), as: "META-INF/container.xml")
        try zip.add(Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">论语</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item href="Text/ch1.xhtml" id="c1" media-type="application/xhtml+xml"/>
            <item id="c2" href="Text/ch%202.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="c2"/><itemref idref="c1"/></spine>
        </package>
        """.utf8), as: "OEBPS/content.opf")
        try zip.add(Data("<html><head><title>标题不要</title><style>p{color:red}</style></head><body><h1>第一章</h1><p>克己复礼为仁&#12290;</p><script>var x=1;</script></body></html>".utf8), as: "OEBPS/Text/ch1.xhtml")
        try zip.add(Data("<html><body><p>序&nbsp;言</p><p>学而时习之，不亦说乎？</p></body></html>".utf8), as: "OEBPS/Text/ch 2.xhtml")
        try zip.add(Data("<ncx/>".utf8), as: "OEBPS/toc.ncx")
        try zip.finish()
        return url
    }

    func testEPUB() throws {
        let url = try makeEPUB()
        let pages = try EbookText.read(url)
        XCTAssertEqual(pages, ["序 言\n学而时习之，不亦说乎？", "第一章\n克己复礼为仁。"], "in spine order; head, style and script left out")
        let read = try DocumentText.read(url)
        XCTAssertFalse(read.isPaged)
        XCTAssertTrue(read.pages[0].contains("克己复礼为仁"))
        guard case .found(let found) = ContentPreview.find(in: url, needles: ["克己复礼"]) else { return XCTFail("snippet") }
        XCTAssertTrue(found.snippet.text.contains("克己复礼为仁"))
        XCTAssertTrue(ContentPreview.canRead(url.path))

        XCTAssertEqual(EbookText.resolve("../Text/a.xhtml#p3", relativeTo: "OEBPS/Content"), "OEBPS/Text/a.xhtml")
        XCTAssertEqual(EbookText.plainText(html: "<p>A &amp; B&#x4E00;</p><br/>C"), "A & B一\nC")
    }

    func testMobipocket() throws {
        // PalmDOC: literals, a back-reference, a space pair, a literal run.
        XCTAssertEqual(EbookText.palmDOC([0x61, 0x62, 0x63, 0x80, 0x1B, 0xE1, 0x02, 0x78, 0x79]), Array("abcabcabc axy".utf8))
        // Trailing entries: a size byte (flag bit 1) and multibyte overlap (flag bit 0).
        XCTAssertEqual(EbookText.trailingSize(Array("hello".utf8) + [0x81], flags: 0b10), 1)
        XCTAssertEqual(EbookText.trailingSize(Array("abc".utf8) + [0x00], flags: 0b01), 1)
        XCTAssertEqual(EbookText.trailingSize(Array("abc".utf8) + [0x01, 0x81], flags: 0b11), 3)

        let html = Data("<html><body><p>学而时习之</p><p>A &amp; B</p></body></html>".utf8)
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        var record0 = u16(1) + u16(0) + u32(html.count) + u16(1) + u16(4096) + u16(0) + u16(0)
        record0 += Array("MOBI".utf8) + u32(232) + u32(2) + u32(65001)
        record0 += [UInt8](repeating: 0, count: 0xF4 - record0.count)
        record0[0xF2] = 0
        record0[0xF3] = 0
        var header = [UInt8](repeating: 0, count: 78)
        header.replaceSubrange(0..<4, with: Array("Test".utf8))
        header.replaceSubrange(60..<68, with: Array("BOOKMOBI".utf8))
        header.replaceSubrange(76..<78, with: u16(2))
        let start = 78 + 2 * 8 + 2
        var file = header + u32(start) + u32(0) + u32(start + record0.count) + u32(1) + [0, 0]
        file += record0 + [UInt8](html)
        XCTAssertEqual(try EbookText.mobi(Data(file)), "学而时习之\nA & B")

        var drm = file
        drm[start + 12] = 0
        drm[start + 13] = 2
        XCTAssertThrowsError(try EbookText.mobi(Data(drm))) { error in
            XCTAssertEqual(error as? EbookText.Failure, .unsupported("DRM"))
        }
        XCTAssertThrowsError(try EbookText.mobi(Data("not a book".utf8)))
        let url = folder.appendingPathComponent("学而.azw3")
        try Data(file).write(to: url)
        XCTAssertEqual(try EbookText.read(url), ["学而时习之\nA & B"])
    }

    func testOwnTextIndex() throws {
        let index = BookTextIndex(directory: folder.appendingPathComponent("BookText"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try index.store(path: "/书/论语.epub", size: 10, modified: date, pages: ["学而时习之，不亦说乎", "克己复礼为仁"])
        try index.store(path: "/书/孟子.mobi", size: 20, modified: date, pages: ["學而時習之？孟子曰仁"])
        index.markUnreadable(path: "/书/加密.azw3", size: 30, modified: date, problem: "DRM")
        index.markUnreadable(path: "/书/普通.txt", size: 40, modified: date, problem: BookTextIndex.readBySpotlight)
        XCTAssertTrue(index.isCurrent(path: "/书/论语.epub", size: 10, modified: date))
        XCTAssertFalse(index.isCurrent(path: "/书/论语.epub", size: 11, modified: date), "changed since")
        XCTAssertTrue(index.isCurrent(path: "/书/加密.azw3", size: 30, modified: date), "an unreadable book is not tried again until it changes")

        XCTAssertEqual(Set(index.search([["学而时习"]]).map(\.path)), ["/书/论语.epub", "/书/孟子.mobi"], "繁简 alike")
        XCTAssertEqual(index.search([["学而"], ["克己"]]).map(\.path), ["/书/论语.epub"], "every word")
        XCTAssertEqual(index.search([["阳明", "孟子曰"]]).map(\.path), ["/书/孟子.mobi"], "any form of a word")
        XCTAssertEqual(index.search([["学而"]], accept: { $0.contains("孟子") }).map(\.path), ["/书/孟子.mobi"])
        XCTAssertEqual(index.pages(for: "/书/论语.epub"), ["学而时习之，不亦说乎", "克己复礼为仁"])
        let summary = index.summary
        XCTAssertEqual(summary.books, 2)
        XCTAssertEqual(summary.problems, 1, "UTF-8 text read by Spotlight is not a problem")

        try index.saveManifest()
        let reloaded = BookTextIndex(directory: folder.appendingPathComponent("BookText"))
        reloaded.load()
        XCTAssertEqual(reloaded.search([["克己"]]).map(\.path), ["/书/论语.epub"])
        reloaded.prune(keeping: ["/书/孟子.mobi"])
        XCTAssertEqual(reloaded.paths, ["/书/孟子.mobi"])
        XCTAssertNil(reloaded.pages(for: "/书/论语.epub"))

        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbkData = try XCTUnwrap("学而时习之，不亦说乎".data(using: String.Encoding(rawValue: gbk)))
        XCTAssertTrue(BookTextIndex.wants("/a/b.txt") { gbkData })
        XCTAssertFalse(BookTextIndex.wants("/a/b.txt") { Data("学而时习之".utf8) }, "UTF-8 text is Spotlight's")
        XCTAssertTrue(BookTextIndex.isUTF8(Data("学而".utf8).dropLast(1)), "a character cut off at the end of a sample")
        XCTAssertTrue(BookTextIndex.wants("/a/b.EPUB") { nil })
        XCTAssertFalse(BookTextIndex.wants("/a/b.pdf") { nil })
    }
}
