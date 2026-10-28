import Foundation

/// A plain Word (.docx) document (0.27): headings and paragraphs whose runs may be bold
/// or highlighted — enough for 出处汇编 and reports, opened by Word, Pages and WPS.
public enum DocxWriter {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold: Bool
        public var highlight: Bool
        public var gray: Bool

        public init(_ text: String, bold: Bool = false, highlight: Bool = false, gray: Bool = false) {
            self.text = text
            self.bold = bold
            self.highlight = highlight
            self.gray = gray
        }
    }

    public enum Block: Equatable, Sendable {
        case heading(String, level: Int)
        case paragraph([Run])
    }

    public static func write(_ blocks: [Block], to url: URL) throws {
        let body = blocks.map(xml).joined()
        let document = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
            + body
            + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>"#
        let types = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#
        let rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#
        try? FileManager.default.removeItem(at: url)
        let zip = try ZipWriter(url: url)
        try zip.add(Data(types.utf8), as: "[Content_Types].xml")
        try zip.add(Data(rels.utf8), as: "_rels/.rels")
        try zip.add(Data(document.utf8), as: "word/document.xml")
        try zip.finish()
    }

    private static func xml(_ block: Block) -> String {
        switch block {
        case .heading(let text, let level):
            let size = level <= 1 ? 32 : (level == 2 ? 28 : 24)
            return "<w:p><w:pPr><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr>" + run(Run(text, bold: true), size: size) + "</w:p>"
        case .paragraph(let runs):
            return "<w:p><w:pPr><w:spacing w:after=\"80\"/></w:pPr>" + runs.map { run($0, size: nil) }.joined() + "</w:p>"
        }
    }

    private static func run(_ run: Run, size: Int?) -> String {
        var properties = ""
        if run.bold { properties += "<w:b/>" }
        if run.gray { properties += "<w:color w:val=\"808080\"/>" }
        if let size { properties += "<w:sz w:val=\"\(size)\"/>" }
        if run.highlight { properties += "<w:highlight w:val=\"yellow\"/>" }
        let lines = run.text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">\(XLSXWriter.escape($0))</w:t>" }
        return "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + lines.joined(separator: "<w:br/>") + "</w:r>"
    }
}

/// Word comments on a copy of a manuscript (0.27, 稿件引文核对): each quotation that
/// differs from its source, or was not found, gets a comment in the margin on the
/// paragraph it stands in. The original document is not changed.
public enum WordComments {
    public struct Comment: Equatable, Sendable {
        /// The quotation, to find its paragraph.
        public var anchor: String
        public var text: String

        public init(anchor: String, text: String) {
            self.anchor = anchor
            self.text = text
        }
    }

    public enum Failure: Error, Equatable {
        case notWord
    }

