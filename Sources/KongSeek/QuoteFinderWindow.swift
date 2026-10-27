import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// "引文查证" (0.21): paste a quotation, find which documents contain it and on
/// which page, allowing for punctuation, spacing, line breaks, 繁简 and variant
/// characters, and small slips of memory.
final class QuoteFinderModel: ObservableObject {
    struct Result: Identifiable {
        let id = UUID()
        var path: String
        var title: String
        var page: Int?
        var unit: String
        var score: Double
        var excerpt: String
        var book: EbookName?
        var exact: Bool { score >= 1 }
    }

    @Published var quote = ""
    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var status = "粘贴一句引文，点“查证”：在已建立内容索引的文件和识别过的扫描件中找出处。"
    @Published private(set) var checked = (done: 0, total: 0)

    private let lookup: QuoteLookup
    /// Opens 稿件引文核对 (set by the app delegate).
    var openManuscriptCheck: (() -> Void)?

    init(ocr: OCRStore) {
        lookup = QuoteLookup(ocr: ocr)
    }

    func run() {
        let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuoteMatcher.normalized(text).count >= 4 else {
            status = "引文太短，至少需要 4 个字。"
            return
        }
        running = true
        results = []
        checked = (0, 0)
        status = "正在查找含有这句话的文件…"
        lookup.run(text, progress: { [weak self] done, total in
            self?.checked = (done, total)
            if done == 0 { self?.status = "找到 \(total) 个可能的文件，正在逐个核对原文…" }
        }) { [weak self] outcome in
            guard let self else { return }
            self.running = false
            self.results = outcome.results
            let exact = outcome.results.filter(\.exact).count
            var text = outcome.results.isEmpty ? "没有找到出处。" : "找到 \(outcome.results.count) 处：完全一致 \(exact) 处，近似 \(outcome.results.count - exact) 处。"
            if outcome.inCloud > 0 { text += "另有 \(outcome.inCloud) 个只在 iCloud 中的文件未核对。" }
            if outcome.results.isEmpty { text += "只能查到 Spotlight 已建立内容索引的文件和已识别的扫描件。" }
            self.status = text
        }
    }

    func stop() {
        lookup.stop()
        running = false
        status = "已停止。"
    }

    // MARK: Actions on a result

    func open(_ result: Result) {
        let url = URL(fileURLWithPath: result.path)
        switch url.pathExtension.lowercased() {
        case "pdf":
            ReaderWindowController.shared.open(url, page: result.page, words: QuoteMatcher.probes(quote, length: 4))
        case "pptx":
            if let page = result.page { PowerPoint.open(result.path, slide: page) { _ in } } else { NSWorkspace.shared.open(url) }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    /// The source in the chosen citation style, with the page.
    func reference(_ result: Result) -> String {
        if let book = result.book {
            return Citation.make(Preferences.citationStyle, name: book, fallbackTitle: book.title, page: result.page).text
        }
        let stem = (result.path as NSString).lastPathComponent
        return "《\((stem as NSString).deletingPathExtension)》" + (result.page.map { "第 \($0) \(result.unit == "张" ? "张幻灯片" : "页")" } ?? "")
    }

    func copy(_ result: Result, withQuote: Bool) {
        let text = withQuote ? "“\(result.excerpt)”\n\(reference(result))" : reference(result)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = withQuote ? "已拷贝原文和出处。" : "已拷贝出处：\(reference(result))"
    }

    /// Opens KongReview's capture window with the passage and its source (0.22).
    func sendToKongReview(_ result: Result) {
        KongReviewLink.send(text: result.excerpt, title: result.title, author: result.book?.authors,
                            location: result.page.map { "第 \($0) \(result.unit == "张" ? "张幻灯片" : "页")" }, note: reference(result))
    }

    /// Shows a message in the status line.
    func note(_ text: String) { status = text }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { quote = text }
    }
}

struct QuoteFinderView: View {
    @ObservedObject var model: QuoteFinderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("引文").font(.callout.weight(.semibold))
            TextEditor(text: $model.quote)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("粘贴") { model.pasteFromClipboard() }
                if let open = model.openManuscriptCheck {
                    Button("核对整篇稿件…") { open() }.help("把一篇稿件中引号内的引文逐条查证")
                }
                Spacer()
                if model.running {
                    if model.checked.total > 0 { Text("已核对 \(model.checked.done) / \(model.checked.total)").font(.caption).foregroundColor(.secondary) }
                    ProgressView().controlSize(.small)
                    Button("停止") { model.stop() }
                } else {
                    Button("查证") { model.run() }.keyboardShortcut(.defaultAction)
                }
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(result.exact ? "完全一致" : "近似 \(Int((result.score * 100).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill((result.exact ? Color.green : Color.orange).opacity(0.18)))
                            .foregroundColor(result.exact ? .green : .orange)
                        Text(result.title).lineLimit(1).truncationMode(.middle)
                        if let page = result.page { Text("第 \(page) \(result.unit)").foregroundColor(.accentColor) }
                        Spacer()
                        Button("打开到此处") { model.open(result) }.controlSize(.small)
                        Button("拷贝出处") { model.copy(result, withQuote: false) }.controlSize(.small)
                        Button("拷贝原文和出处") { model.copy(result, withQuote: true) }.controlSize(.small)
                        if KongReviewLink.isInstalled {
                            Button("送到 KongReview") { model.sendToKongReview(result) }.controlSize(.small)
                        }
                    }
                    Text(result.excerpt).font(.callout).foregroundColor(.secondary).lineLimit(3)
                    Text(SearchWindowController.displayLocation(of: result.path)).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }
}

