import XCTest
@testable import KongSeekCore

/// 0.39: 相关文件, and passages cut for the preview.
final class RelatedFilesTests: XCTestCase {
    private func entry(_ path: String, _ day: Double) -> FileEntry {
        FileEntry(path: path, size: 100, modified: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400))
    }

    func testRelatedFiles() {
        let files = [
            entry("/书/论语译注.pdf", 0),
            entry("/书/论语译注.epub", 2),
            entry("/下载/论语译注（中华书局）.pdf", 5),
            entry("/书/孟子译注.pdf", 1),
            entry("/讲义/中华文明史 v2.pptx", 3),
            entry("/讲义/中华文明史 副本.pptx", 4),
            entry("/讲义/中华文明史.key", 1),
            entry("/讲义/中华文明史.docx", 6),
        ]
        let book = RelatedFiles.find(for: "/书/论语译注.pdf", among: files)
        XCTAssertEqual(book.editions, ["/下载/论语译注（中华书局）.pdf", "/书/论语译注.epub"], "newest first; a note in brackets is not part of the title")
        XCTAssertEqual(book.versions, [], "editions are not listed again as versions")

        let slides = RelatedFiles.find(for: "/讲义/中华文明史 v2.pptx", among: files)
        XCTAssertEqual(slides.editions, [], "not a book")
        XCTAssertEqual(slides.versions, ["/讲义/中华文明史 副本.pptx", "/讲义/中华文明史.key"], "slides of the same name, not the Word file")

        XCTAssertEqual(RelatedFiles.familyExtensions(of: "/a.pptx"), ["ppt", "pptx", "key"])
        XCTAssertEqual(RelatedFiles.familyExtensions(of: "/a.pdf"), ["pdf"])
    }

    func testTrimmedPassage() {
        let long = Snippet.findAll(in: String(repeating: "甲", count: 300) + "格物致知" + String(repeating: "乙", count: 300), needles: ["格物"], radius: 200)[0]
        let short = long.trimmed(radius: 10)
        XCTAssertEqual((short.text as NSString).substring(with: short.highlight), "格物")
        XCTAssertEqual(short.text, "…" + String(repeating: "甲", count: 10) + "格物致知" + String(repeating: "乙", count: 8) + "…")
        let whole = Snippet(text: "格物致知", highlight: NSRange(location: 0, length: 2))
        XCTAssertEqual(whole.trimmed(radius: 10), whole, "already short")
    }
}
