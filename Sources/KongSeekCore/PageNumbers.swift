import Foundation

/// The page numbers printed in a book, for citations (0.27). A scanned book's PDF
/// counts its cover, preface and contents too, so "PDF 第 29 页" may be "第 15 页" in
/// the book. The PDF's own page labels are used when it has them; otherwise, once the
/// reader says "PDF 第 29 页 = 书上第 15 页", every page of that file is counted on
/// from there.
public struct PageNumbers: Codable, Equatable, Sendable {
    /// path → offset; the printed page is the PDF page minus the offset.
    public private(set) var offsets: [String: Int] = [:]

    public init(offsets: [String: Int] = [:]) {
        self.offsets = offsets
    }

    public func offset(for path: String) -> Int? { offsets[path] }

    /// Records that PDF page `pdfPage` is page `printedPage` in the book.
    public mutating func set(path: String, pdfPage: Int, printedPage: Int) {
        guard pdfPage >= 1, printedPage >= 1 else { return }
        let offset = pdfPage - printedPage
        if offset == 0 { offsets.removeValue(forKey: path) } else { offsets[path] = offset }
    }

    public mutating func clear(path: String) {
        offsets.removeValue(forKey: path)
    }

    /// Follows a renamed or moved file.
    public mutating func move(from old: String, to new: String) {
        guard let offset = offsets.removeValue(forKey: old) else { return }
        offsets[new] = offset
    }

    public enum Source: Equatable, Sendable {
        /// Counted from the reader's "PDF 第 N 页 = 书上第 M 页".
        case reader
        /// The PDF's own page label.
        case label
        /// Nothing better known: the PDF page.
        case pdf
    }

    public struct Printed: Equatable, Sendable {
        /// "15", "iii".
        public var text: String
        public var source: Source
        public var pdfPage: Int

        /// "第 15 页", with "（PDF 第 29 页）" when the two differ.
        public var description: String {
            text == String(pdfPage) ? "第 \(text) 页" : "第 \(text) 页（PDF 第 \(pdfPage) 页）"
        }
    }

    /// The page as printed in the book. Pages before the reader's page 1 (front matter)
    /// keep the PDF's label when it has one, else their PDF page.
    public func printed(path: String, pdfPage: Int, label: String?) -> Printed {
        let label = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        if let offset = offsets[path] {
            let number = pdfPage - offset
            if number >= 1 { return Printed(text: String(number), source: .reader, pdfPage: pdfPage) }
        }
        if let label, label != String(pdfPage) { return Printed(text: label, source: .label, pdfPage: pdfPage) }
        return Printed(text: String(pdfPage), source: .pdf, pdfPage: pdfPage)
    }

    // MARK: Storage

    public static func load(from url: URL) -> PageNumbers {
        guard let data = try? Data(contentsOf: url) else { return PageNumbers() }
        return (try? JSONDecoder().decode(PageNumbers.self, from: data)) ?? PageNumbers()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
