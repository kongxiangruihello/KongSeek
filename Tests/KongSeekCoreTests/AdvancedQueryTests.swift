import XCTest
@testable import KongSeekCore

/// path:, in:, parent:, size:, dm:, regex:, file:, folder:, dupe: (0.10).
final class AdvancedQueryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    // MARK: Parsing

    func testParsing() {
        let query = SearchQuery("合同 path:讲义 in:~/Documents -in:草稿 size:>10mb dm:2024-10 regex:^第 file:", now: date("2026-10-27 12:00"), calendar: calendar)
        XCTAssertTrue(query.valid)
        XCTAssertEqual(query.words, ["合同"])
        XCTAssertEqual(query.advanced.pathTerms, ["讲义"])
        XCTAssertEqual(query.advanced.scopes.count, 2)
        XCTAssertEqual(query.advanced.scopes[0].target, .path(Paths.canonical(NSHomeDirectory() + "/Documents")))
        XCTAssertEqual(query.advanced.scopes[1].target, .folderName("草稿"))
        XCTAssertTrue(query.advanced.scopes[1].excluded)
        XCTAssertEqual(query.advanced.attributes.minimumSize, 10_000_001)
        XCTAssertEqual(query.advanced.attributes.modifiedFrom, date("2024-10-01"))
        XCTAssertEqual(query.advanced.attributes.modifiedBefore, date("2024-11-01"))
        XCTAssertEqual(query.advanced.regexes.map(\.source), ["^第"])
        XCTAssertEqual(query.advanced.kind, .files)
        XCTAssertTrue(query.hasConstraints)
        XCTAssertTrue(query.descriptions.contains("在“~/Documents”中"))
    }

    func testQuotingAndValuesWithSpaces() {
        XCTAssertEqual(SearchQuery("\"path:讲义\"").phrases, ["path:讲义"], "quoted text stays literal")
        XCTAssertTrue(SearchQuery("\"path:讲义\"").advanced.isEmpty)
        let spaced = SearchQuery("in:\"/tmp/My Folder\" 合同")
        XCTAssertEqual(spaced.words, ["合同"])
        XCTAssertEqual(spaced.advanced.scopes.first?.displayName, "/tmp/My Folder")
        XCTAssertEqual(SearchQuery("folder:讲义").words, ["讲义"])
        XCTAssertEqual(SearchQuery("folder:讲义").advanced.kind, .folders)
        XCTAssertEqual(SearchQuery("PATH：讲义").advanced.pathTerms, ["讲义"], "full-width colon, any case")
        XCTAssertEqual(SearchQuery("index:abc").words, ["index:abc"], "not an operator")
    }

    func testInvalidValues() {
        for text in ["size:abc", "dm:yesterdayish", "regex:([", "path:", "file: folder:", "-size:1mb", "dm:2024-02-30"] {
            let query = SearchQuery(text)
            XCTAssertFalse(query.valid, text)
            XCTAssertFalse(query.notes.isEmpty, text)
        }
    }

    func testSizeValues() {
        func range(_ text: String) -> [Int64?]? { AdvancedFilters.sizeRange(text).map { [$0.minimum, $0.maximum] } }
        XCTAssertEqual(range(">10mb"), [10_000_001, nil])
        XCTAssertEqual(range(">=10MB"), [10_000_000, nil])
        XCTAssertEqual(range("<=500kb"), [nil, 500_000])
        XCTAssertEqual(range("<1k"), [nil, 999])
        XCTAssertEqual(range("1mb..20mb"), [1_000_000, 20_000_000])
        XCTAssertEqual(range("1.5g"), [1_500_000_000, nil])
        XCTAssertEqual(range("empty"), [nil, 0])
        XCTAssertEqual(range("large"), [1_000_001, 16_000_000])
        XCTAssertEqual(range("10"), [10, nil])
        XCTAssertNil(range("abc"))
        XCTAssertNil(range("20mb..1mb"))
    }

    func testDateValues() {
        let now = date("2026-10-27 12:00") // a Tuesday
        func range(_ text: String) -> [Date?]? {
            AdvancedFilters.dateRange(text, now: now, calendar: calendar).map { [$0.start, $0.end] }
        }
        XCTAssertEqual(range("today"), [date("2026-10-27"), date("2026-10-28")])
        XCTAssertEqual(range("昨天"), [date("2026-10-26"), date("2026-10-27")])
        XCTAssertEqual(range("thisweek"), [date("2026-10-26"), date("2026-11-02")])
        XCTAssertEqual(range("lastmonth"), [date("2026-09-01"), date("2026-10-01")])
        XCTAssertEqual(range("7d"), [date("2026-10-20 12:00"), date("2026-10-28")])
        XCTAssertEqual(range("2024"), [date("2024-01-01"), date("2025-01-01")])
        XCTAssertEqual(range("2024/2"), [date("2024-02-01"), date("2024-03-01")])
        XCTAssertEqual(range("2024-10-05"), [date("2024-10-05"), date("2024-10-06")])
        XCTAssertEqual(range(">=2024-10-01"), [date("2024-10-01"), nil])
        XCTAssertEqual(range(">2024-10"), [date("2024-11-01"), nil])
        XCTAssertEqual(range("<2024"), [nil, date("2024-01-01")])
        XCTAssertEqual(range("<=2024"), [nil, date("2025-01-01")])
        XCTAssertEqual(range("2024-01..2024-03"), [date("2024-01-01"), date("2024-04-01")])
        XCTAssertNil(range("2024-13"))
        XCTAssertNil(range("2024-02-30"))
        XCTAssertNil(range("24-01"))
    }

    func testExternalPaths() {
        let documents = Paths.canonical(NSHomeDirectory()) + "/Documents"
        let query = SearchQuery("in:论语 -path:草稿 regex:\\.pdf$")
        XCTAssertTrue(query.advanced.acceptsPath(documents + "/论语/讲义/第一讲.pdf", isFolder: false))
        XCTAssertFalse(query.advanced.acceptsPath(documents + "/论语/草稿/第一讲.pdf", isFolder: false))
        XCTAssertFalse(query.advanced.acceptsPath(documents + "/孟子/第一讲.pdf", isFolder: false))
        XCTAssertFalse(query.advanced.acceptsPath(documents + "/论语/讲义/第一讲.docx", isFolder: false))
        XCTAssertFalse(query.advanced.acceptsPath(documents + "/论语", isFolder: true), "the folder itself is not inside")
        let parent = SearchQuery("parent:~/Documents")
        XCTAssertTrue(parent.advanced.acceptsPath(documents + "/a.txt", isFolder: false))
        XCTAssertFalse(parent.advanced.acceptsPath(documents + "/sub/a.txt", isFolder: false))
        XCTAssertFalse(SearchQuery("folder:").advanced.acceptsPath(documents + "/a.txt", isFolder: false))
    }

    // MARK: Index

    func testIndexSearch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, ["论语/讲义/第一讲.pdf", "论语/讲义/第二讲.docx", "论语/草稿/第一讲.pdf", "孟子/第一讲.pdf", "孟子/讲义/", "其他/old.txt"])
        FileManager.default.createFile(atPath: root + "/其他/big.bin", contents: Data(count: 2_000_000))
        try FileManager.default.setAttributes([.modificationDate: date("2020-05-01")], ofItemAtPath: root + "/其他/old.txt")
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        func names(_ text: String) -> [String] {
            index.search(SearchQuery(text)).map { index.path(of: $0.id) }.map { String($0.dropFirst(root.count + 1)) }.sorted()
        }

        XCTAssertEqual(names("第一讲 in:论语"), ["论语/草稿/第一讲.pdf", "论语/讲义/第一讲.pdf"])
        XCTAssertEqual(names("第一讲 in:论语 -in:草稿"), ["论语/讲义/第一讲.pdf"])
        XCTAssertEqual(names("parent:讲义"), ["论语/讲义/第一讲.pdf", "论语/讲义/第二讲.docx"])
        XCTAssertEqual(names("in:\"\(root)/孟子\""), ["孟子/第一讲.pdf", "孟子/讲义"])
        XCTAssertEqual(names("第一讲 path:草稿"), ["论语/草稿/第一讲.pdf"])
        XCTAssertEqual(names("第一讲 -path:草稿"), ["孟子/第一讲.pdf", "论语/讲义/第一讲.pdf"])
        XCTAssertEqual(names("regex:^第.讲\\.pdf$"), ["孟子/第一讲.pdf", "论语/草稿/第一讲.pdf", "论语/讲义/第一讲.pdf"])
        XCTAssertEqual(names("regex:讲义/第"), ["论语/讲义/第一讲.pdf", "论语/讲义/第二讲.docx"], "a pattern with / matches the path")
        XCTAssertEqual(names("folder: 讲义"), ["孟子/讲义", "论语/讲义"])
        XCTAssertEqual(names("file: 讲义"), [])
        XCTAssertEqual(names("size:>1mb"), ["其他/big.bin"])
        XCTAssertEqual(names("size:empty ext:pdf").count, 3)
        XCTAssertEqual(names("dm:2020"), ["其他/old.txt"])
        XCTAssertEqual(names("dm:<2021"), ["其他/old.txt"])
        XCTAssertEqual(names("old dm:today"), [])
        // dc: (0.17): creation date, which for a download is when it was downloaded.
        try FileManager.default.setAttributes([.creationDate: date("2019-03-01")], ofItemAtPath: root + "/孟子/第一讲.pdf")
        XCTAssertEqual(names("dc:2019"), ["孟子/第一讲.pdf"])
        XCTAssertEqual(names("dc:today ext:pdf"), ["论语/草稿/第一讲.pdf", "论语/讲义/第一讲.pdf"])
        XCTAssertEqual(SearchQuery("dc:7d").advanced.descriptions, ["创建（下载）时间：7d"])
        XCTAssertFalse(SearchQuery("dc:soon").valid)
        XCTAssertEqual(names("in:不存在"), [])

        let dupes = index.search(SearchQuery("dupe:")).map { String(index.path(of: $0.id).dropFirst(root.count + 1)) }
        XCTAssertEqual(dupes, ["孟子/第一讲.pdf", "论语/草稿/第一讲.pdf", "论语/讲义/第一讲.pdf"], "same names together, by path")
        XCTAssertEqual(names("dupe: ext:docx"), [])
    }

    func testRegexOverManyEntriesUsesAllCores() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeTree(root, (0..<6000).map { "f/file\($0).txt" })
        let index = NameIndex.build(roots: [root], rules: .standard(home: root))
        XCTAssertEqual(index.search(SearchQuery("regex:^file1\\d{3}\\.txt$")).count, 1000)
        XCTAssertEqual(index.search(SearchQuery("file -regex:5")).count, 6000 - (0..<6000).filter { String($0).contains("5") }.count)
    }

    private func temporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("advanced-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return Paths.canonical(path)
    }
}
