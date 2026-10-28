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
            case .done:
                guard let best else { return "未找到" }
                return best.exact ? "完全一致" : "近似 \(Int((best.score * 100).rounded()))%"
            }
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
        let done = rows.filter { $0.state == .done }
        let exact = done.filter { $0.best?.exact == true }.count
        let near = done.filter { $0.best != nil && $0.best?.exact == false }.count
        let missing = done.filter { $0.best == nil }.count
        return "共 \(rows.count) 条引文：完全一致 \(exact)，近似 \(near)，未找到 \(missing)" + (done.count < rows.count ? "，待核对 \(rows.count - done.count)" : "")
    }

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
        do {
            let pages = try DocumentText.read(url, maximumPages: 5_000, downloadWait: 60)
            let quotes = ManuscriptQuotes.extract(from: pages.pages.joined(separator: "\n"))
            rows = quotes.enumerated().map { Row(number: $0.offset + 1, quote: $0.element) }
            status = quotes.isEmpty ? "稿件中没有找到引号内的引文（至少 \(ManuscriptQuotes.minimumLength) 个字）。" : "找到 \(quotes.count) 条引文，点“开始核对”。"
        } catch DocumentText.Failure.unsupported(let ext) {
            status = "无法读取 .\(ext) 文件。请另存为 Word（.docx）、文本或 PDF 后再选。"
        } catch DocumentText.Failure.noText(_) {
            status = "这是没有文字层的扫描版 PDF，读不出引文。"
        } catch DocumentText.Failure.notDownloaded, DocumentText.Failure.downloading {
            status = "稿件只在 iCloud 中，尚未下载完成。请在访达中打开一次后再选。"
        } catch {
            status = "无法读取稿件。"
        }
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
        if let book = best.book { return Citation.make(Preferences.citationStyle, name: book, fallbackTitle: book.title, page: best.page).text }
        return "《\(((best.path as NSString).lastPathComponent as NSString).deletingPathExtension)》" + (best.page.map { "第 \($0) \(best.unit)" } ?? "")
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
        var cells: [[XLSXWriter.Cell]] = [["序号", "引文", "稿中上文", "结果", "出处", "页码", "原文", "文件"].map { .text($0) }]
        for row in rows {
            let page: XLSXWriter.Cell
            if let number = row.best?.page { page = .number(Double(number)) } else { page = .text("") }
            let line: [XLSXWriter.Cell] = [.number(Double(row.number)), .text(row.quote.text), .text(row.quote.context), .text(row.verdict),
                                           .text(reference(row)), page, .text(row.best?.excerpt ?? ""), .text(row.best?.path ?? "")]
            cells.append(line)
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try XLSXWriter.write(rows: cells, columnWidths: [6, 50, 24, 12, 50, 8, 50, 50], sheetName: "引文核对", to: url)
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
                Button("选择稿件…") { model.choose() }.disabled(model.running)
                if model.running {
                    Button("停止") { model.stop() }
                } else {
                    Button("开始核对") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.rows.isEmpty)
                }
                Button("导出 Excel…") { model.export() }.disabled(model.rows.isEmpty || model.running)
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
                }
                if row.state == .done { Button("重查") { model.recheck(row) }.controlSize(.small) }
            }
            if let best = row.best {
                Text("出处：" + model.reference(row) + (row.others > 0 ? "（另有 \(row.others) 处）" : ""))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).padding(.leading, 98)
                Text("原文：" + best.excerpt).font(.caption).foregroundColor(.secondary).lineLimit(2).padding(.leading, 98)
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
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let url { model.load(url) } else if model.manuscript == nil { model.choose() }
    }
}
