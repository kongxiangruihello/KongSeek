import XCTest
@testable import KongSeekCore

/// 0.44: records that cannot be read are kept, daily backups, crash reports, hitches.
final class RecordSafetyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testUnreadableRecordIsMovedAsideNotOverwritten() throws {
        let url = folder.appendingPathComponent("file-notes.json")
        var notes = FileNotes()
        notes.set("讲“仁”的部分在第三章", for: "/书/论语.pdf")
        try notes.save(to: url)
        XCTAssertEqual(FileNotes.load(from: url).note(for: "/书/论语.pdf")?.text, "讲“仁”的部分在第三章")

        // Cut short, as by a power failure.
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count / 2).write(to: url)
        XCTAssertEqual(FileNotes.load(from: url), FileNotes(), "read as empty this time")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved aside, so a save cannot overwrite it")
        let damaged = RecordFile.damagedFiles(in: folder)
        XCTAssertEqual(damaged.count, 1)
        XCTAssertTrue(damaged[0].lastPathComponent.hasPrefix("file-notes.损坏-"))
        XCTAssertEqual(damaged[0].pathExtension, "json")
        XCTAssertEqual(try Data(contentsOf: damaged[0]), whole.prefix(whole.count / 2))

        // A missing file is simply empty, and nothing is moved.
        XCTAssertEqual(PageNumbers.load(from: folder.appendingPathComponent("page-numbers.json")), PageNumbers())
        XCTAssertEqual(RecordFile.damagedFiles(in: folder).count, 1)
    }

    func testDailyBackupKeepsNewestAndRestores() throws {
        let notes = folder.appendingPathComponent("file-notes.json")
        let books = folder.appendingPathComponent("book-records.json")
        try Data("第一版".utf8).write(to: notes)
        try Data("书目".utf8).write(to: books)
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!

        let first = try RecordBackup.backUpIfDue(from: folder, now: day1, keep: 3)
        XCTAssertEqual(first?.lastPathComponent, "2026-10-01")
        XCTAssertNil(try RecordBackup.backUpIfDue(from: folder, now: day1.addingTimeInterval(3600), keep: 3), "once a day")
        try Data("第二版".utf8).write(to: notes)
        for offset in 1...4 {
            try RecordBackup.backUpIfDue(from: folder, now: day1.addingTimeInterval(Double(offset) * 86_400), keep: 3)
        }
        let backups = RecordBackup.backups(in: folder)
        XCTAssertEqual(backups.map(\.lastPathComponent), ["2026-10-05", "2026-10-04", "2026-10-03"], "newest first, three kept")

        // Damage today's notes, then put the backup of 10-03 back.
        try Data("坏了".utf8).write(to: notes)
        let restored = try RecordBackup.restore(backups[2], into: folder, now: day1.addingTimeInterval(5 * 86_400))
        XCTAssertEqual(Set(restored), ["file-notes.json", "book-records.json"])
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "第二版")
        let before = RecordBackup.backups(in: folder).first { $0.lastPathComponent.contains("恢复前") }
        XCTAssertNotNil(before, "the records as they were are kept first")
        XCTAssertEqual(try before.map { try String(contentsOf: $0.appendingPathComponent("file-notes.json"), encoding: .utf8) }, "坏了")
    }

    func testCrashReports() {
        XCTAssertTrue(CrashReport.isAboutApp("KongSeek-2026-10-28-213015.ips"))
        XCTAssertTrue(CrashReport.isAboutApp("KongSeek_2026-10-28-213015_Mac.hang"))
        XCTAssertTrue(CrashReport.isAboutApp("KongSeek.cpu_resource-2026-10-28-213015.ips"))
        XCTAssertFalse(CrashReport.isAboutApp("KongSeekHelper-2026-10-28.ips"))
        XCTAssertFalse(CrashReport.isAboutApp("ks-2026-10-28-213015.ips"))
        XCTAssertFalse(CrashReport.isAboutApp("xctest-2026-10-28-213015.ips"))
        XCTAssertEqual(CrashReport(name: "KongSeek-2026-10-28-213015.ips", date: Date()).kind, "异常退出")
        XCTAssertEqual(CrashReport(name: "KongSeek_2026-10-28-213015_Mac.hang", date: Date()).kind, "无响应")
        XCTAssertEqual(CrashReport(name: "KongSeek.cpu_resource-2026-10-28.ips", date: Date()).kind, "CPU 占用过高")
        XCTAssertEqual(CrashReport(name: "KongSeek.diskwrites_resource-2026-10-28.ips", date: Date()).kind, "磁盘写入过多")

        let now = Date()
        let reports = [CrashReport(name: "a", date: now.addingTimeInterval(-100)), CrashReport(name: "b", date: now.addingTimeInterval(-10)),
                       CrashReport(name: "c", date: now.addingTimeInterval(-1000))]
        XCTAssertEqual(CrashReport.newer(reports, than: now.addingTimeInterval(-500)).map(\.name), ["b", "a"])
    }

    func testHitchLog() throws {
        var log = HitchLog()
        log.capacity = 3
        let now = Date()
        XCTAssertNil(log.summary(now: now))
        log.add(date: now.addingTimeInterval(-10 * 86_400), milliseconds: 9000, activity: "旧的")
        log.add(date: now.addingTimeInterval(-3600), milliseconds: 800, activity: "搜索：论语")
        log.add(date: now.addingTimeInterval(-60), milliseconds: 2400, activity: "预览：论语译注.pdf")
        let summary = try XCTUnwrap(log.summary(now: now))
        XCTAssertTrue(summary.hasPrefix("最近 7 天 2 次，最长 2.4 秒（预览：论语译注.pdf，"), summary)
        log.add(date: now, milliseconds: 600, activity: "")
        XCTAssertEqual(log.entries.count, 3, "only the latest are kept")

        let url = folder.appendingPathComponent("hitches.json")
        try log.save(to: url)
        XCTAssertEqual(HitchLog.load(from: url).entries.map(\.activity), ["搜索：论语", "预览：论语译注.pdf", ""])
    }
}
