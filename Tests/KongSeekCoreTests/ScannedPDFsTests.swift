import XCTest
@testable import KongSeekCore

/// "查找扫描版 PDF" (0.16).
final class ScannedPDFsTests: XCTestCase {
    func testFoldersByPages() {
        let files = [
            ScannedPDFs.File(path: "/u/书/古籍/b.pdf", pages: 100, size: 1),
            ScannedPDFs.File(path: "/u/书/古籍/a.pdf", pages: 300, size: 1),
            ScannedPDFs.File(path: "/u/下载/x.pdf", pages: 20, size: 1),
        ]
        let folders = ScannedPDFs.folders(files)
        XCTAssertEqual(folders.map(\.path), ["/u/书/古籍", "/u/下载"])
        XCTAssertEqual(folders[0].pages, 400)
        XCTAssertEqual(folders[0].files.map(\.path), ["/u/书/古籍/a.pdf", "/u/书/古籍/b.pdf"])
    }

    func testAddingFolders() {
        XCTAssertEqual(ScannedPDFs.adding(["/u/书/古籍"], to: ["/u/书"]), ["/u/书"], "already covered")
        XCTAssertEqual(ScannedPDFs.adding(["/u/书"], to: ["/u/书/古籍", "/u/扫描"]), ["/u/扫描", "/u/书"], "child replaced")
        XCTAssertEqual(ScannedPDFs.adding(["/u/书/a", "/u/书"], to: []), ["/u/书"])
        XCTAssertEqual(ScannedPDFs.adding(["/u/书2"], to: ["/u/书"]), ["/u/书", "/u/书2"], "a sibling with a longer name is not inside")
        XCTAssertTrue(ScannedPDFs.isCovered("/u/书/古籍/a.pdf", by: ["/u/书"]))
        XCTAssertFalse(ScannedPDFs.isCovered("/u/书2/a.pdf", by: ["/u/书"]))
    }

    func testTextRule() {
        XCTAssertFalse(ScannedPDFs.hasText([]))
        XCTAssertFalse(ScannedPDFs.hasText(["", " 12 ", ""]), "page numbers only")
        XCTAssertTrue(ScannedPDFs.hasText(["子曰学而时习之不亦说乎有朋自远方来不亦乐乎人不知而不愠", "有子曰其为人也孝弟而好犯上者鲜矣不好犯上而好作乱者未之有也", ""]))
        XCTAssertTrue(ScannedPDFs.hasText(["子曰学而时习之不亦说乎有朋自远方来不亦乐乎人不知而不愠"]))
        XCTAssertFalse(ScannedPDFs.hasText(["子曰学而时习之不亦说乎有朋自远方来不亦乐乎人不知而不愠", "", "", "", ""]), "one typed page of five")
        XCTAssertFalse(ScannedPDFs.hasText(Array(repeating: "本书由某某网站收集整理仅供学习交流使用请勿商用", count: 6)), "watermark on every page")
        XCTAssertTrue(ScannedPDFs.hasText(["第一讲 导论", "孔子的生平", "论语的成书", "儒家与诸子", "仁与礼的关系"]), "slides with short titles")
    }

    func testSamplePages() {
        XCTAssertEqual(ScannedPDFs.samplePages(count: 0), [])
        XCTAssertEqual(ScannedPDFs.samplePages(count: 3), [0, 1, 2])
        XCTAssertEqual(ScannedPDFs.samplePages(count: 100), [0, 1, 2, 3, 4, 5, 6, 7, 25, 50, 75])
    }

    func testEstimate() {
        let files = [ScannedPDFs.File(path: "/a.pdf", pages: 500, size: 1), ScannedPDFs.File(path: "/b.pdf", pages: 40, size: 1)]
        XCTAssertEqual(ScannedPDFs.estimatedSeconds(files, pageLimit: 200), 360)
        XCTAssertEqual(ScannedPDFs.describe(seconds: 20), "不到 1 分钟")
        XCTAssertEqual(ScannedPDFs.describe(seconds: 360), "约 6 分钟")
        XCTAssertEqual(ScannedPDFs.describe(seconds: 12_000), "约 3 小时 20 分钟")
        XCTAssertEqual(ScannedPDFs.describe(seconds: 7200), "约 2 小时")
    }
}
