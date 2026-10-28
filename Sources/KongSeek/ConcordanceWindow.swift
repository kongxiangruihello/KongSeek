import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore
import KongSeekText

/// "出处汇编" (0.27): every place a word occurs in the library — book, page as printed,
/// the words around it — to work from when preparing a lecture or a paper, and to
/// export to Word or Excel.
final class ConcordanceModel: ObservableObject {
    struct Hit: Identifiable {
        let id = UUID()
        var pdfPage: Int?
        /// "15" — the page printed in the book, or the PDF page.
        var page: String?
        var unit: String
        var occurrence: Concordance.Occurrence
    }

    struct Group: Identifiable {
        var id: String { path }
        var path: String
        var title: String
        var book: EbookName?
        var hits: [Hit]
    }

    @Published var query = ""
    @Published private(set) var groups: [Group] = []
    @Published private(set) var running = false
    @Published private(set) var status = "输入要汇编的词（可加 in:文件夹、ext:pdf 等），在已建立内容索引的文件和识别过的扫描件中逐处列出。"
    @Published private(set) var checked = (done: 0, total: 0)
    private(set) var words: [String] = []

    private let ocr: OCRStore
    private let search = ContentSearch()
    private var token = 0
    static let maximumFiles = 300
    static let maximumHits = 5_000

    init(ocr: OCRStore) {
        self.ocr = ocr
    }

    var hitCount: Int { groups.reduce(0) { $0 + $1.hits.count } }

    func stop() {
        token += 1
        search.stop()
        if running {
            running = false
            status = "已停止。" + summary
        }
    }

    private var summary: String {
        groups.isEmpty ? "" : "\(groups.count) 个文件，共 \(hitCount) 处。"
    }

