import Foundation

/// Reads the long names that ebook sites give their downloads and writes short ones.
///
///     孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编; 成积春; 宋立林 -- Di 1 ban, 北京 Beijing, 2018
///         -- 北京_高等教育出版社 -- 9787040500288 -- 5ba8e6b8…ddc4ddbcd7cf8a88 -- Anna’s Archive
///     → 孔子与《论语》（成积春、宋立林主编，高等教育出版社，2018）
///
///     被遗忘的战争 --咸丰同治年间广东土客大械斗研究 by 刘平 (z-lib.org)
///     → 被遗忘的战争：咸丰同治年间广东土客大械斗研究（刘平）
///
/// Only names with a site's marks are read (Anna's Archive, Z-Library, an MD5
/// checksum, an ISBN, or "书名 by 作者"); names the user wrote ("李欧梵--上海摩登")
/// are left alone, since there is no telling title from author. Marks the user added
/// at the end ("_已读") are kept.
public struct EbookName: Equatable, Sendable {
    public var title: String
    public var authors: String?
    public var publisher: String?
    public var year: String?
    public var isbn: String?
    /// Place of publication, when the name gives it ("北京_高等教育出版社"); for citations (0.17).
    public var place: String?
    /// The user's own mark at the end, such as "_已读".
    public var mark: String = ""

