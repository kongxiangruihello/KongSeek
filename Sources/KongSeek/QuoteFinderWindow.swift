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
        /// The PDF's own number for the page, if it gives one (0.27).
        var label: String? = nil
        var exact: Bool { score >= 1 }

        /// The page as printed in the book (0.27): the reader's "PDF 第 N 页 = 书上第 M 页",
        /// else the PDF's own page label, else the PDF page.
        var printed: PageNumbers.Printed? {
            guard let page, unit == "页" else { return nil }
            return Records.pageNumbers.printed(path: path, pdfPage: page, label: label)
        }

        /// "第 15 页（PDF 第 29 页）" or "第 3 张".
        var placeDescription: String? {
            if let printed { return printed.description }
            return page.map { "第 \($0) \(unit)" }
        }
    }

    @Published var quote = ""
    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var status = "粘贴一句引文，点“查证”：在已建立内容索引的文件和识别过的扫描件中找出处。粘贴含多处引号的一段文字，会逐条查证。"
    @Published private(set) var checked = (done: 0, total: 0)

    private let lookup: QuoteLookup
    /// Opens 稿件引文核对 (set by the app delegate).
    var openManuscriptCheck: (() -> Void)?
    /// Checks each quotation of a pasted passage in 稿件引文核对 (0.32; set by the app delegate).
    var checkPassage: ((String) -> Void)?
    /// The quotation last looked up — the words inside the marks when a passage was pasted
    /// (0.32) — which the results are compared with.
    private var checkedText = ""

    /// The quotations in the text when it is a passage rather than one quotation (0.32).
    var passage: [ManuscriptQuotes.Quote] { ManuscriptQuotes.inPassage(quote) }

    init(ocr: OCRStore) {
        lookup = QuoteLookup(ocr: ocr)
    }

    func run() {
        let pasted = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        // A passage (0.32): several quotations go to 稿件引文核对, one at a time;
        // a single quotation with text around it is looked up by its own words.
        let quotations = ManuscriptQuotes.inPassage(pasted)
        if quotations.count >= 2, let check = checkPassage {
            check(pasted)
            status = "这段文字中有 \(quotations.count) 条引文，已在“稿件引文核对”窗口中逐条查证。"
            return
        }
        let text = quotations.count == 1 ? quotations[0].text : pasted
        let lead = quotations.count == 1 ? QuoteFinderModel.onlyInside(text) : ""
        guard QuoteMatcher.normalized(text).count >= 4 else {
            status = "引文太短，至少需要 4 个字。"
            return
        }
        checkedText = text
        running = true
        results = []
        checked = (0, 0)
        status = lead + "正在查找含有这句话的文件…"
        lookup.run(text, progress: { [weak self] done, total in
            self?.checked = (done, total)
            if done == 0 { self?.status = lead + "找到 \(total) 个可能的文件，正在逐个核对原文…" }
        }) { [weak self] outcome in
            guard let self else { return }
            self.running = false
            self.results = outcome.results
            self.remember(text, results: outcome.results, inCloud: outcome.inCloud)
            self.guessPages()
            let exact = outcome.results.filter(\.exact).count
            var message = lead + (outcome.results.isEmpty ? "没有找到出处。" : "找到 \(outcome.results.count) 处：完全一致 \(exact) 处，近似 \(outcome.results.count - exact) 处。")
            if outcome.inCloud > 0 { message += "另有 \(outcome.inCloud) 个只在 iCloud 中的文件未核对。" }
            if outcome.results.isEmpty { message += "只能查到 Spotlight 已建立内容索引的文件和已识别的扫描件。" }
            self.status = message
        }
    }

    private static func onlyInside(_ text: String) -> String {
        "只查引号内的“" + (text.count > 24 ? String(text.prefix(24)) + "…" : text) + "”。"
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
            PDFOpener.open(url, page: result.page, words: QuoteMatcher.probes(checkedText, length: 4))
        case "pptx":
            if let page = result.page { PowerPoint.open(result.path, slide: page) { _ in } } else { NSWorkspace.shared.open(url) }
        default:
            NSWorkspace.shared.open(url)
        }
    }

    /// The source in the chosen citation style, with the page.
    func reference(_ result: Result) -> String {
        if let book = result.book {
            return Citation.make(Preferences.citationStyle, name: book, fallbackTitle: book.title, page: result.page, pageLabel: result.printed?.text).text
        }
        let stem = (result.path as NSString).lastPathComponent
        let place = result.printed.map { "第 \($0.text) 页" } ?? result.page.map { "第 \($0) \(result.unit == "张" ? "张幻灯片" : "页")" }
        return "《\((stem as NSString).deletingPathExtension)》" + (place ?? "")
    }

    /// 推测书上页码 (0.31) for results whose books number neither their pages nor have been told.
    @Published private(set) var pageGuesses: [String: PageNumberGuess.Guess] = [:]

    private func guessPages() {
        let paths = Set(results.prefix(8).compactMap { $0.printed?.source == .pdf ? $0.path : nil })
        PageGuesses.guess(Array(paths)) { [weak self] path, guess in self?.pageGuesses[path] = guess }
    }

    func acceptGuess(_ result: Result) {
        guard let page = result.page, let guess = pageGuesses[result.path] else { return }
        var numbers = Records.pageNumbers
        numbers.set(path: result.path, pdfPage: page, printedPage: guess.printed(forPDFPage: page))
        Records.pageNumbers = numbers
        pageGuesses[result.path] = nil
        status = "已采用推测的页码：《\(result.title)》PDF 第 \(page) 页 = 书上第 \(guess.printed(forPDFPage: page)) 页。"
    }

    /// Asks which printed page this PDF page is (0.27).
    func setPrintedPage(_ result: Result) {
        guard let page = result.page, result.unit == "页" else { return }
        if PageNumberPrompt.ask(path: result.path, pdfPage: page, current: result.printed) { objectWillChange.send() }
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
                            location: result.printed.map { "第 \($0.text) 页" } ?? result.page.map { "第 \($0) \(result.unit == "张" ? "张幻灯片" : "页")" }, note: reference(result))
    }

    /// 逐字异文 of a near match (0.26); nil when only punctuation or character forms differ.
    func differences(_ result: Result) -> [QuoteDiff.Segment]? {
        guard !result.exact else { return nil }
        let segments = QuoteDiff.compare(quote: checkedText, source: result.excerpt, equivalents: Preferences.quoteEquivalents)
        return QuoteDiff.differs(segments) ? segments : nil
    }

    func copyCorrected(_ result: Result) {
        let corrected = QuoteDiff.corrected(quote: checkedText, source: result.excerpt)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(corrected, forType: .string)
        status = "已拷贝按原文改正的引文：\(corrected)"
    }

    /// Makes the result's file the 常用本 of its book, or stops it being one (0.28).
    func togglePreferred(_ result: Result) {
        Records.togglePreferred(result.path)
        let preferred = Records.editions.isPreferred(result.path)
        results = Records.editions.ordered(results, path: \.path, exact: \.exact)
        status = preferred ? "已把“\(result.title)”设为常用本：以后查证时排在同书其他版本之前。" : "已取消“\(result.title)”的常用本。"
    }

    /// Shows a message in the status line.
    func note(_ text: String) { status = text }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { quote = text }
    }

    // MARK: History (0.33)

    @Published private(set) var history = QuoteHistory.load(from: QuoteFinderModel.historyURL)

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongSeek/quote-history.json")
    }

    private func remember(_ quote: String, results: [Result], inCloud: Int) {
        history.add(QuoteHistory.Entry(quote: quote, results: results.map(\.source), inCloud: inCloud))
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history
        DispatchQueue.global(qos: .utility).async { try? snapshot.save(to: QuoteFinderModel.historyURL) }
    }

    /// Shows an earlier lookup as it was found, without looking it up again.
    func show(_ entry: QuoteHistory.Entry) {
        if running { stop() }
        quote = entry.quote
        checkedText = entry.quote
        results = entry.results.map { Result($0) }
        checked = (0, 0)
        guessPages()
        var text = "\(entry.date.formatted(date: .abbreviated, time: .shortened)) 查证的结果（\(entry.summary)），未重新查找；点“查证”可重查。"
        if entry.inCloud > 0 { text += "当时另有 \(entry.inCloud) 个只在 iCloud 中的文件未核对。" }
        status = text
    }

    func forget(_ entry: QuoteHistory.Entry) {
        history.remove(entry.quote)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
        status = "已清除查证历史。"
    }
}

