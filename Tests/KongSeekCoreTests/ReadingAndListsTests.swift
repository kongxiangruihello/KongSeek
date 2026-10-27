import XCTest
@testable import KongSeekCore

/// 阅读进度、保存的文件清单、废纸篓记录 (0.24).
final class ReadingAndListsTests: XCTestCase {
    func testReadingLogRecordsNewestFirst() {
        var log = ReadingLog(legacyPages: ["/书/论语.pdf": 12])
        XCTAssertEqual(log.entry(for: "/书/论语.pdf")?.progressText, "读到第 12 页")
        XCTAssertTrue(log.recent(5).isEmpty, "undated entries from before 0.24 are not 'recent'")

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(path: "/书/孟子.pdf", page: 30, pages: 300, date: day)
        log.record(path: "/书/论语.pdf", page: 45, pages: 180, date: day.addingTimeInterval(60))
        XCTAssertEqual(log.entries.map(\.path), ["/书/论语.pdf", "/书/孟子.pdf"])
        XCTAssertEqual(log.entry(for: "/书/论语.pdf")?.progressText, "读到第 45 页 / 共 180 页")
        XCTAssertEqual(log.entry(for: "/书/孟子.pdf")?.fraction ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(log.recent(5, exists: { $0.contains("孟子") }).map(\.path), ["/书/孟子.pdf"])

        log.record(path: "/书/孟子.pdf", page: 300, pages: 300, date: day.addingTimeInterval(120))
        XCTAssertEqual(log.entries.first?.progressText, "已读完（共 300 页）")
        log.record(path: "/书/x.pdf", page: 0, pages: 10)
        XCTAssertNil(log.entry(for: "/书/x.pdf"))

        let data = try! JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(ReadingLog.self, from: data), log)
    }

    func testReadingLogLimit() {
        var log = ReadingLog()
        for number in 0..<(ReadingLog.limit + 20) {
            log.record(path: "/f\(number).pdf", page: 1, pages: 2, date: Date(timeIntervalSince1970: Double(number)))
        }
        XCTAssertEqual(log.entries.count, ReadingLog.limit)
        XCTAssertEqual(log.entries.first?.path, "/f\(ReadingLog.limit + 19).pdf")
    }

    func testSavedFileLists() throws {
        var lists = SavedFileLists()
        XCTAssertNil(lists.save(name: "  ", paths: ["/a"]))
        let first = try XCTUnwrap(lists.save(name: " 本学期书单 ", paths: ["/a.pdf", "/b.epub", "/a.pdf"], date: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(first.name, "本学期书单")
        XCTAssertEqual(first.paths, ["/a.pdf", "/b.epub"])
        lists.save(name: "论文参考书", paths: ["/c.pdf"], date: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(lists.lists.map(\.name), ["论文参考书", "本学期书单"])

        // Saving under the same name replaces it, keeping its identity and creation date.
        let again = try XCTUnwrap(lists.save(name: "本学期书单", paths: ["/b.epub"], date: Date(timeIntervalSince1970: 3_000)))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.created, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(lists.lists.count, 2)
        XCTAssertEqual(lists.lists.first?.name, "本学期书单")

        let clash = lists.rename(id: again.id, to: "论文参考书")
        XCTAssertFalse(clash, "names stay unique")
        let renamed = lists.rename(id: again.id, to: "秋季书单")
        XCTAssertTrue(renamed)
        lists.move(from: "/b.epub", to: "/新/b.epub")
        XCTAssertEqual(lists.list(named: "秋季书单")?.paths, ["/新/b.epub"])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("lists.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try lists.save(to: url)
        XCTAssertEqual(SavedFileLists.load(from: url), lists)
        lists.remove(id: again.id)
        XCTAssertEqual(lists.lists.map(\.name), ["论文参考书"])
        XCTAssertEqual(SavedFileLists.load(from: url.appendingPathExtension("missing")).lists, [])
    }

    func testTrashLogPutBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("讲义/第一讲")
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("学而.pdf")
        try Data("pdf".utf8).write(to: trashed)

        var log = TrashLog()
        let entry = TrashLog.Entry(original: folder.appendingPathComponent("学而.pdf").path, trashed: trashed.path,
                                   date: Date(timeIntervalSince1970: 1_800_000_000), source: "搜索窗口", size: 3)
        log.record(entry)
        XCTAssertEqual(log.state(of: entry), .inTrash)
        XCTAssertEqual(entry.name, "学而.pdf")

        // The folder it came from was removed meanwhile: it is made again.
        guard case .success(let restored) = log.putBack(entry.id) else { return XCTFail("not put back") }
        XCTAssertNotNil(restored.restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.original))
        XCTAssertEqual(log.state(of: log.entries[0]), .restored)
        let twice = log.putBack(entry.id)
        XCTAssertEqual(twice, .failure(.notInTrash))

        // Something new with that name at the original place: not overwritten.
        let second = trash.appendingPathComponent("学而 2.pdf")
        try Data("old".utf8).write(to: second)
        let other = TrashLog.Entry(original: entry.original, trashed: second.path, source: "文件清单", size: 3)
        log.record(other)
        let occupied = log.putBack(other.id)
        XCTAssertEqual(occupied, .failure(.occupied))
        XCTAssertEqual(log.entries.map(\.id), [other.id, entry.id])

        let url = root.appendingPathComponent("trash-log.json")
        try log.save(to: url)
        XCTAssertEqual(TrashLog.load(from: url).entries.map(\.id), log.entries.map(\.id))
    }

    func testTrashLogPrune() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let old = TrashLog.Entry(original: "/a/old", trashed: "/T/old", date: now - 100 * day, source: "x", size: 1)
        let emptied = TrashLog.Entry(original: "/a/emptied", trashed: "/T/emptied", date: now - 10 * day, source: "x", size: 1)
        let waiting = TrashLog.Entry(original: "/a/waiting", trashed: "/T/waiting", date: now - 10 * day, source: "x", size: 1)
        let recentGone = TrashLog.Entry(original: "/a/recent", trashed: "/T/recent", date: now - 1 * day, source: "x", size: 1)
        var log = TrashLog(entries: [old, emptied, waiting, recentGone])
        log.prune(now: now, fileExists: { $0 == "/T/waiting" || $0 == "/T/old" })
        XCTAssertEqual(log.entries.map(\.original), ["/a/recent", "/a/waiting"])
        XCTAssertEqual(log.state(of: log.entries[0], fileExists: { _ in false }), .gone)
    }
}
