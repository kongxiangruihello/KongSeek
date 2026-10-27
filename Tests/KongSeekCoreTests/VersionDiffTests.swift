import XCTest
@testable import KongSeekCore

/// 两版讲义对比 and 下载整理 (0.20).
final class VersionDiffTests: XCTestCase {
    func testSlidesPairedInOrder() {
        let old = ["第一讲 导论\n孔子生平", "论语的成书\n汉代三种本子：鲁论、齐论、古论", "仁\n克己复礼为仁", "结语"]
        let new = ["第一讲 导论\n孔子生平", "新增：阅读书目\n杨伯峻《论语译注》", "论语的成书\n汉代三种本子：鲁论、齐论、古论\n张侯论", "仁\n克己复礼为仁", "结  语"]
        let changes = VersionDiff.compare(old: old, new: new)
        XCTAssertEqual(changes.map(\.kind), [.same, .added, .changed, .same, .same])
        XCTAssertEqual(changes[1].new, 2)
        XCTAssertEqual(changes[2].old, 2)
        XCTAssertEqual(changes[2].new, 3)
        XCTAssertEqual(changes[2].addedLines, ["张侯论"])
        XCTAssertEqual(changes[2].removedLines, [])
        let summary = VersionDiff.summary(changes)
        XCTAssertEqual(summary, VersionDiff.Summary(same: 3, changed: 1, added: 1, removed: 0))
    }

    func testRemovedAndRewritten() {
        let changes = VersionDiff.compare(old: ["甲乙丙丁戊己庚辛", "完全不同的一张旧幻灯片"], new: ["甲乙丙丁戊己庚壬"])
        XCTAssertEqual(changes.map(\.kind), [.changed, .removed])
        XCTAssertEqual(changes[1].removedLines, ["完全不同的一张旧幻灯片"])
        XCTAssertEqual(VersionDiff.compare(old: [], new: ["新"]).map(\.kind), [.added])
    }

    func testDownloadTidy() {
        let existing: Set<String> = ["/books/流金集（程应鏐）.pdf"]
        let plans = DownloadTidy.plan([
            "/Users/k/Downloads/流金集 -- 程应鏐 -- 8b48754b5debd66466cff2b95a574938 -- Anna’s Archive.pdf",
            "/Users/k/Downloads/被遗忘的战争 --咸丰同治年间广东土客大械斗研究 by 刘平 (z-lib.org)_已读.epub",
            "/Users/k/Downloads/自己的笔记.pdf",
        ], into: "/books", style: .titleAuthor) { existing.contains($0) }
        XCTAssertEqual(plans.map(\.newName), ["流金集（程应鏐） (2).pdf", "被遗忘的战争：咸丰同治年间广东土客大械斗研究（刘平）.epub"])
        XCTAssertEqual(plans[1].destination, "/books/被遗忘的战争：咸丰同治年间广东土客大械斗研究（刘平）.epub")
        XCTAssertEqual(plans[1].tags, ["已读"])
    }
}
