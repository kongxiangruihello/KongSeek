import XCTest
@testable import KongSeekCore
@testable import KongSeekText

/// 0.28: 常用本, 补全书目信息, 全文搜不到的原因.
final class EditionsAndRecordsTests: XCTestCase {
    func testPreferredEditions() throws {
        var editions = PreferredEditions()
        let zhonghua = "/书/论语译注 杨伯峻 中华书局 1980.pdf"
        let shanggu = "/书/论语译注 杨伯峻 上海古籍 2016.pdf"
        editions.prefer(zhonghua)
        XCTAssertTrue(editions.isPreferred(zhonghua))
        XCTAssertFalse(editions.isPreferred(shanggu))
        XCTAssertEqual(editions.preferred(forBookOf: shanggu), DuplicateFinder.bookKey((shanggu as NSString).lastPathComponent) == DuplicateFinder.bookKey((zhonghua as NSString).lastPathComponent) ? zhonghua : nil)

        struct Hit { var path: String; var exact: Bool }
        let hits = [Hit(path: "/书/其他.pdf", exact: true), Hit(path: shanggu, exact: false), Hit(path: zhonghua, exact: false), Hit(path: "/书/甲.pdf", exact: true)]
        XCTAssertEqual(editions.ordered(hits, path: \.path, exact: \.exact).map(\.path), ["/书/其他.pdf", "/书/甲.pdf", zhonghua, shanggu],
                       "exact first; among the near ones the preferred edition first; otherwise as given")

        editions.move(from: zhonghua, to: "/新/论语译注 杨伯峻 中华书局 1980.pdf")
        XCTAssertTrue(editions.isPreferred("/新/论语译注 杨伯峻 中华书局 1980.pdf"))
        editions.remove("/新/论语译注 杨伯峻 中华书局 1980.pdf")
        XCTAssertTrue(editions.byBook.isEmpty)

        editions.prefer("/a/孟子正义.pdf")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try editions.save(to: url)
        XCTAssertEqual(PreferredEditions.load(from: url), editions)
    }

    func testBookRecordsFillTheReference() {
        var records = BookRecords()
        let path = "/书/Lunyu Yizhu.pdf"
        let name = EbookName(title: "论语译注")
        XCTAssertEqual(records.apply(to: name, path: path), name)
        records.set(.init(authors: "杨伯峻", place: "北京", publisher: "中华书局", year: "1980", source: "手动"), for: path)
        let filled = records.apply(to: name, path: path)
        XCTAssertEqual(filled.title, "论语译注", "an empty field keeps the file's")
        XCTAssertEqual(filled.publisher, "中华书局")
        XCTAssertEqual(Citation.make(.gbt7714, name: filled, fallbackTitle: "").missing, [])
        records.move(from: path, to: "/新/论语译注.pdf")
        XCTAssertNil(records.record(for: path))
        XCTAssertEqual(records.record(for: "/新/论语译注.pdf")?.year, "1980")
        records.remove("/新/论语译注.pdf")
        XCTAssertTrue(records.records.isEmpty)
        // BookInfo uses the records given.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("论语译注.txt")
        try? Data("x".utf8).write(to: file)
        records.set(.init(authors: "杨伯峻", publisher: "中华书局", source: "手动"), for: file.path)
        let info = BookInfo.read(file, records: records)
        XCTAssertEqual(info.name.authors, "杨伯峻")
        XCTAssertEqual(info.titleSource, "已补全的书目信息")
        XCTAssertNil(BookInfo.read(file, records: BookRecords()).name.publisher)
    }

