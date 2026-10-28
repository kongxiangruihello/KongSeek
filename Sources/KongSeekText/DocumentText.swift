import AppKit
import PDFKit
import KongSeekCore

/// Reads the text of a document for `ks mcp`'s read_file: PDFs page by page
/// (with recognized text for scanned pages), Word / RTF / OpenDocument, and plain
/// text (UTF-8 or GB18030). Images and scans use KongSeek's recognized text.
public enum DocumentText {
    public enum Failure: Error, Equatable {
        case notFound
        case isFolder
        /// Only in iCloud; reading it would start a download.
        case notDownloaded
        /// The download from iCloud was started but has not finished yet.
        case downloading
        case unsupported(String)
        case tooLarge
        case unreadable
        /// A scan without a text layer, and KongSeek has not recognized it.
        case noText(pages: Int)

        public var message: String {
            switch self {
            case .notFound: return "The file does not exist."
            case .isFolder: return "This is a folder; use search_files with in:\"<folder>\" to list it."
            case .notDownloaded: return "The file is only in iCloud and not downloaded to this Mac (or is larger than 200 MB). Open it once in Finder to download it."
            case .downloading: return "The file is being downloaded from iCloud; try read_file again in a minute."
            case .unsupported(let ext): return "Reading .\(ext) files is not supported (PDF, Word, PowerPoint .pptx, Excel .xlsx, RTF, OpenDocument, plain text and recognized scans are; Pages and Keynote files are not)."
            case .tooLarge: return "The file is too large to read (over 300 MB)."
            case .unreadable: return "The file could not be read (damaged or protected?)."
            case .noText(let pages): return "This is a scanned PDF (\(pages) pages) without a text layer, and KongSeek has not recognized its text. In KongSeek › 设置 › 文字识别, add its folder to recognize it."
            }
        }
    }

    /// Text by page: PDFs give one entry per page, other documents a single entry.
    public struct Pages: Equatable {
        public var pages: [String]
        /// Pages in the document (PDF), or 1.
        public var totalPages: Int
        /// 1-based number of the first entry in `pages`.
        public var firstPage: Int
        public var isPaged: Bool
        /// Pages whose text came from KongSeek's recognition (scans).
        public var recognizedPages: [Int] = []
        /// What a page is called in headers: 页, or 张幻灯片 for presentations.
        public var unit = "页"
        /// The page numbers the PDF itself gives its pages ("iii", "15"), one per entry of
        /// `pages`; empty when the PDF gives none (0.27).
        public var pageLabels: [String] = []

        /// The PDF's own number for `page` (1-based, in the document), if it gives one.
        public func label(ofPage page: Int) -> String? {
            let index = page - firstPage
            guard pageLabels.indices.contains(index), !pageLabels[index].isEmpty else { return nil }
            return pageLabels[index]
        }

        public init(pages: [String], totalPages: Int, firstPage: Int, isPaged: Bool, recognizedPages: [Int] = [], unit: String = "页") {
            self.pages = pages
            self.totalPages = totalPages
            self.firstPage = firstPage
            self.isPaged = isPaged
            self.recognizedPages = recognizedPages
            self.unit = unit
        }
    }

    static let pagedLimit = 2_000

