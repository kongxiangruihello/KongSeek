import Foundation
import PDFKit
import KongSeekCore

/// What a book file says about itself (0.19): the details in its name (`EbookName`),
/// completed from its own metadata — an EPUB's package document, or a PDF's
/// title and author — when the name has no Chinese title (Anna's Archive sometimes
/// gives only the pinyin: "Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan")
/// or no author. Files only in iCloud are not read.
public struct BookInfo: Equatable {
    public var name: EbookName
    /// True when the name was read from a site's file name pattern.
    public var fromFileName: Bool
    /// Where the title came from when it was not the file name ("EPUB 书目信息", "PDF 文档信息").
    public var titleSource: String?

    public static func read(_ url: URL, readMetadata: Bool = true) -> BookInfo {
        let stem = EbookName.splitMark(url.deletingPathExtension().lastPathComponent).stem
        let parsed = EbookName.parse(stem)
        var info = BookInfo(name: parsed ?? EbookName(title: stem), fromFileName: parsed != nil, titleSource: nil)
        let titleIsRomanized = !EbookName.containsHan(info.name.title)
        // Nothing to add when the name already has a Chinese title and an author.
        guard readMetadata, titleIsRomanized || info.name.authors == nil else { return info }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        guard status != .notDownloaded else { return info }

        var metaTitle: String?
        var metaAuthors: String?
        var source = ""
        switch url.pathExtension.lowercased() {
        case "epub":
            if let epub = EpubMetadata.read(url) {
                metaTitle = epub.title
                metaAuthors = epub.creators.isEmpty ? nil : epub.creators.joined(separator: "、")
                info.name.publisher = info.name.publisher ?? epub.publisher
                if info.name.year == nil { info.name.year = epub.year }
                source = "EPUB 书目信息"
            }
        case "pdf":
            if let document = PDFDocument(url: url), let attributes = document.documentAttributes {
                metaTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String).map(cleanPDFTitle)
                metaAuthors = attributes[PDFDocumentAttribute.authorAttribute] as? String
                source = "PDF 文档信息"
            }
        default:
            break
        }
        // Only Chinese metadata is trusted: PDF fields often hold "Administrator", "SSReader" or a Word file name.
        // The file name's own Chinese title is kept; metadata only replaces a romanized one.
        if titleIsRomanized, let title = metaTitle?.trimmingCharacters(in: .whitespacesAndNewlines), EbookName.containsHan(title), title.count <= 120 {
            info.name.title = title
            info.titleSource = source
        }
        if info.name.authors == nil, let authors = metaAuthors?.trimmingCharacters(in: .whitespacesAndNewlines),
           EbookName.containsHan(authors), authors.count <= 60 {
            info.name.authors = authors
        }
        return info
    }

    /// "Microsoft Word - 讲义.doc" → "讲义".
    static func cleanPDFTitle(_ raw: String) -> String {
        var title = raw
        if let range = title.range(of: #"^Microsoft (Word|PowerPoint) - "#, options: .regularExpression) { title.removeSubrange(range) }
        if let range = title.range(of: #"\.(docx?|pptx?|wps)$"#, options: [.regularExpression, .caseInsensitive]) { title.removeSubrange(range) }
        return title
    }
}
