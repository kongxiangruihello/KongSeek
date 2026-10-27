import XCTest
@testable import KongSeekCore

/// 拷贝引文 and 最近下载 (0.18).
final class QuotationTests: XCTestCase {
    func testCleanJoinsChineseLines() {
        XCTAssertEqual(Quotation.clean("子曰：学而时\n习之，不亦说乎？"), "子曰：学而时习之，不亦说乎？")
        XCTAssertEqual(Quotation.clean("Learning and\n  practice"), "Learning and practice")
        XCTAssertEqual(Quotation.clean("见\nAnalects 1.1"), "见Analects 1.1", "no space next to Chinese")
    }

    func testSentence() {
        let page = "有朋自远方来，不亦乐乎？”子曰：“学而时习之，\n不亦说乎？人不知而不愠，不亦君子乎？”第二段。"
        XCTAssertEqual(Quotation.sentence(in: page, needles: ["时习"]), "子曰：“学而时习之，不亦说乎？")
        XCTAssertEqual(Quotation.sentence(in: page, needles: ["君子"]), "人不知而不愠，不亦君子乎？”")
        XCTAssertEqual(Quotation.sentence(in: "學而時習之，不亦說乎。", needles: ["学而"]), "學而時習之，不亦說乎。")
        XCTAssertNil(Quotation.sentence(in: page, needles: ["孟子"]))
        let long = String(repeating: "甲", count: 400) + "关键" + String(repeating: "乙", count: 400) + "。"
        let cut = Quotation.sentence(in: long, needles: ["关键"], limit: 100)!
        XCTAssertTrue(cut.hasPrefix("……") && cut.hasSuffix("……"), cut)
        XCTAssertEqual(cut.count, 50 + 2 + 50 + 4)
    }

    func testPageCitation() {
        XCTAssertEqual(Citation.withPage("陈登原. 国史旧闻: 第1卷[M]. 北京: 中华书局, 2000.", page: 29), "陈登原. 国史旧闻: 第1卷[M]. 北京: 中华书局, 2000: 29.")
    }

    func testRecentDownloads() throws {
        let root = Paths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["下载/新书.pdf", "下载/自己写的.docx", "旧/旧书.pdf"])
        let marked = root + "/下载/新书.pdf"
        let value = Data("bplist00".utf8)
        XCTAssertEqual(value.withUnsafeBytes { setxattr(marked, RecentDownloads.whereFromsAttribute, $0.baseAddress, value.count, 0, 0) }, 0)
        let old = root + "/旧/旧书.pdf"
        _ = value.withUnsafeBytes { setxattr(old, RecentDownloads.whereFromsAttribute, $0.baseAddress, value.count, 0, 0) }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: old)
        XCTAssertTrue(RecentDownloads.isDownloaded(marked))
        XCTAssertFalse(RecentDownloads.isDownloaded(root + "/下载/自己写的.docx"))
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        let since = Date().addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(index.recentlyCreated(since: since).map(\.name), ["新书.pdf"])
        XCTAssertEqual(Set(index.recentlyCreated(since: since, downloadedOnly: false).map(\.name)), ["新书.pdf", "自己写的.docx"])
    }
}