extension QuoteFinderModel.Result {
    /// A result kept in a session or the history (0.31, 0.33).
    init(_ source: ManuscriptSession.Source) {
        self.init(path: source.path, title: source.title, page: source.page, unit: source.unit, score: source.score,
                  excerpt: source.excerpt, book: source.book, label: source.label)
    }

    var source: ManuscriptSession.Source {
        ManuscriptSession.Source(path: path, title: title, page: page, unit: unit, score: score, excerpt: excerpt, book: book, label: label)
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
                Menu("历史") {
                    if model.history.entries.isEmpty {
                        Text("还没有查证过的引文")
                    }
                    ForEach(Array(model.history.entries.prefix(40).enumerated()), id: \.offset) { _, entry in
                        Button(entry.title + "　" + entry.summary) { model.show(entry) }
                    }
                    if !model.history.entries.isEmpty {
                        Divider()
                        Button("清除历史") { model.clearHistory() }
                    }
                }
                .fixedSize()
                .disabled(model.running)
                .help("最近查证过的引文：选一条即显示当时找到的出处，不必重查")
                Spacer()
                if model.running {
                    if model.checked.total > 0 { Text("已核对 \(model.checked.done) / \(model.checked.total)").font(.caption).foregroundColor(.secondary) }
                    ProgressView().controlSize(.small)
                    Button("停止") { model.stop() }
                } else {
                    Button("查证") { model.run() }.keyboardShortcut(.defaultAction)
                }
            }
            if !model.running, model.checkPassage != nil {
                let quotations = model.passage
                if quotations.count >= 2 {
                    Label("这段文字中有 \(quotations.count) 条引号内的引文，点“查证”会逐条核对（在“稿件引文核对”窗口中）。", systemImage: "text.quote")
                        .font(.caption).foregroundColor(.accentColor)
                } else if quotations.count == 1 {
                    Label("将只查引号内的文字。", systemImage: "text.quote").font(.caption).foregroundColor(.accentColor)
                }
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(QuoteVerdict.text(score: result.score))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill((result.exact ? Color.green : Color.orange).opacity(0.18)))
                            .foregroundColor(result.exact ? .green : .orange)
                        if Records.editions.isPreferred(result.path) {
                            Text("常用本").font(.caption2.weight(.semibold)).foregroundColor(.accentColor)
                        }
                        Text(result.title).lineLimit(1).truncationMode(.middle)
                        if let place = result.placeDescription { Text(place).foregroundColor(.accentColor) }
                        Spacer()
                        Button("打开到此处") { model.open(result) }.controlSize(.small)
                        Button("拷贝出处") { model.copy(result, withQuote: false) }.controlSize(.small)
                        // Less frequent actions in one menu (0.28), so the row fits a narrow window.
                        Menu("更多") {
                            Button("拷贝原文和出处") { model.copy(result, withQuote: true) }
                            if result.unit == "页", result.page != nil {
                                Button("设置书上页码…") { model.setPrintedPage(result) }
                            }
                            Button(Records.editions.isPreferred(result.path) ? String("取消常用本") : String("设为常用本（同书多个版本时排在最前）")) {
                                model.togglePreferred(result)
                            }
                            if result.book != nil {
                                Button("补全书目信息…") { BookLookupWindowController.shared.present(path: result.path) }
                            }
                            if KongReviewLink.isInstalled {
                                Button("送到 KongReview") { model.sendToKongReview(result) }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Text(result.excerpt).font(.callout).foregroundColor(.secondary).lineLimit(3)
                    if let page = result.page, result.printed?.source == .pdf, let guess = model.pageGuesses[result.path] {
                        HStack(spacing: 6) {
                            Text("书上可能是第 \(guess.printed(forPDFPage: page)) 页（读了 \(guess.sampled) 页的页眉页脚，\(guess.agreeing) 页一致）")
                                .font(.caption).foregroundColor(.blue)
                            Button("采用") { model.acceptGuess(result) }.controlSize(.small)
                        }
                    }
                    if let differences = model.differences(result) {
                        HStack(alignment: .firstTextBaseline) {
                            QuoteDiffText.line(differences).font(.caption).lineLimit(3)
                            Spacer()
                            if QuoteDiff.hasErrors(differences) {
                                Button("拷贝改正后的引文") { model.copyCorrected(result) }.controlSize(.small)
                            }
                        }
                    }
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
        if window?.isVisible != true { window?.placeRemembered() }
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
    /// The same texts on disk (0.26), so a book is not read again after KongSeek restarts.
    static let diskCache = TextCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KongSeek/TextCache", isDirectory: true))

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

    /// A document's text from the disk cache while the file is unchanged, else read and kept.
    static func readCached(_ url: URL, ocr: OCRStore) -> DocumentText.Pages? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else {
            return try? DocumentText.read(url, maximumPages: 5_000, ocr: ocr)
        }
        let recognized = ocr.record(for: url.path)?.pages.filter { !$0.isEmpty }.count ?? 0
        let stamp = TextCache.Stamp(size: Int64(size), modified: modified, recognized: recognized)
        // Entries from before 0.27 have no page labels: read those PDFs once more.
        if let entry = diskCache.load(path: url.path, stamp: stamp), entry.labels != nil || !entry.isPaged {
            var pages = DocumentText.Pages(pages: entry.pages, totalPages: entry.totalPages, firstPage: entry.firstPage, isPaged: entry.isPaged)
            pages.unit = entry.unit
            pages.pageLabels = entry.labels ?? []
            return pages
        }
        guard let read = try? DocumentText.read(url, maximumPages: 5_000, ocr: ocr) else { return nil }
        // Worth keeping only when there is text (and the whole document was read).
        if read.pages.contains(where: { !$0.isEmpty }), read.pages.count >= read.totalPages || !read.isPaged {
            diskCache.store(TextCache.Entry(path: url.path, stamp: stamp, pages: read.pages, totalPages: read.totalPages,
                                            firstPage: read.firstPage, isPaged: read.isPaged, unit: read.unit, labels: read.pageLabels))
        }
        return read
    }

    private func check(_ spotlightPaths: Set<String>, text: String, probes: [String], limit: Int, token current: Int,
                       progress: ((Int, Int) -> Void)?, completion: @escaping (Outcome) -> Void) {
        let store = ocr
        let cache = pages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var paths = spotlightPaths
            for probe in probes { for hit in store.search([probe], limit: 100) { paths.insert(hit.path) } }
            // E-books Spotlight does not read (0.37), from KongSeek's own text index.
            for probe in probes { for hit in BookTextService.shared.search([[probe]], limit: 100) { paths.insert(hit.path) } }
            let candidates = Array(paths.prefix(limit))
            if let progress {
                DispatchQueue.main.async { if let self, current == self.token { progress(0, candidates.count) } }
            }
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
                    read = QuoteLookup.readCached(url, ocr: store)
                    cache.setObject(PagesBox(read), forKey: path as NSString)
                }
                if let pages = read, let match = QuoteMatcher.best(in: pages.pages, quote: text) {
                    let ext = url.pathExtension.lowercased()
                    let isBook = DuplicateFinder.bookExtensions.contains(ext)
                    let book = isBook ? BookInfo.read(url).name : nil
                    found.append(Result(path: path, title: book?.title ?? url.lastPathComponent,
                                        page: pages.isPaged ? pages.firstPage + match.unit : nil,
                                        unit: pages.unit == "页" ? "页" : "张", score: match.score, excerpt: match.excerpt, book: book,
                                        label: pages.isPaged ? pages.label(ofPage: pages.firstPage + match.unit) : nil))
                }
                if number % 5 == 4, let progress {
                    let done = number + 1
                    DispatchQueue.main.async { if current == self.token { progress(done, candidates.count) } }
                }
            }
            let sorted = found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                // Exact matches first, and among equals the reader's 常用本 (0.28).
                let ordered = Records.editions.ordered(sorted, path: \.path, exact: \.exact)
                completion(Outcome(results: ordered, candidates: candidates.count, inCloud: inCloud))
            }
        }
    }
}