    static let main = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// Writes `source` with the comments to `destination`; returns, per comment, whether
    /// its paragraph was found in the body (those in footnotes or not found get none).
    @discardableResult
    public static func write(source: URL, destination: URL, comments: [Comment], author: String = "KongSeek", date: Date = Date()) throws -> [Bool] {
        let entries = try ZipReader.entries(at: source)
        var parts: [(name: String, data: Data)] = []
        for entry in entries where !entry.isDirectory {
            parts.append((entry.name, try ZipReader.data(entry, from: source, maximumSize: 200_000_000)))
        }
        guard let documentIndex = parts.firstIndex(where: { $0.name == "word/document.xml" }),
              let document = String(data: parts[documentIndex].data, encoding: .utf8) else { throw Failure.notWord }
        let existingIndex = parts.firstIndex { $0.name == "word/comments.xml" }
        let existing = existingIndex.flatMap { String(data: parts[$0].data, encoding: .utf8) }
        let firstID = (existing.map { maximumID(in: $0) } ?? -1) + 1
        let annotated = annotate(document: document, comments: comments, firstID: firstID)
        parts[documentIndex].data = Data(annotated.document.utf8)

        let stamp = ISO8601DateFormatter().string(from: date)
        var added = ""
        for (offset, comment) in comments.enumerated() where annotated.placed[offset] {
            let paragraphs = comment.text.components(separatedBy: "\n").map {
                "<w:p><w:r><w:t xml:space=\"preserve\">\(XLSXWriter.escape($0))</w:t></w:r></w:p>"
            }.joined()
            added += "<w:comment w:id=\"\(firstID + offset)\" w:author=\"\(XLSXWriter.escape(author))\" w:date=\"\(stamp)\" w:initials=\"KS\">\(paragraphs)</w:comment>"
        }
        if let existingIndex, let existing, let close = existing.range(of: "</w:comments>", options: .backwards) {
            var merged = existing
            merged.insert(contentsOf: added, at: close.lowerBound)
            parts[existingIndex].data = Data(merged.utf8)
        } else {
            let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "<w:comments xmlns:w=\"\(main)\">" + added + "</w:comments>"
            parts.append(("word/comments.xml", Data(xml.utf8)))
            if let index = parts.firstIndex(where: { $0.name == "word/_rels/document.xml.rels" }),
               var rels = String(data: parts[index].data, encoding: .utf8), let close = rels.range(of: "</Relationships>", options: .backwards) {
                rels.insert(contentsOf: #"<Relationship Id="rIdKongSeekComments" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/>"#, at: close.lowerBound)
                parts[index].data = Data(rels.utf8)
            }
            if let index = parts.firstIndex(where: { $0.name == "[Content_Types].xml" }),
               var types = String(data: parts[index].data, encoding: .utf8), !types.contains("/word/comments.xml"),
               let close = types.range(of: "</Types>", options: .backwards) {
                types.insert(contentsOf: #"<Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>"#, at: close.lowerBound)
                parts[index].data = Data(types.utf8)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        let zip = try ZipWriter(url: destination)
        for part in parts { try zip.add(part.data, as: part.name) }
        try zip.finish()
        return annotated.placed
    }

    static func maximumID(in xml: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"w:id="(\d+)""#) else { return -1 }
        let text = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: text.length))
            .compactMap { Int(text.substring(with: $0.range(at: 1))) }.max() ?? -1
    }

    /// The paragraphs of a document.xml (innermost `<w:p>` elements) and their text.
    static func paragraphs(in xml: String) -> [(range: NSRange, text: String)] {
        guard let paragraph = try? NSRegularExpression(pattern: #"<w:p(?:\s[^>]*)?>(?:(?!<w:p[\s>]).)*?</w:p>"#, options: [.dotMatchesLineSeparators]),
              let textRun = try? NSRegularExpression(pattern: #"<w:t(?:\s[^>]*)?>([^<]*)</w:t>"#) else { return [] }
        let whole = xml as NSString
        return paragraph.matches(in: xml, range: NSRange(location: 0, length: whole.length)).map { match in
            let inner = whole.substring(with: match.range)
            let innerText = inner as NSString
            let text = textRun.matches(in: inner, range: NSRange(location: 0, length: innerText.length))
                .map { unescape(innerText.substring(with: $0.range(at: 1))) }.joined()
            return (match.range, text)
        }
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// document.xml with a comment range round the paragraph of each comment's quotation.
    static func annotate(document: String, comments: [Comment], firstID: Int) -> (document: String, placed: [Bool]) {
        let paragraphs = paragraphs(in: document)
        let keys = paragraphs.map { String(QuoteMatcher.normalized($0.text)) }
        // Paragraph index → comment ids, in order.
        var marks: [Int: [Int]] = [:]
        var placed: [Bool] = []
        for (offset, comment) in comments.enumerated() {
            let full = String(QuoteMatcher.normalized(comment.anchor))
            let start = String(full.prefix(8))
            let index = full.isEmpty ? nil : (keys.firstIndex { $0.contains(full) } ?? (start.count >= 4 ? keys.firstIndex { $0.contains(start) } : nil))
            if let index { marks[index, default: []].append(firstID + offset) }
            placed.append(index != nil)
        }
        let result = NSMutableString(string: document)
        // From the end, so earlier ranges stay valid.
        for (index, ids) in marks.sorted(by: { $0.key > $1.key }) {
            let range = paragraphs[index].range
            let paragraph = (document as NSString).substring(with: range)
            guard let openEnd = paragraph.range(of: ">")?.upperBound else { continue }
            var head = String(paragraph[..<openEnd])
            var rest = String(paragraph[openEnd...])
            // Paragraph properties must stay first.
            if rest.hasPrefix("<w:pPr"), let propertiesEnd = rest.range(of: "</w:pPr>")?.upperBound ?? rest.range(of: "/>")?.upperBound {
                head += rest[..<propertiesEnd]
                rest = String(rest[propertiesEnd...])
            }
            guard rest.hasSuffix("</w:p>") else { continue }
            rest.removeLast("</w:p>".count)
            let starts = ids.map { "<w:commentRangeStart w:id=\"\($0)\"/>" }.joined()
            let ends = ids.map { "<w:commentRangeEnd w:id=\"\($0)\"/><w:r><w:commentReference w:id=\"\($0)\"/></w:r>" }.joined()
            result.replaceCharacters(in: range, with: head + starts + rest + ends + "</w:p>")
        }
        return (result as String, placed)
    }
}
