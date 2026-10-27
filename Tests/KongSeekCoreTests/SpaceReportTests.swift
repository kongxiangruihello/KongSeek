import XCTest
@testable import KongSeekCore

final class SpaceReportTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 1_500_000_000) // 2017
    private let recent = Date(timeIntervalSince1970: 1_790_000_000) // 2026

    private var files: [FileEntry] {
        [
            FileEntry(path: "/Users/k/教案/中华文明史.pptx", size: 736_000_000, modified: recent),
            FileEntry(path: "/Users/k/教案/备份/中华文明史.pptx", size: 2_760_000_000, modified: old),
            FileEntry(path: "/Users/k/教案/备份/《论语》导读.pptx", size: 339_000_000, modified: old),
            FileEntry(path: "/Users/k/ebook/论语稽.pdf", size: 17_000_000, modified: old, isLocal: false),
            FileEntry(path: "/Users/k/ebook/小.txt", size: 10, modified: old),
            FileEntry(path: "/Users/k/顶层.zip", size: 5_000_000, modified: recent),
        ]
    }

    func testTotalsAndLargest() {
        let totals = SpaceReport.totals(files)
        XCTAssertEqual(totals.files, 6)
        XCTAssertEqual(totals.local, 736_000_000 + 2_760_000_000 + 339_000_000 + 10 + 5_000_000)
        XCTAssertEqual(totals.cloudOnly, 17_000_000)
        XCTAssertEqual(SpaceReport.largest(files, limit: 2).map(\.size), [2_760_000_000, 736_000_000])
        XCTAssertFalse(SpaceReport.largest(files).contains { !$0.isLocal }, "iCloud-only files take no space here")
        XCTAssertTrue(SpaceReport.largest(files, localOnly: false).contains { !$0.isLocal })
    }

    func testStale() {
        let twoYearsAgo = Date(timeIntervalSince1970: 1_790_000_000 - 2 * 365 * 86_400)
        XCTAssertEqual(SpaceReport.stale(files, before: twoYearsAgo).map(\.size), [2_760_000_000, 339_000_000])
    }

    func testFolders() {
        let folders = SpaceReport.folders(files, roots: ["/Users/k"], depth: 2)
        XCTAssertEqual(folders.map(\.path), ["/Users/k/教案", "/Users/k/教案/备份", "/Users/k/ebook"], "ebook counts only its local file here")
        XCTAssertEqual(folders.last?.local, 10)
        XCTAssertEqual(folders.first?.local, 736_000_000 + 2_760_000_000 + 339_000_000)
        XCTAssertEqual(folders.first?.files, 3)
        let withCloud = SpaceReport.folders(files, roots: ["/Users/k"], depth: 1, localOnly: false)
        XCTAssertEqual(withCloud.map(\.path), ["/Users/k/教案", "/Users/k/ebook"])
        XCTAssertEqual(withCloud.last?.cloudOnly, 17_000_000)
    }
}