    /// Pages `firstPage`…`firstPage + maximumPages - 1` of a PDF, or the whole text
    /// of another document.
    /// With `downloadWait` > 0, a file that is only in iCloud (up to 200 MB) is
    /// downloaded first, waiting up to that many seconds.
    public static func read(_ url: URL, firstPage: Int = 1, maximumPages: Int = 50, ocr: OCRStore? = nil,
                            downloadWait: TimeInterval = 0) throws -> Pages {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw Failure.notFound }
        let ext = url.pathExtension.lowercased()
        if isDirectory.boolValue && !["rtfd"].contains(ext) { throw Failure.isFolder }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            guard downloadWait > 0, (values?.fileSize ?? 0) <= 200_000_000 else { throw Failure.notDownloaded }
            try download(url, wait: downloadWait)
        }
        // .pptx/.xlsx: only the XML text parts are read, however large the pictures make the file.
        guard (values?.fileSize ?? 0) <= 300_000_000 || ext == "pptx" || ext == "xlsx" else { throw Failure.tooLarge }
        let record = ocr?.record(for: path)

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
            if document.isLocked && !document.unlock(withPassword: "") { throw Failure.unreadable }
            let total = document.pageCount
            let first = max(1, min(firstPage, max(1, total)))
            let last = min(total, first + max(1, maximumPages) - 1)
            var pages: [String] = []
            var recognized: [Int] = []
            var labels: [String] = []
            var anyText = false
            if total > 0 {
                for number in first...last {
                    let page = document.page(at: number - 1)
                    labels.append(page?.label ?? "")
                    var text = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty, let record, number - 1 < record.pages.count {
                        text = record.pages[number - 1]
                        if !text.isEmpty { recognized.append(number) }
                    }
                    if !text.isEmpty { anyText = true }
                    pages.append(text)
                }
            }
            if !anyText && total > 0 && record == nil && !documentHasText(document) { throw Failure.noText(pages: total) }
            var read = Pages(pages: pages, totalPages: total, firstPage: first, isPaged: true, recognizedPages: recognized)
            // Only when the PDF numbers its pages itself (front matter in roman numerals, the
            // body from 1); PDFKit otherwise reports the page's position, which says nothing.
            if labels.enumerated().contains(where: { !$0.element.isEmpty && $0.element != String(first + $0.offset) }) { read.pageLabels = labels }
            return read
        }

        if ext == "pptx" {
            let slides: [String]
            do { slides = try OfficeText.slides(of: url) } catch { throw Failure.unreadable }
            let total = slides.count
            let first = max(1, min(firstPage, max(1, total)))
            let last = min(total, first + max(1, maximumPages) - 1)
            let shown = total == 0 ? [] : Array(slides[(first - 1)..<last])
            return Pages(pages: shown, totalPages: total, firstPage: first, isPaged: true, unit: "张幻灯片")
        }
        if ext == "xlsx" {
            do { return Pages(pages: [try OfficeText.spreadsheet(of: url)], totalPages: 1, firstPage: 1, isPaged: false) } catch { throw Failure.unreadable }
        }
        if let record, OCRStoreImage.isImage(ext) {
            return Pages(pages: [record.pages.joined(separator: "\n")], totalPages: 1, firstPage: 1, isPaged: false, recognizedPages: [1])
        }
        if ContentPreview.plainTextExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
            guard let text = String(data: data, encoding: .utf8) ?? ContentPreview.decodeGB18030(data) else { throw Failure.unreadable }
            return Pages(pages: [text], totalPages: 1, firstPage: 1, isPaged: false)
        }
        if ContentPreview.richTextExtensions.contains(ext) {
            guard let text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string else { throw Failure.unreadable }
            return Pages(pages: [text], totalPages: 1, firstPage: 1, isPaged: false)
        }
        throw Failure.unsupported(ext.isEmpty ? "(no extension)" : ext)
    }

    /// Asks iCloud for the file and waits until it is on this Mac.
    static func download(_ url: URL, wait: TimeInterval) throws {
        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch { throw Failure.notDownloaded }
        let deadline = Date().addingTimeInterval(wait)
        var current = url
        while Date() < deadline {
            current.removeAllCachedResourceValues()
            let status = (try? current.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Failure.downloading
    }

    /// What "查找扫描版 PDF" needs to know about a PDF.
    public struct TextLayer: Equatable {
        public var hasText: Bool
        public var pages: Int
    }

    /// Whether a local PDF has a text layer, and its page count; nil when it cannot be opened
    /// or is password-protected. Never downloads from iCloud.
    public static func textLayer(of url: URL) -> TextLayer? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked && !document.unlock(withPassword: "") { return nil }
        return TextLayer(hasText: hasTextLayer(document), pages: document.pageCount)
    }

    /// The same test the background recognition uses: sampled pages, most of them with text.
    public static func hasTextLayer(_ document: PDFDocument) -> Bool {
        let texts = ScannedPDFs.samplePages(count: document.pageCount).map { document.page(at: $0)?.string ?? "" }
        return ScannedPDFs.hasText(texts)
    }

    /// Whether any page (checked up to 30) has a text layer.
    private static func documentHasText(_ document: PDFDocument) -> Bool {
        for index in 0..<min(document.pageCount, 30) where !(document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return true
        }
        return false
    }

    /// Text for a reply of at most `maximumCharacters`, starting `offset` characters
    /// into an unpaged document. Returns the text and where to continue, if cut.
    public static func excerpt(_ pages: Pages, offset: Int = 0, maximumCharacters: Int) -> (text: String, nextPage: Int?, nextOffset: Int?) {
        if pages.isPaged {
            var parts: [String] = []
            var used = 0
            for (index, page) in pages.pages.enumerated() {
                let number = pages.firstPage + index
                let header = "--- 第 \(number) \(pages.unit)" + (pages.recognizedPages.contains(number) ? "（识别文字）" : "") + " ---"
                let body = page.isEmpty ? "（此页无文字）" : page
                if used > 0 && used + header.count + body.count > maximumCharacters {
                    return (parts.joined(separator: "\n"), number, nil)
                }
                let room = maximumCharacters - used - header.count
                if body.count > room {
                    // One very long page: cut it, and continue with the next page.
                    parts.append(header + "\n" + String(body.prefix(max(0, room))) + "…")
                    let next = number + 1 <= pages.totalPages ? number + 1 : nil
                    return (parts.joined(separator: "\n"), next, nil)
                }
                parts.append(header + "\n" + body)
                used += header.count + body.count + 2
            }
            let lastShown = pages.firstPage + pages.pages.count - 1
            return (parts.joined(separator: "\n"), lastShown < pages.totalPages ? lastShown + 1 : nil, nil)
        }
        let text = pages.pages.first ?? ""
        let start = text.index(text.startIndex, offsetBy: max(0, offset), limitedBy: text.endIndex) ?? text.endIndex
        let end = text.index(start, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
        let next = end < text.endIndex ? text.distance(from: text.startIndex, to: end) : nil
        return (String(text[start..<end]), nil, next)
    }
}

/// Image types OCR covers (same list as the app's OCR service).
enum OCRStoreImage {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]
    static func isImage(_ ext: String) -> Bool { extensions.contains(ext) }
}
