import Foundation
import PDFKit
import KongSeekCore

/// "书库体检" (0.21): files in the library that cannot be used as they are.
public enum LibraryCheck {
    public enum Problem: String, CaseIterable, Sendable {
        case unreadablePDF, lockedPDF, unreadableEPUB, empty, partialDownload

        public var title: String {
            switch self {
            case .unreadablePDF: return "打不开的 PDF"
            case .lockedPDF: return "加密的 PDF"
            case .unreadableEPUB: return "损坏的 EPUB"
            case .empty: return "0 字节的文件"
            case .partialDownload: return "没下载完的文件"
            }
        }

        public var advice: String {
            switch self {
            case .unreadablePDF: return "文件已损坏或不是真正的 PDF，通常需要重新下载。"
            case .lockedPDF: return "需要密码才能打开，全文搜索和文字识别都读不到。"
            case .unreadableEPUB: return "压缩包结构损坏，阅读器可能打不开，建议重新下载。"
            case .empty: return "文件没有内容，多为下载或拷贝中断留下的空文件。"
            case .partialDownload: return "浏览器下载中断留下的临时文件（.crdownload、.part 等），可以删除后重新下载。"
            }
        }
    }

    /// Extensions browsers give files that are still downloading.
    public static let partialExtensions: Set<String> = ["crdownload", "part", "partial", "opdownload", "download", "!ut", "aria2"]

    /// Kinds of documents checked for being empty.
    public static let documentExtensions: Set<String> = DuplicateFinder.bookExtensions.union(["doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "rtf", "zip"])

    /// What is wrong with a file, from its name and size alone (no reading).
    public static func quickProblem(path: String, size: Int64) -> Problem? {
        let ext = (path as NSString).pathExtension.lowercased()
        if partialExtensions.contains(ext) { return .partialDownload }
        if size == 0 && documentExtensions.contains(ext) { return .empty }
        return nil
    }

    /// What is wrong with a local PDF or EPUB, by opening it; nil when it is fine
    /// or not a kind that is opened here.
    public static func inspect(_ url: URL) -> Problem? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return .unreadablePDF }
            if document.isLocked && !document.unlock(withPassword: "") { return .lockedPDF }
            return document.pageCount == 0 ? .unreadablePDF : nil
        case "epub":
            return EpubMetadata.read(url) == nil ? .unreadableEPUB : nil
        default:
            return nil
        }
    }
}
