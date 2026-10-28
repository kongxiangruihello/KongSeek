import AppKit
import PDFKit
import KongSeekCore

/// KongFolio, the PDF reading and annotation app (0.25). When it is installed (and chosen
/// in 设置 › 通用 › PDF 阅读), PDFs opened "at the hit" go there instead of KongSeek's reading window,
/// and its reading progress shows in 最近阅读 and 文件清单.
enum KongFolio {
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: KongFolioLink.bundleIdentifier)
    }

    static var isInstalled: Bool { appURL != nil }

    static var installedVersion: String? {
        guard let url = appURL, let info = Bundle(url: url)?.infoDictionary else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Whether PDFs are opened in KongFolio: the setting, or (自动) whenever it is installed.
    static var isReader: Bool {
        switch Preferences.pdfReader {
        case .kongFolio: return isInstalled
        case .builtIn: return false
        case .automatic: return isInstalled
        }
    }

    /// Reading progress KongFolio keeps in its preferences (empty when it was never used).
    static func readingEntries() -> [ReadingLog.Entry] {
        guard let defaults = UserDefaults(suiteName: KongFolioLink.bundleIdentifier) else { return [] }
        return KongFolioLink.entries(from: defaults.dictionaryRepresentation())
    }

    /// Opens a PDF in KongFolio at `page` (1-based) with `words` marked on it; without a page,
    /// KongFolio opens it where it was last read (KongFolio 0.34).
    static func open(_ url: URL, page: Int?, words: [String], keepMarks: Bool = true) {
        guard let app = appURL else { return }
        guard let page else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let rects = words.isEmpty ? [] : marks(of: words, on: page, in: url)
            DispatchQueue.main.async {
                guard let link = KongFolioLink.url(path: url.path, page: page, rects: rects, anchor: words.first, keep: keepMarks && !rects.isEmpty) else {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
                }
            }
        }
    }

    /// Where the words stand on the page, in page coordinates (the page's text layer; a
    /// scan without one gives none, and KongFolio then looks for the words itself).
    static func marks(of words: [String], on page: Int, in url: URL) -> [KongFolioLink.Rect] {
        guard let document = PDFDocument(url: url), !document.isLocked, page >= 1, page <= document.pageCount,
              let target = document.page(at: page - 1), let text = target.string else { return [] }
        return lineMarks(of: words, on: target, text: text)
    }

    /// One rectangle per line, so a phrase broken over two lines is marked line by line.
    private static func lineMarks(of words: [String], on page: PDFPage, text: String) -> [KongFolioLink.Rect] {
        var result: [KongFolioLink.Rect] = []
        for range in TextLocator.ranges(of: words, in: text).prefix(40) {
            guard let selection = page.selection(for: range) else { continue }
            let lines = selection.selectionsByLine()
            for line in lines.isEmpty ? [selection] : lines {
                let box = line.bounds(for: page)
                guard box.width > 0, box.height > 0 else { continue }
                result.append(KongFolioLink.Rect(x: Double(box.minX), y: Double(box.minY), width: Double(box.width), height: Double(box.height)))
            }
        }
        return result
    }
}

/// Opens a PDF at a page with words marked: in KongFolio, or in KongSeek's reading window.
enum PDFOpener {
    static func open(_ url: URL, page: Int?, words: [String]) {
        if KongFolio.isReader {
            KongFolio.open(url, page: page, words: words)
        } else {
            ReaderWindowController.shared.open(url, page: page, words: words)
        }
    }

    /// Opens a book from 最近阅读 at the page it was read to.
    static func resume(_ url: URL, at page: Int?) {
        if KongFolio.isReader {
            KongFolio.open(url, page: page, words: [], keepMarks: false)
        } else {
            ReaderWindowController.shared.open(url, page: nil, words: [])
        }
    }

    /// Where each book was read to, in KongSeek's reading window and in KongFolio.
    static var readingLog: ReadingLog {
        Records.reading.merged(with: KongFolio.readingEntries())
    }
}