    func testGoogleBooksAndOpenLibrary() throws {
        let google = #"{"totalItems":1,"items":[{"volumeInfo":{"title":"论语译注","subtitle":"简体字本","authors":["杨伯峻"],"publisher":"中华书局","publishedDate":"2006-12","industryIdentifiers":[{"type":"ISBN_10","identifier":"7101052002"},{"type":"ISBN_13","identifier":"9787101052003"}]}}]}"#
        let fromGoogle = BookLookup.googleBooks(Data(google.utf8))
        XCTAssertEqual(fromGoogle, [BookLookup.Candidate(title: "论语译注：简体字本", authors: "杨伯峻", publisher: "中华书局", year: "2006", isbn: "9787101052003", source: "Google Books")])
        XCTAssertEqual(fromGoogle[0].summary, "杨伯峻 · 中华书局 · 2006")
        XCTAssertEqual(BookLookup.googleBooks(Data(#"{"totalItems":0}"#.utf8)), [])

        let edition = #"{"title":"Lun yu yi zhu","publishers":["Zhonghua shu ju"],"publish_places":["Beijing"],"publish_date":"1980","by_statement":"Yang Bojun yi zhu.","isbn_13":["9787101000000"]}"#
        XCTAssertEqual(BookLookup.openLibrary(Data(edition.utf8)),
                       [BookLookup.Candidate(title: "Lun yu yi zhu", authors: "Yang Bojun yi zhu", place: "Beijing", publisher: "Zhonghua shu ju", year: "1980", isbn: "9787101000000", source: "Open Library")])
        let search = #"{"numFound":1,"docs":[{"title":"论语译注","author_name":["杨伯峻"],"publisher":["中华书局","中華書局"],"publish_year":[2009,1980],"publish_place":["北京"],"isbn":["7101000000","9787101000001"]}]}"#
        XCTAssertEqual(BookLookup.openLibrary(Data(search.utf8)).first?.year, "1980")
        XCTAssertEqual(BookLookup.openLibrary(Data(search.utf8)).first?.isbn, "9787101000001")

        XCTAssertEqual(BookLookup.year("c1980."), "1980")
        XCTAssertNil(BookLookup.year("n.d."))
        let byISBN = try XCTUnwrap(BookLookup.googleQuery(isbn: "9787101052003", title: "论语", authors: nil))
        XCTAssertTrue(byISBN.absoluteString.contains("isbn:9787101052003"))
        XCTAssertEqual(BookLookup.openLibraryQuery(isbn: "9787101052003", title: "", authors: nil)?.absoluteString, "https://openlibrary.org/isbn/9787101052003.json")
        XCTAssertNotNil(BookLookup.openLibraryQuery(isbn: nil, title: "论语译注", authors: "杨伯峻"))
    }

    func testSpotlightCoverage() {
        let files: [(path: String, isLocal: Bool)] = (0..<40).map { ("/U/书/\($0).pdf", true) } + [("/U/书/云.pdf", false), ("/U/书/图.png", true), ("/V/空/a.png", true)]
        let samples = SpotlightCoverage.samples(roots: ["/U/书", "/V/空"], files: files, perRoot: 10)
        XCTAssertEqual(samples["/U/书"]?.count, 10)
        XCTAssertFalse(samples["/U/书"]?.contains("/U/书/云.pdf") ?? true, "files only in iCloud are not checked")
        XCTAssertNil(samples["/V/空"], "no documents, nothing to check")

        XCTAssertEqual(SpotlightCoverage.indexed(mdlsOutput: "a.pdf\u{0}(null)\u{0}c.pdf\u{0}", count: 3), [true, false, true])
        XCTAssertEqual(SpotlightCoverage.indexed(mdlsOutput: "garbled", count: 2), [true, true], "unreadable output is not a finding")
        XCTAssertEqual(SpotlightCoverage.verdict([true, true, true, false]), .indexed)
        XCTAssertEqual(SpotlightCoverage.verdict([true, false, false, false]), .partly(known: 1, of: 4))
        XCTAssertEqual(SpotlightCoverage.verdict([false, false]), .notIndexed)
        XCTAssertEqual(SpotlightCoverage.indexingEnabled(mdutilOutput: "/:\n\tIndexing enabled. \n"), true)
        XCTAssertEqual(SpotlightCoverage.indexingEnabled(mdutilOutput: "/Volumes/X:\n\tIndexing disabled.\n"), false)
        XCTAssertNil(SpotlightCoverage.indexingEnabled(mdutilOutput: "Error"))
    }

    /// 0.32: 书库体检 lists the books with several editions and no 常用本.
    func testBooksWithoutAPreferredEdition() {
        var editions = PreferredEditions()
        let lunyu = ["/书/论语译注.pdf", "/书/论语译注.epub"]
        let mengzi = ["/书/孟子正义.pdf", "/书/孟子正义（繁体）.pdf"]
        XCTAssertEqual(editions.unset([lunyu, mengzi, ["/书/单本.pdf"]]), [lunyu, mengzi], "a single file needs no choice")
        editions.prefer("/书/论语译注.epub")
        XCTAssertEqual(editions.unset([lunyu, mengzi]), [mengzi])
    }
}
