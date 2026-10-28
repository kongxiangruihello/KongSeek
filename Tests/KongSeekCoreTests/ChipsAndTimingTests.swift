import XCTest
@testable import KongSeekCore

/// 0.42: 条件标签 and 性能自检.
final class ChipsAndTimingTests: XCTestCase {
    func testChips() {
        let text = "论语 作者:杨伯峻 -草稿 ext:pdf in:\"讲义 2024\" 年:1980..1995 #在读 -作者:朱熹"
        let chips = QueryChips.chips(for: text)
        XCTAssertEqual(chips.map(\.title), ["作者：杨伯峻", "排除：草稿", "扩展名：pdf", "在：讲义 2024", "出版年：1980..1995", "标签：在读", "非 作者：朱熹"])
        XCTAssertEqual(chips[3].token, "in:\"讲义 2024\"", "a quoted value is one token")
        XCTAssertEqual(QueryChips.removing(chips[1], from: text), "论语 作者:杨伯峻 ext:pdf in:\"讲义 2024\" 年:1980..1995 #在读 -作者:朱熹")
        XCTAssertEqual(QueryChips.removing(chips[3], from: text), "论语 作者:杨伯峻 -草稿 ext:pdf 年:1980..1995 #在读 -作者:朱熹")
        XCTAssertEqual(QueryChips.chips(for: "论语 孟子"), [], "plain words are not conditions")
        XCTAssertEqual(QueryChips.chips(for: "folder: 讲义").map(\.title), ["只要文件夹"])
        XCTAssertEqual(QueryChips.chips(for: "备注:").map(\.title), ["备注"])
    }

    func testTimingLog() {
        var log = TimingLog(capacity: 3)
        XCTAssertNil(log.summary("名称搜索"))
        log.add("名称搜索", milliseconds: 10, detail: "论语")
        log.add("全文搜索", milliseconds: 900)
        log.add("名称搜索", milliseconds: 30.4, detail: "作者:杨伯峻")
        XCTAssertEqual(log.summary("名称搜索"), "最近 2 次：平均 20 ms，最慢 30 ms（作者:杨伯峻）")
        log.add("名称搜索", milliseconds: 5)
        log.add("名称搜索", milliseconds: 6)
        XCTAssertEqual(log.entries.count, 3, "only the latest are kept")
        XCTAssertNil(log.summary("全文搜索"), "the oldest dropped")
        XCTAssertEqual(log.slowest("名称搜索"), 30.4)
    }
}
