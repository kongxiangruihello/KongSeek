import AppKit
import PDFKit
import KongSeekCore

/// Finds where a search word occurs inside a file, for the preview pane in
/// full-text mode (ported from KongFetch 4.1) and for `ks mcp`'s search_content.
public enum ContentPreview {
    public struct Found {
        public var snippet: Snippet
        /// 1-based PDF page, if known.
        public var page: Int?
        /// From text recognition rather than the file's own text.
        public var recognized = false
    }

    public enum Outcome {
        case found(Found)
        case notFound
        /// An iCloud file that is not on this Mac; reading it would start a download.
        case notDownloaded
        case unsupported
    }

    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "tex", "bib", "json", "xml", "html", "htm", "yaml", "yml", "log",
        "swift", "py", "js", "ts", "css", "sh", "c", "h", "m",
    ]
    static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "wordml"]

    /// Whether `find` can look inside this kind of file.
    public static func canRead(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "pdf" || ext == "pptx" || ext == "xlsx" || plainTextExtensions.contains(ext) || richTextExtensions.contains(ext)
            || EbookText.supports(ext)
    }

    /// Slow for big files: call off the main thread.
    public static func find(in url: URL, needles: [String], ocr: OCRStore? = nil) -> Outcome {
        if let hit = ocr?.hit(for: url.path, needles: needles) {
            return .found(Found(snippet: hit.snippet, page: hit.page, recognized: true))
        }
        let ext = url.pathExtension.lowercased()
        guard canRead(url.path) else { return .unsupported }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
        let size = values?.fileSize ?? 0
        // .pptx/.xlsx are zip archives whose size is mostly pictures; only their small XML text parts are read.
        guard size <= 300_000_000 || ext == "pptx" || ext == "xlsx" else { return .unsupported }

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return .notFound }
            for index in 0..<min(document.pageCount, 1000) {
                if let text = document.page(at: index)?.string, let snippet = Snippet.find(in: text, needles: needles) {
                    return .found(Found(snippet: snippet, page: index + 1))
                }
            }
            return .notFound
        }

        if EbookText.supports(ext) {
            // E-books (0.37), which Spotlight does not read: KongSeek's own text index finds them.
            guard let parts = try? EbookText.read(url), let snippet = Snippet.find(in: parts.joined(separator: "\n\n"), needles: needles) else { return .notFound }
            return .found(Found(snippet: snippet, page: nil))
        }

        if ext == "pptx" {
            guard let slides = try? OfficeText.slides(of: url) else { return .notFound }
            for (index, slide) in slides.enumerated() {
                if let snippet = Snippet.find(in: slide, needles: needles) { return .found(Found(snippet: snippet, page: index + 1)) }
            }
            return .notFound
        }

        let text: String?
        if ext == "xlsx" {
            text = try? OfficeText.spreadsheet(of: url)
        } else if plainTextExtensions.contains(ext) {
            guard size <= 30_000_000, let data = try? Data(contentsOf: url) else { return .notFound }
            text = String(data: data, encoding: .utf8) ?? decodeGB18030(data)
        } else {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let text, let snippet = Snippet.find(in: text, needles: needles) else { return .notFound }
        return .found(Found(snippet: snippet, page: nil))
    }

    /// Older Chinese text files are often GB18030 / GBK rather than UTF-8.
    public static func decodeGB18030(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
}

/// Runs one full-text Spotlight query at a time over the indexed folders.
public final class ContentSearch: NSObject {
    public struct Hit {
        public var path: String
        public var isFolder: Bool
        public var relevance: Double
        public var modified: Date?
    }

    /// Spotlight can match very many items for short words; only this many are ranked.
    public var maximumHits = 3000

    public override init() {
        super.init()
    }

    private var query: NSMetadataQuery?
    private var completion: (([Hit], Bool) -> Void)?

    /// Calls `completion` on main with partial results while gathering, then once
    /// with `finished == true`. Returns false if the query could not be built.
    @discardableResult
    public func search(_ queryString: String, scopes: [String], completion: @escaping ([Hit], Bool) -> Void) -> Bool {
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

    public var isRunning: Bool { query != nil }

    /// Runs a query to the end on the current thread (which must not be busy with
    /// anything else: its run loop is spun until Spotlight finishes or `timeout`).
    /// Used by the command-line tool.
    public static func runToEnd(_ queryString: String, scopes: [String], maximumHits: Int = 3000, timeout: TimeInterval = 20) -> [Hit]? {
        let search = ContentSearch()
        search.maximumHits = maximumHits
        var result: [Hit]?
        var done = false
        guard search.search(queryString, scopes: scopes, completion: { hits, finished in
            result = hits
            if finished { done = true }
        }) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.1)))
        }
        search.stop()
        return result ?? []
    }

    public func stop() {
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
