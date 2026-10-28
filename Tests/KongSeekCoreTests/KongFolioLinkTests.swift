import XCTest
@testable import KongSeekCore

/// 与 KongFolio 联动 (0.25).
final class KongFolioLinkTests: XCTestCase {
    private func reference(_ url: URL) throws -> [String: Any] {
        XCTAssertEqual(url.scheme, "kongfolio")
        XCTAssertEqual(url.host, "source")
        let value = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ref" }?.value)
        let data = try XCTUnwrap(Data(base64Encoded: value))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLinkCarriesPageAndMarks() throws {
        let url = try XCTUnwrap(KongFolioLink.url(path: "/书/论语注疏.pdf", page: 12,
                                                  rects: [.init(x: 72, y: 500, width: 120.5, height: 14), .init(x: 0, y: 0, width: 0, height: 5)],
                                                  anchor: "克己复礼"))
        let ref = try reference(url)
        XCTAssertEqual(ref["path"] as? String, "/书/论语注疏.pdf")
        XCTAssertEqual(ref["fileName"] as? String, "论语注疏.pdf")
        XCTAssertEqual(ref["page"] as? Int, 11, "KongFolio counts pages from 0")
        XCTAssertEqual(ref["keep"] as? Bool, true)
        // CGRect's Codable form; the empty rectangle is dropped, and with marks the anchor is not needed.
        let rects = try XCTUnwrap(ref["rects"] as? [[[Double]]])
        XCTAssertEqual(rects, [[[72, 500], [120.5, 14]]])
        XCTAssertNil(ref["anchor"])
    }

    func testLinkWithoutMarksUsesTheText() throws {
        let ref = try reference(try XCTUnwrap(KongFolioLink.url(path: "/a.pdf", page: 1, anchor: "学而时习之", keep: false)))
        XCTAssertEqual(ref["page"] as? Int, 0)
        XCTAssertEqual(ref["anchor"] as? String, "学而时习之")
        XCTAssertEqual((ref["rects"] as? [Any])?.count, 0, "KongFolio requires the key")
        XCTAssertNil(ref["keep"])
        XCTAssertNil(KongFolioLink.url(path: "relative.pdf", page: 1))
        XCTAssertNil(KongFolioLink.url(path: "/a.pdf", page: 0))
    }

    func testProgressFromKongFolio() {
        XCTAssertEqual(KongFolioLink.visitedCount("0-3,7,9-10"), 7)
        XCTAssertEqual(KongFolioLink.visitedCount(""), 0)
        let preferences: [String: Any] = [
            "KongFolio.progress./书/孟子.pdf": ["visited": "0-9", "last": 9, "date": 1_800_000_000.0, "pages": 400] as [String: Any],
            "KongFolio.progress./书/旧.pdf": ["visited": "0-4", "last": 4] as [String: Any],
            "KongFolio.progress./书/空.pdf": ["visited": "", "last": 0] as [String: Any],
            "KongFolio.cardsBeside": true,
        ]
        let entries = KongFolioLink.entries(from: preferences).sorted { $0.path < $1.path }
        XCTAssertEqual(entries.map(\.path), ["/书/孟子.pdf", "/书/旧.pdf"])
        XCTAssertEqual(entries[0].progressText, "读到第 10 页 / 共 400 页")
        XCTAssertEqual(entries[0].date, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(entries[1].progressText, "读到第 5 页")
        XCTAssertEqual(entries[1].date, .distantPast)
    }

    func testMergedKeepsTheNewerRecord() {
        var mine = ReadingLog()
        mine.record(path: "/a.pdf", page: 3, pages: 10, date: Date(timeIntervalSince1970: 2_000))
        mine.record(path: "/b.pdf", page: 8, pages: 10, date: Date(timeIntervalSince1970: 3_000))
        let folio = [
            ReadingLog.Entry(path: "/a.pdf", page: 7, pages: 10, date: Date(timeIntervalSince1970: 4_000)),
            ReadingLog.Entry(path: "/b.pdf", page: 2, pages: 10, date: .distantPast),
            ReadingLog.Entry(path: "/c.pdf", page: 5, pages: 0, date: .distantPast),
        ]
        let merged = mine.merged(with: folio)
        XCTAssertEqual(merged.entry(for: "/a.pdf")?.page, 7)
        XCTAssertEqual(merged.entry(for: "/b.pdf")?.page, 8)
        XCTAssertEqual(merged.entry(for: "/c.pdf")?.page, 5)
        XCTAssertEqual(merged.recent(5).map(\.path), ["/a.pdf", "/b.pdf"])
    }

    /// 0.26: 联动自检 needs KongFolio 0.34 or later.
    func testLinkedVersion() {
        XCTAssertTrue(KongFolioLink.isLinked(version: "0.34.0"))
        XCTAssertTrue(KongFolioLink.isLinked(version: "0.34"))
        XCTAssertTrue(KongFolioLink.isLinked(version: "0.40.1"))
        XCTAssertTrue(KongFolioLink.isLinked(version: "1.0"))
        XCTAssertFalse(KongFolioLink.isLinked(version: "0.33.0"))
        XCTAssertFalse(KongFolioLink.isLinked(version: "0.4"), "0.4 is older than 0.34")
    }
}
