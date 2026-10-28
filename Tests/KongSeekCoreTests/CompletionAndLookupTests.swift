import XCTest
@testable import KongSeekCore

/// 0.41: 输入时自动补全, 批量补全书目信息, 按命中次数排序.
final class CompletionAndLookupTests: XCTestCase {
    func testCompletion() {
        let candidates = ["论语 ext:pdf", "Lunyu daodu", "论语导读讲义", "孟子正义"]
        XCTAssertEqual(Autocomplete.completion(for: "论", candidates: candidates), "论语 ext:pdf", "the first that fits")
        XCTAssertEqual(Autocomplete.completion(for: "论语导", candidates: candidates), "论语导读讲义")
        XCTAssertEqual(Autocomplete.completion(for: "lun", candidates: candidates), "lunyu daodu", "what was typed is kept as typed")
        XCTAssertEqual(Autocomplete.completion(for: "論語導", candidates: candidates), "論語導读讲义", "繁简 alike")
        XCTAssertNil(Autocomplete.completion(for: "l", candidates: candidates), "one Latin letter is too little")
        XCTAssertNil(Autocomplete.completion(for: "论语 ", candidates: candidates), "not after a space")
        XCTAssertNil(Autocomplete.completion(for: "孟子正义", candidates: candidates), "nothing longer")
        XCTAssertNil(Autocomplete.completion(for: "庄子", candidates: candidates))
    }

    func testBatchLookup() {
        XCTAssertEqual(BookLookup.isbn(inName: "论语译注 -- 9787101000000 -- Anna’s Archive"), "9787101000000")
        XCTAssertNil(BookLookup.isbn(inName: "论语译注 1980"))

        let byISBN = BookLookup.Candidate(title: "Lun yu yi zhu", authors: "Yang Bojun", publisher: "Zhonghua shu ju", year: "1980", isbn: "9787101000000", source: "Open Library")
        let byTitle = BookLookup.Candidate(title: "論語譯注", authors: "杨伯峻", place: "北京", publisher: "中华书局", year: "2006", source: "Google Books")
        let other = BookLookup.Candidate(title: "论语译注新编", authors: "某某", source: "Google Books")
        XCTAssertEqual(BookLookup.confidentMatch([byTitle, byISBN], title: "论语译注", isbn: "9787101000000"), byISBN, "the same ISBN first")
        XCTAssertEqual(BookLookup.confidentMatch([other, byTitle], title: "论语译注", isbn: nil), byTitle, "the very title, 繁简 aside")
        XCTAssertNil(BookLookup.confidentMatch([other], title: "论语", isbn: nil), "a longer title is not the book")

        let current = EbookName(title: "论语译注", authors: "杨伯峻")
        let completed = BookLookup.completed(current, with: byISBN)
        XCTAssertEqual(completed.title, "论语译注", "the Chinese title kept")
        XCTAssertEqual(completed.authors, "杨伯峻", "a Chinese author is not replaced by a romanized one")
        XCTAssertEqual(completed.publisher, "Zhonghua shu ju", "what was missing is filled in")
        XCTAssertEqual(completed.year, "1980")
        XCTAssertEqual(completed.isbn, "9787101000000")
        let romanized = BookLookup.completed(EbookName(title: "Lunyu yizhu", publisher: "Zhonghua"), with: byTitle)
        XCTAssertEqual(romanized.title, "論語譯注", "a Chinese title replaces a romanized one")
        XCTAssertEqual(romanized.publisher, "中华书局")
        XCTAssertEqual(romanized.place, "北京")
    }

    func testHitCount() {
        let pages = ["天理人欲，天理之公。", "存天理，灭人欲", "天理"]
        XCTAssertEqual(HitCount.count(["天理"], in: pages), 4)
        XCTAssertEqual(HitCount.count(["天理", "人欲"], in: pages), 6)
        XCTAssertEqual(HitCount.count(["天理"], in: ["天理天理"], limit: 1), 1)
        XCTAssertEqual(HitCount.count([], in: pages), 0)
    }
}
