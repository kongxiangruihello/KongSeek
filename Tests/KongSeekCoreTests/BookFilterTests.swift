import XCTest
@testable import KongSeekCore

/// 0.38: 作者:、出版社:、年: — books by their details.
final class BookFilterTests: XCTestCase {
    func testParsing() {
        let query = SearchQuery("论语 作者:杨伯峻 出版社:中华书局 年:1980..1995 -作者:朱熹")
        XCTAssertTrue(query.valid)
        XCTAssertEqual(query.words, ["论语"])
        let book = query.advanced.book
        XCTAssertEqual(book.authors, [.init(text: "杨伯峻", excluded: false), .init(text: "朱熹", excluded: true)])
        XCTAssertEqual(book.publishers.map(\.text), ["中华书局"])
        XCTAssertEqual(book.yearFrom, 1980)
        XCTAssertEqual(book.yearTo, 1995)
        XCTAssertTrue(query.advanced.descriptions.contains("作者不是：朱熹"))
        XCTAssertTrue(SearchQuery("author:钱穆 年份:>=2000").advanced.book.isActive)
        XCTAssertFalse(SearchQuery("年:很久以前").valid)
        XCTAssertFalse(SearchQuery("作者:").valid)
        XCTAssertFalse(SearchQuery("论语").advanced.book.isActive)

        XCTAssertEqual(BookFilter.yearRange("1980")?.from, 1980)
        XCTAssertEqual(BookFilter.yearRange("1980年")?.to, 1980)
        XCTAssertEqual(BookFilter.yearRange("1980-1990")?.to, 1990)
        XCTAssertEqual(BookFilter.yearRange(">=2000")?.from, 2000)
        XCTAssertNil(BookFilter.yearRange(">=2000")?.to)
        XCTAssertEqual(BookFilter.yearRange("<1949")?.to, 1948)
        XCTAssertNil(BookFilter.yearRange("1995..1980"))
        XCTAssertNil(BookFilter.yearRange("98"))
    }

    func testAccepts() {
        var filter = BookFilter()
        filter.authors = [.init(text: "朱子", excluded: false)]
        let aliases = SearchAliases(lines: ["朱熹=朱子=晦庵"])
        let parsed = EbookName(title: "四书章句集注", authors: "朱熹", publisher: "中华书局", year: "1983")
        XCTAssertTrue(filter.accepts(details: parsed, fileName: "四书章句集注.pdf", aliases: aliases), "by another name of the author")
        XCTAssertFalse(filter.accepts(details: parsed, fileName: "四书章句集注.pdf"), "without the alias table")
        XCTAssertTrue(filter.accepts(details: nil, fileName: "朱子语类 黎靖德编.pdf"), "no details: the file name")
        XCTAssertFalse(filter.accepts(details: EbookName(title: "朱子语类", authors: "黎靖德"), fileName: "朱子语类.pdf"),
                       "a known author is looked at, not the title")

        filter = BookFilter()
        filter.publishers = [.init(text: "中華書局", excluded: false)]
        filter.yearFrom = 1980
        filter.yearTo = 1990
        XCTAssertTrue(filter.accepts(details: parsed, fileName: "x.pdf"), "繁简 alike; the year from the details")
        XCTAssertTrue(filter.accepts(details: nil, fileName: "论语译注 杨伯峻 中华书局 1980.pdf"), "publisher and year from the name")
        XCTAssertFalse(filter.accepts(details: nil, fileName: "论语译注 杨伯峻 中华书局 2006.pdf"))
        XCTAssertFalse(filter.accepts(details: nil, fileName: "论语译注 中华书局.pdf"), "no year anywhere")
        XCTAssertTrue(filter.accepts(details: nil, fileName: "ISBN 9787101000000 中华书局 1980.pdf"), "the year, not digits inside an ISBN")
        XCTAssertFalse(filter.accepts(details: nil, fileName: "ISBN 9787101985000 中华书局.pdf"), "no year taken from inside an ISBN")

        filter = BookFilter()
        filter.authors = [.init(text: "朱熹", excluded: true)]
        XCTAssertFalse(filter.accepts(details: parsed, fileName: "x.pdf"))
        XCTAssertTrue(filter.accepts(details: EbookName(title: "论语译注", authors: "杨伯峻"), fileName: "x.pdf"))
    }
}
