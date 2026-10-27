import Foundation

/// A book reference in the style of GB/T 7714—2015《信息与文献 参考文献著录规则》
/// for monographs (0.17):
///
///     主要责任者. 题名: 其他题名信息[M]. 其他责任者. 出版地: 出版者, 出版年.
///     成积春, 宋立林. 孔子与《论语》[M]. 北京: 高等教育出版社, 2018.
///
/// Built from what a file name (`EbookName`) and, for EPUB, the book's own metadata
/// say. Parts that are not known are left out and listed in `missing`, so the user
/// can complete them; nothing is invented except a place of publication inferred
/// from a well-known publisher, which is reported in `notes`.
public enum Citation {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Parts the reference should have but the file does not tell ("出版地", "出版年"…).
        public var missing: [String]
        /// How a part was filled in ("出版地按出版社推定").
        public var notes: [String]
    }

    /// Words for how a person is responsible ("主编", "译注"); the citation keeps
    /// translators apart and drops the others, as the standard omits "著".
    static let rolePattern = #"\s*(主编|编著|编撰|编纂|编选|编校|编|撰|著|点校|校注|校点|校释|笺注|笺|集注|集释|译注|注译|注|疏|译|口述|整理)$"#

    /// The two ways references are written (0.19).
    public enum Style: String, CaseIterable, Sendable {
        /// GB/T 7714—2015: 作者. 书名[M]. 出版地: 出版者, 年份: 页码.
        case gbt7714
        /// Footnote style common in Chinese humanities journals:
        /// 作者：《书名》，出版地：出版者，年份年，第 N 页。
        case footnote

        public var title: String {
            switch self {
            case .gbt7714: return "GB/T 7714（作者. 书名[M]. 出版地: 出版者, 年份.）"
            case .footnote: return "脚注式（作者：《书名》，出版地：出版者，年份年，第 N 页。）"
            }
        }
    }

    /// A reference in `style`, with the page cited when given.
    public static func make(_ style: Style, name: EbookName?, fallbackTitle: String, epub: EpubMetadata? = nil, page: Int? = nil) -> Result {
        switch style {
        case .gbt7714:
            var result = book(name, fallbackTitle: fallbackTitle, epub: epub)
            if let page { result.text = withPage(result.text, page: page) }
            return result
        case .footnote:
            return footnote(name, fallbackTitle: fallbackTitle, epub: epub, page: page)
        }
    }

    /// The file name's details, with gaps filled from the EPUB's own metadata.
    static func merged(_ name: EbookName?, fallbackTitle: String, epub: EpubMetadata?) -> EbookName {
        var book = name ?? EbookName(title: epub?.title ?? fallbackTitle)
        if let epub {
            if book.authors == nil, !epub.creators.isEmpty { book.authors = epub.creators.joined(separator: "、") }
            if book.publisher == nil { book.publisher = epub.publisher }
            if book.year == nil { book.year = epub.year }
        }
        return book
    }

    /// The place of publication, inferred from a well-known publisher when the name gives none.
    static func resolvedPlace(_ book: EbookName, notes: inout [String]) -> String? {
        if let place = book.place { return place }
        guard let publisher = book.publisher, let guessed = place(ofPublisher: publisher) else { return nil }
        notes.append("出版地按出版社推定为“\(guessed)”")
        return guessed
    }

    /// 成积春、宋立林主编：《孔子与〈论语〉》，北京：高等教育出版社，2018年，第23页。
    public static func footnote(_ name: EbookName?, fallbackTitle: String, epub: EpubMetadata? = nil, page: Int? = nil) -> Result {
        let book = merged(name, fallbackTitle: fallbackTitle, epub: epub)
        var missing: [String] = []
        var notes: [String] = []
        var responsibility = ""
        var translators = ""
        if let authors = book.authors {
            let (names, role) = people(authors)
            var list = names.filter { $0 != "等" }.joined(separator: "、")
            if names.contains("等") { list += "等" }
            if role == "译" {
                translators = list + "译"
            } else {
                responsibility = list + ((role == nil || role == "著" || role == "撰") ? "" : role!)
            }
        }
        if responsibility.isEmpty { missing.append(translators.isEmpty ? "责任者" : "原著者") }
        // Book-title marks inside a title become 〈〉.
        let title = book.title.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "《", with: "〈").replacingOccurrences(of: "》", with: "〉")
        let place = resolvedPlace(book, notes: &notes)
        if place == nil { missing.append("出版地") }
        if book.publisher == nil { missing.append("出版者") }
        if book.year == nil { missing.append("出版年") }
        var parts: [String] = ["《\(title)》"]
        if !translators.isEmpty { parts.append(translators) }
        if let place, let publisher = book.publisher { parts.append(place + "：" + publisher) }
        else if let publisher = book.publisher { parts.append(publisher) }
        else if let place { parts.append(place) }
        if let year = book.year { parts.append(year + "年") }
        if let page { parts.append("第\(page)页") }
        let text = (responsibility.isEmpty ? "" : responsibility + "：") + parts.joined(separator: "，") + "。"
        return Result(text: text, missing: missing, notes: notes)
    }

    public static func book(_ name: EbookName?, fallbackTitle: String, epub: EpubMetadata? = nil) -> Result {
        let book = merged(name, fallbackTitle: fallbackTitle, epub: epub)
        var missing: [String] = []
        var notes: [String] = []

        // Responsibility: "成积春、宋立林主编" → 成积春, 宋立林; more than three → first three, 等.
        var main: [String] = []
        var translators: [String] = []
        if let authors = book.authors {
            let (names, role) = people(authors)
            if role == "译" { translators = names } else { main = names }
        }
        if main.isEmpty { missing.append(translators.isEmpty ? "责任者" : "原著者") }

        var title = book.title.trimmingCharacters(in: .whitespaces)
        // Subtitle after ": " (GB/T 7714 uses the half-width colon); "/" is not in names.
        if let range = title.range(of: "：") { title.replaceSubrange(range, with: ": ") }
        title = title.replacingOccurrences(of: "／", with: "/")

        let place = resolvedPlace(book, notes: &notes)
        if place == nil { missing.append("出版地") }
        if book.publisher == nil { missing.append("出版者") }
        if book.year == nil { missing.append("出版年") }

        var text = main.isEmpty ? "" : listed(main) + ". "
        text += title + "[M]. "
        if !translators.isEmpty {
            // "陈生铮, 译." / "魏嬪, 杨艳, 等译." as in the standard's examples.
            let names = listed(translators)
            text += names + (names.hasSuffix("等") ? "译. " : ", 译. ")
        }
        var imprint = ""
        if let place, let publisher = book.publisher { imprint = place + ": " + publisher }
        else if let publisher = book.publisher { imprint = publisher }
        else if let place { imprint = place }
        if let year = book.year { imprint += imprint.isEmpty ? year : ", " + year }
        if !imprint.isEmpty { text += imprint + "." }
        return Result(text: text.trimmingCharacters(in: .whitespaces), missing: missing, notes: notes)
    }

    /// The reference with the page cited: "…, 2018." → "…, 2018: 23." (GB/T 7714: 出版年: 引文页码).
    public static func withPage(_ reference: String, page: Int) -> String {
        var text = reference
        if text.hasSuffix(".") { text.removeLast() }
        return text + ": \(page)."
    }

    /// Names and the role word at the end: "孙雪霞、陈桐生译注" → ([孙雪霞, 陈桐生], "译注").
    static func people(_ raw: String) -> (names: [String], role: String?) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var role: String?
        if let range = text.range(of: rolePattern, options: .regularExpression) {
            role = text[range].trimmingCharacters(in: .whitespaces)
            text = String(text[..<range.lowerBound])
        }
        var names = text.components(separatedBy: CharacterSet(charactersIn: "、,，;；/&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: rolePattern, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        var etAl = false
        if let last = names.last, last == "等" || last.hasSuffix("等") {
            etAl = true
            names[names.count - 1] = String(last.dropLast()).trimmingCharacters(in: .whitespaces)
            if names[names.count - 1].isEmpty { names.removeLast() }
        }
        if etAl && !names.isEmpty { names.append("等") }
        return (names, role)
    }

    /// "王明珂" / "成积春, 宋立林" / four or more: the first three, then "等".
    static func listed(_ names: [String]) -> String {
        let people = names.filter { $0 != "等" }
        let shown = Array(people.prefix(3))
        let more = people.count > 3 || names.contains("等")
        return (shown + (more ? ["等"] : [])).joined(separator: ", ")
    }

    // MARK: Places of publishers

    /// Publishers not in the city their name suggests; checked first.
    static let exceptions: [(String, String)] = [
        ("广西师范大学出版社", "桂林"), ("河南大学出版社", "开封"), ("河北大学出版社", "保定"),
        ("中国科学技术大学出版社", "合肥"), ("中国海洋大学出版社", "青岛"), ("中国矿业大学出版社", "徐州"),
    ]

    /// Names that start with a city or province: 北京大学出版社, 上海三联书店, 浙江古籍出版社 (杭州).
    static let prefixPlaces: [(String, String)] = [
        ("北京", "北京"), ("上海", "上海"), ("天津", "天津"), ("重庆", "重庆"), ("南京", "南京"), ("广州", "广州"),
        ("武汉", "武汉"), ("西安", "西安"), ("成都", "成都"), ("杭州", "杭州"), ("济南", "济南"), ("长沙", "长沙"),
        ("郑州", "郑州"), ("沈阳", "沈阳"), ("长春", "长春"), ("哈尔滨", "哈尔滨"), ("厦门", "厦门"), ("青岛", "青岛"),
        ("大连", "大连"), ("深圳", "深圳"), ("苏州", "苏州"), ("香港", "香港"), ("澳门", "澳门"), ("台北", "台北"), ("台湾", "台北"),
        ("浙江", "杭州"), ("江苏", "南京"), ("山东", "济南"), ("湖南", "长沙"), ("湖北", "武汉"), ("四川", "成都"),
        ("广东", "广州"), ("河南", "郑州"), ("河北", "石家庄"), ("陕西", "西安"), ("山西", "太原"), ("福建", "福州"),
        ("安徽", "合肥"), ("江西", "南昌"), ("辽宁", "沈阳"), ("吉林", "长春"), ("黑龙江", "哈尔滨"), ("云南", "昆明"),
        ("贵州", "贵阳"), ("甘肃", "兰州"), ("青海", "西宁"), ("广西", "南宁"), ("内蒙古", "呼和浩特"), ("新疆", "乌鲁木齐"),
        ("西藏", "拉萨"), ("宁夏", "银川"), ("海南", "海口"),
    ]

    /// Well-known publishers whose name gives no place (after the prefixes, so
    /// 上海人民出版社 is not taken for 人民出版社).
    static let knownPlaces: [(String, String)] = [
        ("中华书局", "北京"), ("商务印书馆", "北京"), ("三联书店", "北京"), ("人民出版社", "北京"),
        ("人民文学出版社", "北京"), ("社会科学文献出版社", "北京"), ("高等教育出版社", "北京"),
        ("科学出版社", "北京"), ("文物出版社", "北京"), ("中信出版", "北京"), ("东方出版社", "北京"),
        ("九州出版社", "北京"), ("线装书局", "北京"), ("国家图书馆出版社", "北京"), ("故宫出版社", "北京"),
        ("新星出版社", "北京"), ("华夏出版社", "北京"), ("民族出版社", "北京"), ("作家出版社", "北京"),
        ("清华大学出版社", "北京"), ("宗教文化出版社", "北京"), ("光明日报出版社", "北京"),
        ("复旦大学出版社", "上海"), ("华东师范大学出版社", "上海"), ("学林出版社", "上海"), ("中西书局", "上海"),
        ("东方出版中心", "上海"), ("南开大学出版社", "天津"), ("中山大学出版社", "广州"), ("花城出版社", "广州"),
        ("厦门大学出版社", "厦门"), ("华中师范大学出版社", "武汉"), ("东北师范大学出版社", "长春"), ("西南大学出版社", "重庆"),
        ("齐鲁书社", "济南"), ("岳麓书社", "长沙"), ("巴蜀书社", "成都"), ("凤凰出版社", "南京"), ("译林出版社", "南京"),
        ("三秦出版社", "西安"), ("中州古籍出版社", "郑州"), ("黄山书社", "合肥"),
        ("联经", "台北"), ("三民书局", "台北"), ("远流", "台北"), ("允晨", "台北"), ("麦田", "台北"),
    ]

    /// The usual place of publication for a publisher, when it is well known; nil otherwise.
    public static func place(ofPublisher raw: String) -> String? {
        let publisher = SearchText.simplifiedChinese(raw.trimmingCharacters(in: .whitespaces))
        if let found = exceptions.first(where: { publisher.contains($0.0) }) { return found.1 }
        if let found = prefixPlaces.first(where: { publisher.hasPrefix($0.0) }) { return found.1 }
        if let found = knownPlaces.first(where: { publisher.contains($0.0) }) { return found.1 }
        // 中国社会科学出版社, 中国人民大学出版社, 中国书店…
        if publisher.hasPrefix("中国") || publisher.hasPrefix("中央") { return "北京" }
        return nil
    }
}

