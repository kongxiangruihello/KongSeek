import XCTest
@testable import KongSeekCore

/// 0.43: 正文索引管理 — the books it could not read, its size on disk, and 重建.
final class BookTextManagerTests: XCTestCase {
    func testProblemsSizeAndRemoveAll() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("booktext-manage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = BookTextIndex(directory: folder)
        let now = Date()
        try index.store(path: "/书/论语.epub", size: 10, modified: now, pages: ["学而时习之", "不亦说乎"])
        index.markUnreadable(path: "/书/扫描.pdf", size: 20, modified: now, problem: "扫描件")
        index.markUnreadable(path: "/书/加密.azw3", size: 30, modified: now, problem: "DRM")
        index.markUnreadable(path: "/书/笔记.txt", size: 40, modified: now, problem: BookTextIndex.readBySpotlight)
        try index.saveManifest()

        XCTAssertEqual(index.problems.map { $0.path }, ["/书/加密.azw3", "/书/扫描.pdf"], "sorted by path; text Spotlight reads is not a problem")
        XCTAssertEqual(index.problems.map { $0.problem }, ["DRM", "扫描件"])
        XCTAssertGreaterThan(index.diskSize, 0)

        index.removeAll()
        XCTAssertTrue(index.paths.isEmpty)
        XCTAssertTrue(index.problems.isEmpty)
        XCTAssertNil(index.pages(for: "/书/论语.epub"))
        let reloaded = BookTextIndex(directory: folder)
        reloaded.load()
        XCTAssertTrue(reloaded.paths.isEmpty, "the emptied manifest is saved")
    }
}
