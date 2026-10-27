import AppKit
import PDFKit
import KongSeekCore

/// Finds where a search word occurs inside a file, for the preview pane in
/// full-text mode (ported from KongFetch 4.1).
enum ContentPreview {
    struct Found {
        var snippet: Snippet
        /// 1-based PDF page, if known.
        var page: Int?
    }

    enum Outcome {
        case found(Found)
        case notFound
        /// An iCloud file that is not on this Mac; reading it would start a download.
        case notDownloaded
        case unsupported
    }

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "tex", "bib", "json", "xml", "html", "htm", "yaml", "yml", "log",
        "swift", "py", "js", "ts", "css", "sh", "c", "h", "m",
    ]
    private static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "wordml"]

    /// Slow for big files: call off the main thread.
    static func find(in url: URL, needles: [String]) -> Outcome {
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || plainTextExtensions.contains(ext) || richTextExtensions.contains(ext) else { return .unsupported }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
        let size = values?.fileSize ?? 0
        guard size <= 300_000_000 else { return .unsupported }

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return .notFound }
            for index in 0..<min(document.pageCount, 1000) {
                if let text = document.page(at: index)?.string, let snippet = Snippet.find(in: text, needles: needles) {
                    return .found(Found(snippet: snippet, page: index + 1))
                }
            }
            return .notFound
        }

        let text: String?
        if plainTextExtensions.contains(ext) {
            guard size <= 30_000_000, let data = try? Data(contentsOf: url) else { return .notFound }
            text = String(data: data, encoding: .utf8) ?? decodeGB18030(data)
        } else {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let text, let snippet = Snippet.find(in: text, needles: needles) else { return .notFound }
        return .found(Found(snippet: snippet, page: nil))
    }

    /// Older Chinese text files are often GB18030 / GBK rather than UTF-8.
    private static func decodeGB18030(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
}

/// Runs one full-text Spotlight query at a time over the indexed folders.
final class ContentSearch: NSObject {
    struct Hit {
        var path: String
        var isFolder: Bool
        var relevance: Double
        var modified: Date?
    }

    /// Spotlight can match very many items for short words; only this many are ranked.
    var maximumHits = 3000

    private var query: NSMetadataQuery?
    private var completion: (([Hit], Bool) -> Void)?

    /// Calls `completion` on main with partial results while gathering, then once
    /// with `finished == true`. Returns false if the query could not be built.
    @discardableResult
    func search(_ queryString: String, scopes: [String], completion: @escaping ([Hit], Bool) -> Void) -> Bool {
        stop()
        guard let predicate = NSPredicate(fromMetadataQueryString: queryString) else { return false }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        query.notificationBatchingInterval = 0.2
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(progress(_:)), name: .NSMetadataQueryGatheringProgress, object: query)
        center.addObserver(self, selector: #selector(finished(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = query
        self.completion = completion
        if !query.start() {
            stop()
            return false
        }
        return true
    }

    var isRunning: Bool { query != nil }

    func stop() {
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
        }
        query = nil
        completion = nil
    }

    @objc private func progress(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        completion?(collect(query), false)
    }

    @objc private func finished(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        let hits = collect(query)
        let completion = self.completion
        stop() // one-shot: no live updates
        completion?(hits, true)
    }

    private func collect(_ query: NSMetadataQuery) -> [Hit] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = min(query.resultCount, maximumHits)
        var hits: [Hit] = []
        hits.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            hits.append(Hit(
                path: path,
                isFolder: type == "public.folder",
                relevance: (item.value(forAttribute: NSMetadataQueryResultContentRelevanceAttribute) as? NSNumber)?.doubleValue ?? 0,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            ))
        }
        return hits
    }
}