    func run() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = SearchQuery(text)
        words = parsed.words + parsed.phrases
        guard !words.isEmpty, let spotlight = SpotlightQuery.content(for: parsed) else {
            status = "请输入要汇编的词。"
            return
        }
        token += 1
        let current = token
        groups = []
        running = true
        checked = (0, 0)
        status = "正在查找含有这些词的文件…"
        let roots = NameIndex.effectiveRoots(Preferences.roots, rules: Preferences.rules)
        search.stop()
        let started = search.search(spotlight, scopes: roots) { [weak self] hits, finished in
            guard let self, finished, current == self.token else { return }
            self.collect(Set(hits.filter { !$0.isFolder }.map(\.path)), query: parsed, token: current)
        }
        if !started { collect([], query: parsed, token: current) }
    }

    private func accepts(_ path: String, _ query: SearchQuery) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if !query.extensions.isEmpty && !query.extensions.contains(ext) { return false }
        if query.excludedExtensions.contains(ext) { return false }
        return query.advanced.acceptsPath(path, isFolder: false)
    }

    /// Adds the e-books Spotlight does not read (0.37), looked up off the main thread.
    private func collect(_ spotlightPaths: Set<String>, query: SearchQuery, token current: Int) {
        let words = self.words
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let books = Set(BookTextService.shared.search(words.map { [$0] }, limit: 200).map(\.path))
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                self.gather(spotlightPaths.union(books), query: query, token: current)
            }
        }
    }

    private func gather(_ found: Set<String>, query: SearchQuery, token current: Int) {
        var paths = found
        for hit in ocr.search(words, limit: 200) { paths.insert(hit.path) }
        let candidates = Array(paths.filter { accepts($0, query) }.sorted().prefix(Self.maximumFiles))
        let skipped = paths.count - candidates.count
        checked = (0, candidates.count)
        status = "找到 \(candidates.count) 个文件，正在逐个列出…"
        let words = self.words
        let store = ocr
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total = 0
            for (number, path) in candidates.enumerated() {
                guard let self, current == self.token else { return }
                let url = URL(fileURLWithPath: path)
                if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded { continue }
                guard let pages = QuoteLookup.readCached(url, ocr: store) else { continue }
                let found = Concordance.occurrences(in: pages.pages, words: words, context: 40, limit: max(1, min(300, ConcordanceModel.maximumHits - total)))
                if !found.isEmpty {
                    let ext = url.pathExtension.lowercased()
                    let book = DuplicateFinder.bookExtensions.contains(ext) ? BookInfo.read(url).name : nil
                    let numbers = Records.pageNumbers
                    let hits = found.map { occurrence -> Hit in
                        let pdfPage = pages.isPaged ? pages.firstPage + occurrence.unit : nil
                        let page: String? = pdfPage.map { number in
                            pages.unit == "页" ? numbers.printed(path: path, pdfPage: number, label: pages.label(ofPage: number)).text : String(number)
                        }
                        return Hit(pdfPage: pdfPage, page: page, unit: pages.unit == "页" ? "页" : "张", occurrence: occurrence)
                    }
                    total += hits.count
                    let group = Group(path: path, title: book?.title ?? url.deletingPathExtension().lastPathComponent, book: book, hits: hits)
                    DispatchQueue.main.async {
                        guard current == self.token else { return }
                        self.groups.append(group)
                        self.sortGroups()
                    }
                }
                let done = number + 1
                DispatchQueue.main.async { if current == self.token { self.checked = (done, candidates.count) } }
                if total >= ConcordanceModel.maximumHits { break }
            }
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                self.running = false
                var text = self.groups.isEmpty ? "没有找到。只能汇编 Spotlight 已建立内容索引的文件和已识别的扫描件。" : "完成：" + self.summary
                if total >= ConcordanceModel.maximumHits { text += "已达 \(ConcordanceModel.maximumHits) 处上限，请加 in: 或 ext: 缩小范围。" }
                if skipped > 0 { text += "另有 \(skipped) 个文件未列出（范围之外或超过 \(ConcordanceModel.maximumFiles) 个文件的上限）。" }
                self.status = text
            }
        }
    }

    /// The reader's 常用本 first (0.28), then the books with most occurrences.
    func sortGroups() {
        let editions = Records.editions
        groups.sort { a, b in
            let preferredA = editions.isPreferred(a.path), preferredB = editions.isPreferred(b.path)
            if preferredA != preferredB { return preferredA }
            return a.hits.count != b.hits.count ? a.hits.count > b.hits.count : a.title < b.title
        }
    }

    func togglePreferred(_ group: Group) {
        Records.togglePreferred(group.path)
        sortGroups()
    }

    // MARK: Actions

    func open(_ hit: Hit, in group: Group) {
        let url = URL(fileURLWithPath: group.path)
        switch url.pathExtension.lowercased() {
        case "pdf": PDFOpener.open(url, page: hit.pdfPage, words: words)
        case "pptx":
            if let page = hit.pdfPage { PowerPoint.open(group.path, slide: page) { _ in } } else { NSWorkspace.shared.open(url) }
        default: NSWorkspace.shared.open(url)
        }
    }

    func reference(_ hit: Hit, in group: Group) -> String {
        if let book = group.book {
            return Citation.make(Preferences.citationStyle, name: book, fallbackTitle: book.title, page: hit.pdfPage, pageLabel: hit.page).text
        }
        return "《\(group.title)》" + (hit.page.map { "第 \($0) \(hit.unit == "张" ? "张幻灯片" : "页")" } ?? "")
    }

    func copy(_ hit: Hit, in group: Group) {
        let text = "“\(hit.occurrence.before.replacingOccurrences(of: "…", with: ""))\(hit.occurrence.match)\(hit.occurrence.after.replacingOccurrences(of: "…", with: ""))”\n" + reference(hit, in: group)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "已拷贝这一处和出处。"
    }

    private var exportName: String {
        "“" + (words.joined(separator: " ").isEmpty ? "出处" : words.joined(separator: " ")) + "”出处汇编"
    }

    func exportWord() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = exportName + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var blocks: [DocxWriter.Block] = [
            .heading(exportName, level: 1),
            .paragraph([.init("共 \(groups.count) 种文献、\(hitCount) 处；\(Date().formatted(date: .numeric, time: .omitted)) 由 KongSeek 汇编。页码为书上所印页码（未设对应时为 PDF 页码）。", gray: true)]),
        ]
        for group in groups {
            let reference = group.book.map { Citation.make(Preferences.citationStyle, name: $0, fallbackTitle: $0.title).text } ?? "《\(group.title)》"
            blocks.append(.heading("\(reference)（\(group.hits.count) 处）", level: 2))
            for hit in group.hits {
                var runs: [DocxWriter.Run] = []
                if let page = hit.page { runs.append(.init("第 \(page) \(hit.unit)：", bold: true)) }
                runs.append(.init(hit.occurrence.before))
                runs.append(.init(hit.occurrence.match, bold: true, highlight: true))
                runs.append(.init(hit.occurrence.after))
                blocks.append(.paragraph(runs))
            }
        }
        do {
            try DocxWriter.write(blocks, to: url)
            status = "已导出到 \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportExcel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.nameFieldStringValue = exportName + ".xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var cells: [[XLSXWriter.Cell]] = [["书名", "作者", "页码", "前文", "命中", "后文", "出处", "文件"].map { .text($0) }]
        for group in groups {
            for hit in group.hits {
                let page: XLSXWriter.Cell
                if let text = hit.page, let number = Int(text) { page = .number(Double(number)) } else { page = .text(hit.page ?? "") }
                cells.append([.text(group.title), .text(group.book?.authors ?? ""), page, .text(hit.occurrence.before), .text(hit.occurrence.match),
                              .text(hit.occurrence.after), .text(reference(hit, in: group)), .text(group.path)])
            }
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try XLSXWriter.write(rows: cells, columnWidths: [30, 16, 8, 40, 10, 40, 50, 50], sheetName: "出处汇编", to: url)
            status = "已导出到 \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct ConcordanceView: View {
    @ObservedObject var model: ConcordanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("要汇编的词，如 天理、\"格物致知\"；可加 in:讲义 ext:pdf", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.run() }
                if model.running {
                    if model.checked.total > 0 { Text("\(model.checked.done) / \(model.checked.total)").font(.caption).foregroundColor(.secondary) }
                    ProgressView().controlSize(.small)
                    Button("停止") { model.stop() }
                } else {
                    Button("汇编") { model.run() }.keyboardShortcut(.defaultAction)
                }
                Menu("导出") {
                    Button("Word 文档（.docx）…") { model.exportWord() }
                    Button("Excel 表格（.xlsx）…") { model.exportExcel() }
                }
                .frame(width: 70)
                .disabled(model.groups.isEmpty || model.running)
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.hits) { hit in row(hit, group: group) }
                    } header: {
                        HStack {
                            if Records.editions.isPreferred(group.path) {
                                Text("常用本").font(.caption2.weight(.semibold)).foregroundColor(.accentColor)
                            }
                            Text(group.title).font(.headline).lineLimit(1)
                            if let authors = group.book?.authors { Text(authors).foregroundColor(.secondary).lineLimit(1) }
                            Spacer()
                            Text("\(group.hits.count) 处").foregroundColor(.secondary)
                            Menu("…") {
                                Button(Records.editions.isPreferred(group.path) ? String("取消常用本") : String("设为常用本（排在最前）")) {
                                    model.togglePreferred(group)
                                }
                                if group.book != nil {
                                    Button("补全书目信息…") { BookLookupWindowController.shared.present(path: group.path) }
                                }
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.path)]) }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func row(_ hit: ConcordanceModel.Hit, group: ConcordanceModel.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hit.page.map { "第 \($0) \(hit.unit)" } ?? "").font(.caption.monospacedDigit()).foregroundColor(.accentColor).frame(width: 78, alignment: .leading)
            (Text(hit.occurrence.before).foregroundColor(.secondary) + Text(hit.occurrence.match).bold().foregroundColor(.orange)
                + Text(hit.occurrence.after).foregroundColor(.secondary))
                .lineLimit(2)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(hit, in: group) }
        .contextMenu {
            Button("打开到此处") { model.open(hit, in: group) }
            Button("拷贝这一处和出处") { model.copy(hit, in: group) }
        }
        .help("双击打开到此处；右键拷贝这一处和出处")
    }
}

final class ConcordanceWindowController: NSWindowController {
    let model: ConcordanceModel

    init(ocr: OCRStore) {
        model = ConcordanceModel(ocr: ocr)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "出处汇编"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ConcordanceView(model: model))
        window.setContentSize(NSSize(width: 900, height: 660))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window; with `query`, fills it in and runs it.
    func present(query: String? = nil) {
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            model.query = query
            model.run()
        }
    }
}