final class QuoteFinderWindowController: NSWindowController {
    let model: QuoteFinderModel

    init(ocr: OCRStore) {
        model = QuoteFinderModel(ocr: ocr)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "引文查证"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: QuoteFinderView(model: model))
        window.setContentSize(NSSize(width: 860, height: 640))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window; `quote` (e.g. text selected in another app) is filled in and checked.
    func present(quote: String? = nil) {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.quote = quote
            model.run()
        }
    }
}

/// Finds where a quotation occurs (0.21; shared with 稿件引文核对, 0.23): candidates
/// from Spotlight (any of three pieces of the quotation) and recognized scans, then
/// each candidate's text checked with QuoteMatcher. Callbacks arrive on main.
final class QuoteLookup {
    typealias Result = QuoteFinderModel.Result

    struct Outcome {
        var results: [Result]
        var candidates: Int
        var inCloud: Int
    }

    private let ocr: OCRStore
    private let search = ContentSearch()
    private var token = 0
    /// Texts of documents read lately, so checking many quotations from one manuscript
    /// does not read the same books again and again.
    private let pages = NSCache<NSString, PagesBox>()

    final class PagesBox {
        let pages: DocumentText.Pages?
        init(_ pages: DocumentText.Pages?) { self.pages = pages }
    }

    init(ocr: OCRStore) {
        self.ocr = ocr
        pages.countLimit = 40
    }

    func stop() {
        token += 1
        search.stop()
    }

    func run(_ text: String, maximumCandidates: Int = 150, progress: ((Int, Int) -> Void)? = nil, completion: @escaping (Outcome) -> Void) {
        let probes = QuoteMatcher.probes(text)
        guard QuoteMatcher.normalized(text).count >= 4, !probes.isEmpty else {
            completion(Outcome(results: [], candidates: 0, inCloud: 0))
            return
        }
        token += 1
        let current = token
        let queries = probes.compactMap { SpotlightQuery.content(for: SearchQuery("\"\($0)\"")) }
        let spotlight = queries.map { "(\($0))" }.joined(separator: " || ")
        let roots = NameIndex.effectiveRoots(Preferences.roots, rules: Preferences.rules)
        search.stop()
        let started = search.search(spotlight, scopes: roots) { [weak self] hits, finished in
            guard let self, finished, current == self.token else { return }
            self.check(Set(hits.filter { !$0.isFolder }.map(\.path)), text: text, probes: probes, limit: maximumCandidates,
                       token: current, progress: progress, completion: completion)
        }
        if !started { check([], text: text, probes: probes, limit: maximumCandidates, token: current, progress: progress, completion: completion) }
    }

    private func check(_ spotlightPaths: Set<String>, text: String, probes: [String], limit: Int, token current: Int,
                       progress: ((Int, Int) -> Void)?, completion: @escaping (Outcome) -> Void) {
        var paths = spotlightPaths
        for probe in probes { for hit in ocr.search([probe], limit: 100) { paths.insert(hit.path) } }
        let candidates = Array(paths.prefix(limit))
        progress?(0, candidates.count)
        let store = ocr
        let cache = pages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [Result] = []
            var inCloud = 0
            for (number, path) in candidates.enumerated() {
                guard let self, current == self.token else { return }
                let url = URL(fileURLWithPath: path)
                if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    inCloud += 1
                    continue
                }
                let read: DocumentText.Pages?
                if let box = cache.object(forKey: path as NSString) {
                    read = box.pages
                } else {
                    read = try? DocumentText.read(url, maximumPages: 5_000, ocr: store)
                    cache.setObject(PagesBox(read), forKey: path as NSString)
                }
                if let pages = read, let match = QuoteMatcher.best(in: pages.pages, quote: text) {
                    let ext = url.pathExtension.lowercased()
                    let isBook = DuplicateFinder.bookExtensions.contains(ext)
                    let book = isBook ? BookInfo.read(url).name : nil
                    found.append(Result(path: path, title: book?.title ?? url.lastPathComponent,
                                        page: pages.isPaged ? pages.firstPage + match.unit : nil,
                                        unit: pages.unit == "页" ? "页" : "张", score: match.score, excerpt: match.excerpt, book: book))
                }
                if number % 5 == 4, let progress {
                    let done = number + 1
                    DispatchQueue.main.async { if current == self.token { progress(done, candidates.count) } }
                }
            }
            let sorted = found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                completion(Outcome(results: sorted, candidates: candidates.count, inCloud: inCloud))
            }
        }
    }
}