    public enum Style: String, CaseIterable, Identifiable, Sendable {
        case full, titleAuthor, titleOnly, authorTitle
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .full: return "书名（作者，出版社，年份）"
            case .titleAuthor: return "书名（作者）"
            case .titleOnly: return "书名"
            case .authorTitle: return "作者《书名》"
            }
        }
    }

    public init(title: String, authors: String? = nil, publisher: String? = nil, year: String? = nil, isbn: String? = nil, mark: String = "", place: String? = nil) {
        self.title = title
        self.authors = authors
        self.publisher = publisher
        self.year = year
        self.isbn = isbn
        self.mark = mark
        self.place = place
    }

    public func formatted(_ style: Style) -> String {
        var name: String
        switch style {
        case .titleOnly:
            name = title
        case .titleAuthor:
            name = title + (authors.map { "（\($0)）" } ?? "")
        case .full:
            let details = [authors, publisher, year].compactMap { $0 }
            name = title + (details.isEmpty ? "" : "（" + details.joined(separator: "，") + "）")
        case .authorTitle:
            let shownTitle = title.hasPrefix("《") ? title : "《\(title)》"
            name = (authors ?? "") + shownTitle
        }
        // "/" and ":" are not allowed in file names.
        name = name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        return name + mark
    }

    // MARK: Reading

    /// The parts of a file name (without extension), or nil when it carries no site's marks.
    public static func parse(_ stem: String) -> EbookName? {
        let split = splitMark(stem)
        var parsed = annasArchive(split.stem) ?? zLibrary(split.stem)
        parsed?.mark = split.mark
        return parsed
    }

    /// A reading mark the user put at the end of a name ("_已读", "（已读）", " 精读") and the rest.
    public static func splitMark(_ name: String) -> (stem: String, mark: String) {
        var text = name.trimmingCharacters(in: .whitespaces)
        guard let range = text.range(of: #"[_\s]*[（(]?(已读|未读|在读|精读|重要)[)）]?$"#, options: .regularExpression) else { return (text, "") }
        var mark = String(text[range]).trimmingCharacters(in: .whitespaces)
        if !mark.hasPrefix("_") && !mark.hasPrefix("（") && !mark.hasPrefix("(") { mark = "_" + mark }
        text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (text, mark)
    }

    /// The tag a mark stands for: "_已读" → 已读.
    public static func tag(forMark mark: String) -> String? {
        ["已读", "未读", "在读", "精读", "重要"].first { mark.contains($0) }
    }

    /// "Title -- Authors -- edition, place, year -- place_Publisher -- ISBN -- md5 -- Anna’s Archive"; any part may be missing.
    static func annasArchive(_ text: String) -> EbookName? {
        let parts = text.components(separatedBy: " -- ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        var marked = false
        var isbn: String?
        var rest: [String] = []
        for (index, part) in parts.enumerated() {
            if index == 0 { continue }
            if part.lowercased().hasPrefix("anna") { marked = true; continue }
            if part.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil { marked = true; continue }
            if let found = Self.isbn(in: part) {
                marked = true
                isbn = isbn ?? found
                continue
            }
            rest.append(part)
        }
        guard marked else { return nil }
        var result = EbookName(title: cleanTitle(parts[0]))
        result.isbn = isbn
        for part in rest {
            if result.publisher == nil, isPublisher(part) {
                // "北京_高等教育出版社" → 高等教育出版社, published in 北京
                let pieces = part.components(separatedBy: "_").map { $0.trimmingCharacters(in: .whitespaces) }
                result.publisher = pieces.last
                if pieces.count > 1, let first = pieces.first, containsHan(first), first.count <= 6 { result.place = first }
            } else if let year = year(in: part), isEdition(part) {
                result.year = result.year ?? year
                // "Di 1 ban, 北京 Beijing, 2018": the Chinese place name, if any.
                if result.place == nil {
                    for piece in part.components(separatedBy: ",") {
                        let han = piece.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.map(String.init).joined()
                        if han.count >= 2 && han.count <= 6 && !piece.contains("版") {
                            result.place = han
                            break
                        }
                    }
                }
            } else if result.authors == nil {
                result.authors = cleanAuthors(part)
            }
        }
        return result.title.isEmpty ? nil : result
    }

    /// "Title--Subtitle (Publisher) by Author (z-lib.org)", "Title (Author) (Z-Library)".
    static func zLibrary(_ text: String) -> EbookName? {
        var rest = text
        var marked = false
        if let range = rest.range(of: #"\s*\((z-?lib(rary)?(\.[a-z]+)?|z-library)\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            marked = true
            rest = String(rest[..<range.lowerBound])
        }
        var authors: String?
        if let by = rest.range(of: " by ", options: .backwards) {
            marked = true
            authors = cleanAuthors(String(rest[by.upperBound...]))
            rest = String(rest[..<by.lowerBound])
        }
        guard marked else { return nil }
        var publisher: String?
        // Trailing "(…)" groups: a publisher, or (without "by") the author; web addresses dropped.
        while let range = rest.range(of: #"\s*[(（]([^()（）]*)[)）]\s*$"#, options: .regularExpression) {
            let inside = String(rest[range]).trimmingCharacters(in: CharacterSet(charactersIn: " ()（）"))
            let words = inside.split(separator: " ").filter { !$0.contains(".") }.joined(separator: " ")
            if words.isEmpty || (rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces).isEmpty { break }
            if isPublisher(words) {
                publisher = publisher ?? words.replacingOccurrences(of: "出品", with: "")
            } else if authors == nil {
                authors = cleanAuthors(words)
            } else {
                break // part of the title, like "（精）"
            }
            rest = String(rest[..<range.lowerBound])
        }
        let title = cleanTitle(rest)
        return title.isEmpty ? nil : EbookName(title: title, authors: authors, publisher: publisher)
    }

    // MARK: Pieces

    /// The title without a trailing romanization ("孔子与《论语》 Kong zi yu _ lun yu _"), with
    /// "--" between title and subtitle as "：", and series names ("…丛刊", "…项目") dropped.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if containsHan(title), let range = title.range(of: #"\s+[A-Za-z][A-Za-z0-9 _,.'’:-]*$"#, options: .regularExpression),
           containsHan(String(title[..<range.lowerBound])) {
            title = String(title[..<range.lowerBound])
        }
        // Only runs of two or more dashes separate a subtitle (a single "-" stays).
        if title.range(of: #"[-－]{2,}"#, options: .regularExpression) != nil {
            let parts = title.replacingOccurrences(of: #"\s*[-－]{2,}\s*"#, with: "\u{0}", options: .regularExpression)
                .components(separatedBy: "\u{0}")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            title = parts.enumerated().filter { $0.offset == 0 || !isSeries($0.element) }.map(\.element).joined(separator: "：")
        }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
    }

    /// "成积春,宋立林主编; 成积春; 宋立林" → "成积春、宋立林主编"; "Yang, Qun, 杨群" → "杨群".
    static func cleanAuthors(_ raw: String) -> String? {
        var text = raw.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? raw
        if containsHan(text) {
            let pieces = text.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }
            let han = pieces.filter(containsHan)
            text = (han.isEmpty ? pieces : han).joined(separator: "、")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return text.isEmpty ? nil : text
    }

    static func isbn(in text: String) -> String? {
        let digits = text.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard text.range(of: #"^[0-9Xx\-\s,;]+$"#, options: .regularExpression) != nil, digits.count >= 10 else { return nil }
        let first = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).first.map(String.init) ?? text
        let clean = first.replacingOccurrences(of: "-", with: "")
        return clean.count == 10 || clean.count == 13 ? clean : nil
    }

    static func year(in text: String) -> String? {
        guard let range = text.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func isEdition(_ text: String) -> Bool {
        text.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
            || text.range(of: #"(Di \d+ ban|第.版|版|edition|ed\.|, *(19|20)\d{2})"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isPublisher(_ text: String) -> Bool {
        text.range(of: #"(出版社|出版|书局|書局|书社|書社|印书馆|印書館|Press|Publish|University|Verlag)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isSeries(_ text: String) -> Bool {
        text.range(of: #"(丛刊|丛书|叢書|叢刊|项目|項目|系列|文库|文庫)$"#, options: .regularExpression) != nil
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }
}
