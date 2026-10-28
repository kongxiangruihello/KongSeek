import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore
import KongSeekText

/// "稿件引文核对" (0.23): every quotation in a manuscript (text in “…” or 「…」)
/// checked against the library with 引文查证, one after another, as a table to go
/// through before the manuscript is finished.
final class ManuscriptCheckModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var number: Int
        var quote: ManuscriptQuotes.Quote
        var state: State = .waiting
        var best: QuoteLookup.Result?
        var others = 0

        enum State: Equatable { case waiting, checking, done }

        var verdict: String {
            switch state {
            case .waiting: return "待核对"
            case .checking: return "核对中…"
            case .done: return QuoteVerdict.text(score: best?.score)
            }
        }

        /// 逐字异文 against the passage found (0.26), for near matches.
        var differences: [QuoteDiff.Segment]? {
            guard let best, !best.exact else { return nil }
            let segments = QuoteDiff.compare(quote: quote.text, source: best.excerpt)
            return QuoteDiff.differs(segments) ? segments : nil
        }
    }

    @Published private(set) var manuscript: URL?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var running = false
    @Published private(set) var status = "选择一篇稿件（Word、文本、Markdown 或 PDF），找出其中引号内的引文，逐条到书库中查证。"
    @Published var selection: Row.ID?
    private let lookup: QuoteLookup
    private var stopped = false

    init(ocr: OCRStore) {
        lookup = QuoteLookup(ocr: ocr)
    }

    var summary: String {
        QuoteVerdict.summary(rows.map { row -> Double?? in row.state == .done ? .some(row.best?.score) : nil })
    }

    /// Set while the manuscript is being read (0.26: in the background, so a long PDF does not freeze the window).
    @Published private(set) var reading = false

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["docx", "doc", "odt", "rtf", "txt", "md", "pdf"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择要核对引文的稿件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        stop()
        manuscript = url
        rows = []
        reading = true
        status = "正在读取稿件…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ManuscriptCheckModel.readQuotes(url)
            DispatchQueue.main.async {
                guard let self, self.manuscript == url else { return }
                self.reading = false
                switch outcome {
                case .success(let quotes):
                    self.rows = quotes.enumerated().map { Row(number: $0.offset + 1, quote: $0.element) }
                    let inNotes = quotes.filter { $0.context.hasPrefix("〔注〕") }.count
                    self.status = quotes.isEmpty
                        ? "稿件中没有找到引号内的引文（至少 \(ManuscriptQuotes.minimumLength) 个字）。"
                        : "找到 \(quotes.count) 条引文" + (inNotes > 0 ? "（其中脚注、尾注中 \(inNotes) 条）" : "") + "，点“开始核对”。"
                case .failure(let message):
                    self.status = message
                }
            }
        }
    }

    private enum ReadOutcome { case success([ManuscriptQuotes.Quote]), failure(String) }

    /// The quotations of the body, then those of a Word document's footnotes and endnotes
    /// (marked 〔注〕 in their context), each quotation once.
    private static func readQuotes(_ url: URL) -> ReadOutcome {
        let pages: DocumentText.Pages
        do {
            pages = try DocumentText.read(url, maximumPages: 5_000, downloadWait: 60)
        } catch DocumentText.Failure.unsupported(let ext) {
            return .failure("无法读取 .\(ext) 文件。请另存为 Word（.docx）、文本或 PDF 后再选。")
        } catch DocumentText.Failure.noText(_) {
            return .failure("这是没有文字层的扫描版 PDF，读不出引文。")
        } catch DocumentText.Failure.notDownloaded, DocumentText.Failure.downloading {
            return .failure("稿件只在 iCloud 中，尚未下载完成。请在访达中打开一次后再选。")
        } catch {
            return .failure("无法读取稿件。")
        }
        var quotes = ManuscriptQuotes.extract(from: pages.pages.joined(separator: "\n"))
        if url.pathExtension.lowercased() == "docx", let notes = try? OfficeText.wordNotes(of: url) {
            var seen = Set(quotes.map { String(QuoteMatcher.normalized($0.text)) })
            for text in [notes.footnotes, notes.endnotes] where !text.isEmpty {
                for var quote in ManuscriptQuotes.extract(from: text) where seen.insert(String(QuoteMatcher.normalized(quote.text))).inserted {
                    quote.context = "〔注〕" + quote.context
                    quotes.append(quote)
                }
            }
        }
        return .success(quotes)
    }

    func start() {
        guard !rows.isEmpty, !running else { return }
        stopped = false
        running = true
        next()
    }

    /// Checks the next waiting quotation; one at a time, so Spotlight is not flooded.
    private func next() {
        guard !stopped, let index = rows.firstIndex(where: { $0.state == .waiting }) else {
            running = false
            status = stopped ? "已停止。" + summary : "核对完成。" + summary
            return
        }
        rows[index].state = .checking
        status = "正在核对第 \(index + 1) / \(rows.count) 条…"
        lookup.run(rows[index].quote.text, maximumCandidates: 80) { [weak self] outcome in
            guard let self, self.rows.indices.contains(index) else { return }
            self.rows[index].state = .done
            self.rows[index].best = outcome.results.first
            self.rows[index].others = max(0, outcome.results.count - 1)
            self.next()
        }
    }

    func stop() {
        stopped = true
        lookup.stop()
        if running {
            running = false
            for index in rows.indices where rows[index].state == .checking { rows[index].state = .waiting }
            status = "已停止。" + summary
        }
    }

    func recheck(_ row: Row) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index].state = .waiting
        rows[index].best = nil
        if !running { start() }
    }

    func open(_ row: Row) {
        guard let best = row.best else { return }
        let url = URL(fileURLWithPath: best.path)
        if url.pathExtension.lowercased() == "pdf" {
            PDFOpener.open(url, page: best.page, words: QuoteMatcher.probes(row.quote.text, length: 4))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func reference(_ row: Row) -> String {
        guard let best = row.best else { return "" }
        if let book = best.book {
            return Citation.make(Preferences.citationStyle, name: book, fallbackTitle: book.title, page: best.page, pageLabel: best.printed?.text).text
        }
        let place = best.printed.map { "第 \($0.text) 页" } ?? best.page.map { "第 \($0) \(best.unit)" }
        return "《\(((best.path as NSString).lastPathComponent as NSString).deletingPathExtension)》" + (place ?? "")
    }

    /// The quotation as the source writes it (0.26).
    /// Makes the source the 常用本 of its book, or stops it being one (0.28). Rows already
    /// checked keep their result; 重查 picks the preferred edition first.
    func togglePreferred(_ row: Row) {
        guard let best = row.best else { return }
        Records.togglePreferred(best.path)
        objectWillChange.send()
        status = Records.editions.isPreferred(best.path)
            ? "已把“\(best.title)”设为常用本：之后核对的引文优先取这一版本（已核对的可点“重查”）。"
            : "已取消“\(best.title)”的常用本。"
    }

    /// Asks which printed page this PDF page is (0.27); the book's other rows follow.
    func setPrintedPage(_ row: Row) {
        guard let best = row.best, let page = best.page, best.unit == "页" else { return }
        if PageNumberPrompt.ask(path: best.path, pdfPage: page, current: best.printed) { objectWillChange.send() }
    }

    /// A copy of the Word manuscript with a comment on each quotation that differs from its
    /// source or was not found (0.27). The manuscript itself is not changed.
    func writeComments() {
        guard let manuscript, manuscript.pathExtension.lowercased() == "docx" else { return }
        let flagged = rows.filter { $0.state == .done && ($0.best == nil || $0.best?.exact == false) && !$0.quote.context.hasPrefix("〔注〕") }
        guard !flagged.isEmpty else {
            status = "已核对的引文都与原文一致，不需要批注。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.directoryURL = manuscript.deletingLastPathComponent()
        panel.nameFieldStringValue = manuscript.deletingPathExtension().lastPathComponent + "（引文核对）.docx"
        panel.message = "原稿不动，另存一份在页边加了批注的副本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != manuscript.standardizedFileURL else {
            status = "请换一个文件名：原稿不会被覆盖。"
            return
        }
        let comments = flagged.map { row -> WordComments.Comment in
            var lines: [String] = []
            if let best = row.best {
                var head = "引文核对：\(row.verdict)"
                if let differences = row.differences { head += "，" + QuoteDiff.summary(differences) }
                lines.append(head)
                if row.differences != nil { lines.append("按原文改正：" + QuoteDiff.corrected(quote: row.quote.text, source: best.excerpt)) }
                lines.append("原文：" + best.excerpt)
                lines.append("出处：" + reference(row))
            } else {
                lines.append("引文核对：未在书库中找到出处（可能出自未建立内容索引的文件、未识别的扫描件，或与原文出入较大）。")
            }
            return WordComments.Comment(anchor: row.quote.text, text: lines.joined(separator: "\n"))
        }
        do {
            let placed = try WordComments.write(source: manuscript, destination: url, comments: comments)
            let count = placed.filter { $0 }.count
            status = "已在 \(count) 处加批注，存为“\(url.lastPathComponent)”" + (count < comments.count ? "；\(comments.count - count) 条在稿中没能定位到段落，未加。" : "。")
                + (rows.contains { $0.quote.context.hasPrefix("〔注〕") } ? "脚注中的引文不加批注，请看 Excel 核对表。" : "")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "生成批注副本失败：\(error.localizedDescription)"
        }
    }

    func copyCorrected(_ row: Row) {
        guard let best = row.best else { return }
        let corrected = QuoteDiff.corrected(quote: row.quote.text, source: best.excerpt)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(corrected, forType: .string)
        status = "已拷贝按原文改正的引文：\(corrected)"
    }

    func copyReference(_ row: Row) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference(row), forType: .string)
        status = "已拷贝出处：\(reference(row))"
    }

    /// The table as an Excel workbook, to keep with the manuscript.
    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.nameFieldStringValue = (manuscript?.deletingPathExtension().lastPathComponent ?? "稿件") + " 引文核对.xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var cells: [[XLSXWriter.Cell]] = [["序号", "引文", "稿中上文", "结果", "异文", "按原文改正", "出处", "页码", "原文", "文件"].map { .text($0) }]
        for row in rows {
            // The page printed in the book when known (0.27), else the PDF page.
            let page: XLSXWriter.Cell
            if let printed = row.best?.printed {
                if let number = Int(printed.text) { page = .number(Double(number)) } else { page = .text(printed.text) }
            } else if let number = row.best?.page { page = .number(Double(number)) } else { page = .text("") }
            let differences = row.differences
            let corrected = differences == nil ? "" : QuoteDiff.corrected(quote: row.quote.text, source: row.best?.excerpt ?? "")
            let line: [XLSXWriter.Cell] = [.number(Double(row.number)), .text(row.quote.text), .text(row.quote.context), .text(row.verdict),
                                           .text(differences.map(QuoteDiff.summary) ?? ""), .text(corrected),
                                           .text(reference(row)), page, .text(row.best?.excerpt ?? ""), .text(row.best?.path ?? "")]
            cells.append(line)
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try XLSXWriter.write(rows: cells, columnWidths: [6, 50, 24, 12, 30, 50, 50, 8, 50, 50], sheetName: "引文核对", to: url)
            status = "已导出到 \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct ManuscriptCheckView: View {
    @ObservedObject var model: ManuscriptCheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.manuscript?.lastPathComponent ?? "未选择稿件").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.reading { ProgressView().controlSize(.small) }
                Button("选择稿件…") { model.choose() }.disabled(model.running || model.reading)
                if model.running {
                    Button("停止") { model.stop() }
                } else {
                    Button("开始核对") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.rows.isEmpty)
                }
                Button("导出 Excel…") { model.export() }.disabled(model.rows.isEmpty || model.running)
                if model.manuscript?.pathExtension.lowercased() == "docx" {
                    Button("生成带批注的 Word…") { model.writeComments() }
                        .disabled(model.running || !model.rows.contains { $0.state == .done })
                        .help("另存一份稿件，在有异文、找不到出处的引文旁加 Word 批注；原稿不动")
                }
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.rows.isEmpty { Text(model.summary).font(.caption).foregroundColor(.secondary) }
            List(model.rows, selection: $model.selection) { row in
                rowView(row)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 560)
    }

    private func color(_ row: ManuscriptCheckModel.Row) -> Color {
        guard row.state == .done else { return .secondary }
        guard let best = row.best else { return .red }
        return best.exact ? .green : .orange
    }

    private func rowView(_ row: ManuscriptCheckModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(row.number)").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 26, alignment: .trailing)
                Text(row.verdict).font(.caption2.weight(.semibold)).foregroundColor(color(row)).frame(width: 64, alignment: .leading)
                Text("“\(row.quote.text)”").lineLimit(2)
                Spacer()
                if row.best != nil {
                    Button("打开到此处") { model.open(row) }.controlSize(.small)
                    Button("拷贝出处") { model.copyReference(row) }.controlSize(.small)
                    if let best = row.best {
                        Menu("更多") {
                            if best.unit == "页", best.page != nil {
                                Button("设置书上页码…") { model.setPrintedPage(row) }
                            }
                            Button(Records.editions.isPreferred(best.path) ? String("取消常用本") : String("设为常用本（同书多个版本时排在最前）")) {
                                model.togglePreferred(row)
                            }
                            if best.book != nil {
                                Button("补全书目信息…") { BookLookupWindowController.shared.present(path: best.path) }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                if row.state == .done { Button("重查") { model.recheck(row) }.controlSize(.small) }
            }
            if let best = row.best {
                Text("出处：" + model.reference(row) + (row.others > 0 ? "（另有 \(row.others) 处）" : ""))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).padding(.leading, 98)
                Text("原文：" + best.excerpt).font(.caption).foregroundColor(.secondary).lineLimit(2).padding(.leading, 98)
                if let differences = row.differences {
                    HStack(alignment: .firstTextBaseline) {
                        QuoteDiffText.line(differences).font(.caption).lineLimit(3)
                        Spacer()
                        Button("拷贝改正后的引文") { model.copyCorrected(row) }.controlSize(.small)
                            .help("按原文的用字改正这条引文（保留稿中的标点），拷贝下来贴回稿件")
                    }
                    .padding(.leading, 98)
                }
            } else if row.state == .done {
                Text("未在书库中找到。可能出自未建立内容索引的文件、未识别的扫描件、只在 iCloud 中的文件，或引文与原文出入较大。")
                    .font(.caption).foregroundColor(.secondary).padding(.leading, 98)
            }
        }
        .padding(.vertical, 2)
    }
}

final class ManuscriptCheckWindowController: NSWindowController {
    let model: ManuscriptCheckModel

    init(ocr: OCRStore) {
        model = ManuscriptCheckModel(ocr: ocr)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "稿件引文核对"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ManuscriptCheckView(model: model))
        window.setContentSize(NSSize(width: 960, height: 680))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(_ url: URL? = nil) {
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let url { model.load(url) } else if model.manuscript == nil { model.choose() }
    }
}
