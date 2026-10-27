import Foundation
import KongSeekCore

/// Text of PowerPoint (.pptx) and Excel (.xlsx) files, read straight from their
/// XML parts (they are zip archives), without PowerPoint or Excel.
public enum OfficeText {
    /// One string per slide, in slide order: the text of every text box, one
    /// paragraph per line, followed by the speaker notes when there are any.
    public static func slides(of url: URL) throws -> [String] {
        let entries = try ZipReader.entries(at: url)
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // ppt/slides/slide12.xml → 12; numbered order, not archive order.
        let slides = entries.compactMap { entry -> (Int, ZipReader.Entry)? in
            guard entry.name.hasPrefix("ppt/slides/slide"), entry.name.hasSuffix(".xml"),
                  let number = Int(entry.name.dropFirst("ppt/slides/slide".count).dropLast(4)) else { return nil }
            return (number, entry)
        }.sorted { $0.0 < $1.0 }
        return try slides.map { number, entry in
            var text = paragraphs(in: try ZipReader.data(entry, from: url, maximumSize: 50_000_000), textElement: "a:t", paragraphElement: "a:p")
            if let notes = byName["ppt/notesSlides/notesSlide\(number).xml"] {
                let noteText = paragraphs(in: try ZipReader.data(notes, from: url, maximumSize: 50_000_000), textElement: "a:t", paragraphElement: "a:p")
                    .split(separator: "\n").filter { Int($0) == nil }.joined(separator: "\n") // drop the slide-number field
                if !noteText.isEmpty { text += (text.isEmpty ? "" : "\n") + "【备注】" + noteText }
            }
            return text
        }
    }

    /// The text cells of a workbook (its shared strings), one per line.
    public static func spreadsheet(of url: URL) throws -> String {
        let entries = try ZipReader.entries(at: url)
        guard let strings = entries.first(where: { $0.name == "xl/sharedStrings.xml" }) else { return "" }
        return paragraphs(in: try ZipReader.data(strings, from: url, maximumSize: 100_000_000), textElement: "t", paragraphElement: "si")
    }

    /// Text inside `textElement`s, with a line break after each `paragraphElement`.
    static func paragraphs(in xml: Data, textElement: String, paragraphElement: String) -> String {
        let collector = Collector(textElement: textElement, paragraphElement: paragraphElement)
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.parse()
        return collector.lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let textElement: String
        let paragraphElement: String
        var lines: [String] = []
        private var current = ""
        private var inText = false

        init(textElement: String, paragraphElement: String) {
            self.textElement = textElement
            self.paragraphElement = paragraphElement
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == textElement { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == textElement { inText = false }
            if name == paragraphElement {
                lines.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if !current.isEmpty { lines.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
