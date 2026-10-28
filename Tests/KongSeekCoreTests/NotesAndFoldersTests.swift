import XCTest
@testable import KongSeekCore

/// 0.40: 文件备注 and 文件夹跳转.
final class NotesAndFoldersTests: XCTestCase {
    func testNotes() throws {
        var notes = FileNotes()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        notes.set("  讲“仁”的部分在第三章  ", for: "/书/论语译注.pdf", date: date)
        notes.set("学生论文，引文有问题", for: "/作业/张三.docx", date: date)
        XCTAssertEqual(notes.note(for: "/书/论语译注.pdf")?.text, "讲“仁”的部分在第三章", "trimmed")
        XCTAssertEqual(notes.paths(matching: ["仁"]), ["/书/论语译注.pdf"])
        XCTAssertEqual(notes.paths(matching: ["引文", "論文"]), ["/作业/张三.docx"], "every word, 繁简 alike")
        XCTAssertEqual(notes.paths(matching: []), ["/书/论语译注.pdf", "/作业/张三.docx"].sorted(), "备注: alone: every noted file")

        notes.move(from: "/书/论语译注.pdf", to: "/新/论语译注.pdf")
        XCTAssertNil(notes.note(for: "/书/论语译注.pdf"))
        XCTAssertEqual(notes.note(for: "/新/论语译注.pdf")?.date, date)
        notes.set("   ", for: "/作业/张三.docx")
        XCTAssertNil(notes.note(for: "/作业/张三.docx"), "an empty note removes it")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try notes.save(to: url)
        XCTAssertEqual(FileNotes.load(from: url), notes)

        let query = SearchQuery("论语 备注:仁")
        XCTAssertTrue(query.valid)
        XCTAssertEqual(query.words, ["论语"])
        XCTAssertEqual(query.advanced.noteTerms, ["仁"])
        XCTAssertEqual(SearchQuery("备注:").advanced.noteTerms, [])
        XCTAssertEqual(SearchQuery("备注:").advanced.descriptions, ["有备注的"])
        XCTAssertNil(SearchQuery("论语").advanced.noteTerms)
        XCTAssertFalse(SearchQuery("-备注:仁").valid)
    }

    func testFolderJump() {
        XCTAssertEqual(FolderJump.query("/讲义"), "folder: 讲义")
        XCTAssertEqual(FolderJump.query("／论语 导读"), "folder: 论语 导读")
        XCTAssertNil(FolderJump.query("/"))
        XCTAssertNil(FolderJump.query("/Users/kong/讲义"), "a real path")
        XCTAssertNil(FolderJump.query("讲义"))
        XCTAssertTrue(SearchQuery(FolderJump.query("/讲义") ?? "").valid)

        let counts = ["/讲义/论语/第一讲.pptx": 5, "/讲义/论语/第二讲.pptx": 2, "/讲义/孟子/a.pdf": 1, "/讲义论语备份/x.pdf": 9]
        XCTAssertEqual(FolderJump.affinity(of: "/讲义/论语", counts: counts), 7)
        XCTAssertEqual(FolderJump.affinity(of: "/讲义", counts: counts), 8, "not /讲义论语备份")
        XCTAssertEqual(FolderJump.affinity(of: "/其他", counts: counts), 0)
    }
}
