import AppKit
import PDFKit
import KongSeekCore

/// "PDF 第 N 页在书上是第几页？" (0.27): set once per book, then every page of it is
/// cited by the number printed in the book.
enum PageNumberPrompt {
    /// Returns true when the book's page numbering was changed.
    @discardableResult
    static func ask(path: String, pdfPage: Int, current: PageNumbers.Printed?) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let hasOffset = Records.pageNumbers.offset(for: path) != nil
        let alert = NSAlert()
        alert.messageText = "PDF 第 \(pdfPage) 页在书上是第几页？"
        var info = "请看这一页上印的页码填在下面。设一次，《\(name)》的每一页都按它换算，引文出处、参考文献、Excel 核对表都用书上的页码。"
        if let current, current.text != String(pdfPage) {
            info += "\n\n现在按" + (current.source == .reader ? "你设的对应" : "PDF 自带的页码") + "算作第 \(current.text) 页。"
        }
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "如 15"
        if let current, Int(current.text) != nil { field.stringValue = current.text }
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if hasOffset { alert.addButton(withTitle: "清除这本书的设定") }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let digits = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let printed = Int(digits), printed >= 1 else {
                let problem = NSAlert()
                problem.messageText = "请填一个正整数页码，如 15。"
                problem.informativeText = "罗马数字的前言页码不必设：从正文第 1 页起对上即可。"
                problem.runModal()
                return false
            }
            var numbers = Records.pageNumbers
            numbers.set(path: path, pdfPage: pdfPage, printedPage: printed)
            Records.pageNumbers = numbers
            return true
        case .alertThirdButtonReturn:
            var numbers = Records.pageNumbers
            numbers.clear(path: path)
            Records.pageNumbers = numbers
            return true
        default:
            return false
        }
    }

    /// The PDF's own label for a page, when it numbers its pages itself.
    static func label(path: String, pdfPage: Int) -> String? {
        guard let page = PDFDocumentCache.page(path: path, number: pdfPage), let label = page.label,
              !label.isEmpty, label != String(pdfPage) else { return nil }
        return label
    }

    /// The page as printed in the book, reading the PDF's label when needed.
    static func printed(path: String, pdfPage: Int) -> PageNumbers.Printed {
        let numbers = Records.pageNumbers
        if numbers.offset(for: path) != nil { return numbers.printed(path: path, pdfPage: pdfPage, label: nil) }
        return numbers.printed(path: path, pdfPage: pdfPage, label: label(path: path, pdfPage: pdfPage))
    }
}

/// The last PDF opened for a page label, so labelling several hits in one book opens it once.
enum PDFDocumentCache {
    private static var last: (path: String, document: PDFDocument)?

    static func page(path: String, number: Int) -> PDFPage? {
        let document: PDFDocument
        if let last, last.path == path {
            document = last.document
        } else {
            guard let opened = PDFDocument(url: URL(fileURLWithPath: path)), !opened.isLocked else { return nil }
            document = opened
            last = (path, opened)
        }
        guard number >= 1, number <= document.pageCount else { return nil }
        return document.page(at: number - 1)
    }
}
