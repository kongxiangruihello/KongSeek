import XCTest
@testable import KongSeekCore

/// "拷贝为参考文献" (GB/T 7714—2015, monographs) (0.17).
final class CitationTests: XCTestCase {
    private func cite(_ stem: String) -> Citation.Result {
        Citation.book(EbookName.parse(stem), fallbackTitle: stem)
    }

    func testFromAnnasArchiveName() {
        let result = cite("孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编; 成积春; 宋立林 -- Di 1 ban, 北京 Beijing, 2018 -- 北京_高等教育出版社 -- 9787040500288 -- 5ba8e6b83786f540ddc4ddbcd7cf8a88 -- Anna’s Archive")
        XCTAssertEqual(result.text, "成积春, 宋立林. 孔子与《论语》[M]. 北京: 高等教育出版社, 2018.")
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.notes, [], "the place came from the name")
        XCTAssertEqual(EbookName.parse("儒家文献研究 -- 黄怀信, 李景明主编; 黄怀信; 李景明; 曲阜师范大学 -- Kongzi wen hua lun yuan, Di 1 ban, Jinan, China, 2004 -- 济南_齐鲁书社 -- 9787533314286 -- 89b4e63c6fcabe2b4dc91003462ac0b7 -- Anna’s Arch")?.place, "济南")
    }

    func testFromZLibraryName() {
        let result = cite("古代五岳祭祀演变考论--国家社科基金后期资助项目 (中华书局) by 牛敬飞 (z-lib.org)")
        XCTAssertEqual(result.text, "牛敬飞. 古代五岳祭祀演变考论[M]. 北京: 中华书局.")
        XCTAssertEqual(result.missing, ["出版年"])
        XCTAssertEqual(result.notes, ["出版地按出版社推定为“北京”"])
        XCTAssertEqual(cite("華夏邊緣--歷史記憶與族群認同 by 王明珂 (z-lib.org)").text, "王明珂. 華夏邊緣: 歷史記憶與族群認同[M].")
        XCTAssertEqual(cite("華夏邊緣--歷史記憶與族群認同 by 王明珂 (z-lib.org)").missing, ["出版地", "出版者", "出版年"])
    }

    func testResponsibility() {
        XCTAssertEqual(Citation.book(EbookName(title: "某书", authors: "甲、乙、丙、丁主编"), fallbackTitle: "").text, "甲, 乙, 丙, 等. 某书[M].")
        XCTAssertEqual(Citation.book(EbookName(title: "某书", authors: "张三等"), fallbackTitle: "").text, "张三, 等. 某书[M].")
        let translated = Citation.book(EbookName(title: "西方文明史：问题与源头", authors: "魏嬪、杨艳等译", publisher: "东北财经大学出版社", year: "2011", place: "大连"), fallbackTitle: "")
        XCTAssertEqual(translated.text, "西方文明史: 问题与源头[M]. 魏嬪, 杨艳, 等译. 大连: 东北财经大学出版社, 2011.")
        XCTAssertEqual(translated.missing, ["原著者"])
        XCTAssertEqual(Citation.book(nil, fallbackTitle: "论语稽").text, "论语稽[M].")
    }

    func testPublisherPlaces() {
        let expected = ["上海人民出版社": "上海", "人民出版社": "北京", "上海三联书店": "上海", "生活·读书·新知三联书店": "北京",
                        "广西师范大学出版社": "桂林", "广西人民出版社": "南宁", "聯經出版事業公司": "台北", "中国社会科学出版社": "北京",
                        "浙江古籍出版社": "杭州", "香港中华书局": "香港", "河南大学出版社": "开封"]
        for (publisher, place) in expected { XCTAssertEqual(Citation.place(ofPublisher: publisher), place, publisher) }
        XCTAssertNil(Citation.place(ofPublisher: "某某出版社"))
    }

    func testEpubMetadata() {
        let container = Data("""
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        XCTAssertEqual(EpubMetadata.rootfile(inContainer: container), "OEBPS/content.opf")
        let opf = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>流金集</dc:title>
            <dc:creator opf:role="aut">程应鏐 著</dc:creator>
            <dc:publisher>上海古籍出版社</dc:publisher>
            <dc:date>2008-05-01</dc:date>
            <dc:identifier opf:scheme="ISBN">9787532550000</dc:identifier>
            <dc:language>zh</dc:language>
          </metadata>
        </package>
        """.utf8)
        let metadata = EpubMetadata.parse(opf: opf)
        XCTAssertEqual(metadata?.title, "流金集")
        XCTAssertEqual(metadata?.creators, ["程应鏐 著"])
        XCTAssertEqual(metadata?.year, "2008")
        let result = Citation.book(nil, fallbackTitle: "流金集 (z-lib)", epub: metadata)
        XCTAssertEqual(result.text, "程应鏐. 流金集[M]. 上海: 上海古籍出版社, 2008.")
        XCTAssertEqual(result.notes, ["出版地按出版社推定为“上海”"])
    }
}
