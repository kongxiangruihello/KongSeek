import XCTest
@testable import KongSeekCore

/// 0.36: every hit in a file, near: / 同页:, filter buttons, merged copies.
final class RefinementsTests: XCTestCase {
    func testEveryHitInAText() {
        let text = "格物致知，见于《大学》。" + String(repeating: "其他文字。", count: 40) + "朱子以格物为穷理。" + String(repeating: "又", count: 10) + "阳明以格物为正念头。"
        let all = Snippet.findAll(in: text, needles: ["格物"], radius: 10)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[1].text.contains("朱子以格物"))
        XCTAssertEqual((all[2].text as NSString).substring(with: all[2].highlight), "格物")
        XCTAssertEqual(Snippet.findAll(in: text, needles: ["格物"], radius: 60).count, 2, "a hit inside the passage before is not repeated")
        XCTAssertEqual(Snippet.findAll(in: text, needles: ["格物"], radius: 10, limit: 2).count, 2)
        XCTAssertEqual(Snippet.findAll(in: "格物", needles: ["致知"]), [])
        XCTAssertEqual(Snippet.findAll(in: "說文解字", needles: ["说文"]).count, 1, "繁简 alike")
    }

    func testProximity() {
        let pages = ["格物" + String(repeating: "之", count: 50) + "致知", "致知在格物", "只有格物"]
        XCTAssertEqual(Proximity.firstPage(pages, words: [["格物"], ["致知"]], distance: 10), 1)
        XCTAssertEqual(Proximity.firstPage(pages, words: [["格物"], ["致知"]], distance: 60), 0)
        XCTAssertEqual(Proximity.firstPage(pages, words: [["格物"], ["致知"]], distance: nil), 0, "同页: anywhere on the page")
        XCTAssertNil(Proximity.firstPage(["格物在前页", "致知在后页"], words: [["格物"], ["致知"]], distance: nil))
        XCTAssertEqual(Proximity.firstPage(["阳明说致良知"], words: [["王守仁", "阳明"], ["良知"]], distance: 3), 0, "any form of a word")
        XCTAssertEqual(Proximity.firstPage(["格物致知"], words: [["格物"], ["致知"]], distance: 0), 0, "side by side")
        XCTAssertEqual(Proximity.firstPage(["格物 · 致知"], words: [["格物"], ["致知"]], distance: 2), nil)

        let query = SearchQuery("格物 致知 near:30 同页:")
        XCTAssertTrue(query.valid)
        XCTAssertEqual(query.words, ["格物", "致知"])
        XCTAssertEqual(query.advanced.near, 30)
        XCTAssertTrue(query.advanced.samePage)
        XCTAssertTrue(query.advanced.needsProximity)
        XCTAssertEqual(SearchQuery("相距:20字 天理").advanced.near, 20)
        XCTAssertFalse(SearchQuery("near:很近").valid)
        XCTAssertFalse(SearchQuery("near:").valid)
        XCTAssertFalse(SearchQuery("天理").advanced.needsProximity)
    }

    func testFilterFragments() {
        let fragments = FilterFragments(lines: ["PDF=ext:pdf", "书库 = in:电子书", "坏行", "=ext:x", "本学期讲义=in:论语 dm:thisyear"])
        XCTAssertEqual(fragments.lines, ["PDF=ext:pdf", "书库=in:电子书", "本学期讲义=in:论语 dm:thisyear"])
        let pdf = fragments.fragments[0], course = fragments.fragments[2]
        XCTAssertFalse(FilterFragments.isActive(pdf, in: "论语"))
        XCTAssertEqual(FilterFragments.toggled(pdf, in: "论语"), "论语 ext:pdf")
        XCTAssertTrue(FilterFragments.isActive(pdf, in: "论语 EXT:PDF"))
        XCTAssertEqual(FilterFragments.toggled(pdf, in: "论语 ext:pdf"), "论语")
        XCTAssertEqual(FilterFragments.toggled(course, in: "学而"), "学而 in:论语 dm:thisyear")
        XCTAssertEqual(FilterFragments.toggled(course, in: "学而 in:论语"), "学而 in:论语 dm:thisyear", "a part already there is not repeated")
        XCTAssertEqual(FilterFragments.toggled(course, in: "学而 in:论语 dm:thisyear"), "学而")
        XCTAssertEqual(FilterFragments.toggled(pdf, in: ""), "ext:pdf")
        for line in FilterFragments.standardLines {
            let fragment = FilterFragments(lines: [line]).fragments[0]
            XCTAssertTrue(SearchQuery(FilterFragments.toggled(fragment, in: "论语")).valid, line)
        }
    }

    func testCopyGroups() {
        let files: [(path: String, size: Int64)] = [("/a/论语.pdf", 100), ("/b/论语.pdf", 100), ("/c/别的.pdf", 100), ("/d/论语 副本.pdf", 100), ("/e/空.txt", 0), ("/f/空.txt", 0)]
        let hashes = ["/a/论语.pdf": "x", "/b/论语.pdf": "x", "/c/别的.pdf": "y", "/d/论语 副本.pdf": "x"]
        let groups = CopyGroups.group(files) { path, _ in hashes[path] }
        XCTAssertEqual(groups, ["/a/论语.pdf": ["/b/论语.pdf", "/d/论语 副本.pdf"]], "the first in order leads; empty files are not copies")

        // Real files: the same bytes, and the same size with other bytes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copies-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("1.txt"), two = folder.appendingPathComponent("2.txt"), three = folder.appendingPathComponent("3.txt")
        try? Data(repeating: 7, count: 200_000).write(to: one)
        try? Data(repeating: 7, count: 200_000).write(to: two)
        var other = Data(repeating: 7, count: 200_000)
        other[100_000] = 8
        try? other.write(to: three)
        let real = CopyGroups.group([(one.path, 200_000), (two.path, 200_000), (three.path, 200_000)], hash: CopyGroups.contentHash)
        XCTAssertEqual(real, [one.path: [two.path]], "a difference in the middle is caught by the full hash")
    }
}
