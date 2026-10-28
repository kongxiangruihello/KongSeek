import XCTest
@testable import KongSeekCore

/// 0.29: records in the settings file, 通假字, the manuscript's reference list.
final class ArchiveAndEquivalentsTests: XCTestCase {
    func testRecordsTravelWithTheSettings() throws {
        var numbers = PageNumbers()
        numbers.set(path: "/Users/kong/书/论语.pdf", pdfPage: 29, printedPage: 15)
        // JSONEncoder writes "/" as "\/".
        let pageData = try JSONEncoder().encode(numbers)
        let lists = Data(#"{"lists":[{"name":"书单","paths":["/Users/kong/书/孟子.pdf","/Users/kongxiangrui/别人.pdf"]}]}"#.utf8)
        let archive = SettingsArchive(defaults: [:], snippets: [], records: ["page-numbers.json": pageData, "file-lists.json": lists, "other.json": Data("{}".utf8)],
                                      appVersion: "0.29.0", home: "/Users/kong")
        XCTAssertEqual(Set(archive.records.keys), ["page-numbers.json", "file-lists.json"], "only KongSeek's own records")
        let stored = String(decoding: archive.records["file-lists.json"]!, as: UTF8.self)
        XCTAssertTrue(stored.contains(#""{HOME}/书/孟子.pdf""#))
        XCTAssertTrue(stored.contains(#""/Users/kongxiangrui/别人.pdf""#), "another user's folder is not this home")

        let decoded = try SettingsArchive.decode(archive.encoded())
        let restored = decoded.restoredRecords(home: "/Users/kxr")
        let moved = try JSONDecoder().decode(PageNumbers.self, from: try XCTUnwrap(restored["page-numbers.json"]))
        XCTAssertEqual(moved.offset(for: "/Users/kxr/书/论语.pdf"), 14)
        XCTAssertTrue(String(decoding: restored["file-lists.json"]!, as: UTF8.self).contains(#""/Users/kxr/书/孟子.pdf""#))
        // Files from before 0.29 carry no records.
        XCTAssertTrue(try SettingsArchive.decode(SettingsArchive(defaults: [:], snippets: [], appVersion: "0.28.0", home: "/Users/kong").encoded()).records.isEmpty)
    }

    func testEquivalentCharactersAreNotErrors() {
        let table = CharacterEquivalents(lines: ["说=悦", "莫 暮", "说＝悦", "x", "弟悌"])
        XCTAssertTrue(table.areEquivalent("說", "悦"), "繁简 folded")
        XCTAssertTrue(table.areEquivalent("暮", "莫"))
        XCTAssertFalse(table.areEquivalent("说", "暮"))
        XCTAssertEqual(Set(table.lines), ["说=悦", "暮=莫", "弟=悌"].reduce(into: Set<String>()) { set, line in
            let parts = line.split(separator: "=").map(String.init)
            set.insert(parts[0] < parts[1] ? line : parts[1] + "=" + parts[0])
        })

        let segments = QuoteDiff.compare(quote: "学而时习之，不亦悦乎", source: "學而時習之，不亦說乎？", equivalents: table)
        XCTAssertEqual(segments, [.same("學而時習之不亦"), .equivalent(quote: "悦", source: "說"), .same("乎")])
        XCTAssertTrue(QuoteDiff.differs(segments))
        XCTAssertFalse(QuoteDiff.hasErrors(segments))
        XCTAssertEqual(QuoteDiff.summary(segments), "仅通假或古今字 1 处（悦/說），不算错")

        let both = QuoteDiff.compare(quote: "学而时习之，不亦悦乎！人不知而不温", source: "學而時習之，不亦說乎？人不知而不慍", equivalents: table)
        XCTAssertTrue(QuoteDiff.hasErrors(both))
        XCTAssertEqual(QuoteDiff.summary(both), "异文 1 处（温/慍）、另有通假或古今字 1 处（悦/說），不算错")
        // A wrong last character, with more of the source after it: still one 异字, the rest is context.
        XCTAssertEqual(QuoteDiff.compare(quote: "人不知而不温", source: "人不知而不慍，不亦君子乎？"),
                       [.same("人不知而不"), .changed(quote: "温", source: "慍")])
        XCTAssertEqual(QuoteDiff.corrected(quote: "人不知而不温", source: "人不知而不慍，不亦君子乎？"), "人不知而不慍")
        // Without a table, as before.
        XCTAssertEqual(QuoteDiff.compare(quote: "不亦悦乎", source: "不亦說乎")[1], .changed(quote: "悦", source: "說"))
        XCTAssertFalse(CharacterEquivalents.standard.isEmpty)
        XCTAssertTrue(CharacterEquivalents.standard.areEquivalent("莫", "暮"))
    }

    func testReferenceList() {
        let items = [
            ReferenceList.Item(authors: "杨伯峻", title: "论语译注", text: "杨伯峻. 论语译注[M]. 北京: 中华书局, 1980."),
            ReferenceList.Item(authors: "程树德", title: "论语集释", text: "程树德. 论语集释[M]. 北京: 中华书局, 1990."),
            ReferenceList.Item(authors: "杨伯峻", title: "论语译注", text: "杨伯峻. 论语译注[M]. 北京: 中华书局, 1980."),
            ReferenceList.Item(authors: nil, title: "《孔子家语》", text: "《孔子家语》"),
        ]
        XCTAssertEqual(ReferenceList.numbered(items), [
            "[1] 程树德. 论语集释[M]. 北京: 中华书局, 1990.",
            "[2] 《孔子家语》",
            "[3] 杨伯峻. 论语译注[M]. 北京: 中华书局, 1980.",
        ])
    }
}

/// 0.29: the 更新内容 window reads CHANGELOG items.
final class ReleaseNoteItemsTests: XCTestCase {
    func testItemsJoinWrappedLinesAndKeepSubItems() {
        let body = """
        - 书上页码：引文查证、稿件引文核对中的页码改用书上印的页码。
          - PDF 自带页码时直接用；
          - 扫描书设一次“PDF 第 29 页 = 书上第 15 页”，
            每一页都按此换算。
        - 换机与备份带上记录：设置 › 通用 › 导出设置，此后连同书上页
          码的设定一起导出；KongSeek 使用 Google Books
          and Open Library。
        - 新增 3 项测试。
        """
        let items = ReleaseNotes.items(body)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].lead, "书上页码")
        XCTAssertEqual(items[0].text, "引文查证、稿件引文核对中的页码改用书上印的页码。")
        XCTAssertEqual(items[0].children, ["PDF 自带页码时直接用；", "扫描书设一次“PDF 第 29 页 = 书上第 15 页”，每一页都按此换算。"])
        XCTAssertEqual(items[1].text, "设置 › 通用 › 导出设置，此后连同书上页码的设定一起导出；KongSeek 使用 Google Books and Open Library。")
        XCTAssertNil(items[2].lead)
        XCTAssertEqual(items[2].text, "新增 3 项测试。")
    }
}