/// Title, creators, publisher and date from an EPUB's package document (OPF).
public struct EpubMetadata: Equatable, Sendable {
    public var title: String?
    public var creators: [String] = []
    public var publisher: String?
    public var date: String?
    public var identifiers: [String] = []

    public var year: String? { date.flatMap { EbookName.year(in: $0) } }

    /// Reads META-INF/container.xml, then the package document it names. Nil when
    /// the file is not a readable EPUB.
    public static func read(_ url: URL) -> EpubMetadata? {
        guard let entries = try? ZipReader.entries(at: url, limit: 20_000),
              let container = entries.first(where: { $0.name == "META-INF/container.xml" }),
              let containerData = try? ZipReader.data(container, from: url, maximumSize: 1_000_000),
              let opfPath = rootfile(inContainer: containerData),
              let opf = entries.first(where: { $0.name == opfPath }),
              let opfData = try? ZipReader.data(opf, from: url, maximumSize: 10_000_000) else { return nil }
        return parse(opf: opfData)
    }

    static func rootfile(inContainer data: Data) -> String? {
        let collector = XMLCollector(wanted: [])
        collector.parse(data)
        return collector.rootfile
    }

    static func parse(opf data: Data) -> EpubMetadata? {
        let collector = XMLCollector(wanted: ["title", "creator", "publisher", "date", "identifier"])
        guard collector.parse(data) else { return nil }
        func clean(_ value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Placeholders some converters write.
            return text.isEmpty || ["unknown", "未知"].contains(text.lowercased()) ? nil : text
        }
        var metadata = EpubMetadata()
        metadata.title = collector.values["title"]?.compactMap(clean).first
        metadata.creators = collector.values["creator"]?.compactMap(clean) ?? []
        metadata.publisher = collector.values["publisher"]?.compactMap(clean).first
        metadata.date = collector.values["date"]?.compactMap(clean).first
        metadata.identifiers = collector.values["identifier"]?.compactMap(clean) ?? []
        return metadata
    }
}

/// Collects the text of some elements (by local name, ignoring namespaces) and the
/// container's rootfile path.
private final class XMLCollector: NSObject, XMLParserDelegate {
    let wanted: Set<String>
    var values: [String: [String]] = [:]
    var rootfile: String?
    private var current: String?
    private var buffer = ""

    init(wanted: Set<String>) {
        self.wanted = wanted
    }

    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "rootfile", rootfile == nil, let path = attributes["full-path"] { rootfile = path }
        if wanted.contains(name) {
            current = name
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == current {
            values[name, default: []].append(buffer)
            current = nil
        }
    }
}
