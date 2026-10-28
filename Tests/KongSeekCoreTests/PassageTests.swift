import XCTest
@testable import KongSeekCore

/// 0.32: a passage pasted into 引文查证 is checked quotation by quotation.
final class PassageTests: XCTestCase {
    func testPassageOrSingleQuotation() {
        let lecture = "孔子说：“学而时习之，不亦说乎？”又说：“三人行，必有我师焉。”可见他重视学习。"
        XCTAssertEqual(ManuscriptQuotes.inPassage(lecture).map(\.text), ["学而时习之，不亦说乎？", "三人行，必有我师焉。"])

        let oneInParagraph = "这一章讲的是修身。孟子认为“富贵不能淫，贫贱不能移，威武不能屈”，这才是大丈夫的标准，后世多引此语以自励。"
        XCTAssertEqual(ManuscriptQuotes.inPassage(oneInParagraph).map(\.text), ["富贵不能淫，贫贱不能移，威武不能屈"],
                       "one quotation with much text around it")

        XCTAssertTrue(ManuscriptQuotes.inPassage("学而时习之，不亦说乎").isEmpty, "a bare quotation is checked as it is")
        XCTAssertTrue(ManuscriptQuotes.inPassage("“学而时习之，不亦说乎？”").isEmpty, "a quotation in its marks too")
        XCTAssertTrue(ManuscriptQuotes.inPassage("子曰：“学而时习之，不亦说乎？”").isEmpty, "a short lead-in is part of the quotation")
    }
}
