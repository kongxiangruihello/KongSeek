import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore

/// 备注一览 (0.43): every file with a note, newest first, to read, filter, change or
/// delete in one place, and to export as an Excel or Word list.
final class NotesModel: ObservableObject {
    struct Row: Identifiable {
        var id: String { path }
        var path: String
        var text: String
        var date: Date
        var name: String { (path as NSString).lastPathComponent }
        var exists: Bool
    }

    @Published var filter = ""
    @Published private(set) var rows: [Row] = []
    @Published private(set) var status = ""
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Records.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        let notes = Records.notes.notes
        rows = notes.map { path, note in
            Row(path: path, text: note.text, date: note.date, exists: FileManager.default.fileExists(atPath: path))
        }.sorted { $0.date > $1.date }
        status = rows.isEmpty ? "还没有备注。在搜索结果上 ⌘K › 写备注… 即可添加。" : "共 \(rows.count) 条备注。"
    }

    var shown: [Row] {
        let terms = filter.split(separator: " ").map { SearchText.fold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return rows }
        return rows.filter { row in
            let text = SearchText.fold(row.text + " " + row.name)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    func save(_ row: Row, text: String) {
        var notes = Records.notes
        notes.set(text, for: row.path)
        Records.notes = notes
        status = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已删除“\(row.name)”的备注。" : "已保存“\(row.name)”的备注。"
    }

    func delete(_ row: Row) {
        save(row, text: "")
    }

    func open(_ row: Row) {
        NSWorkspace.shared.open(URL(fileURLWithPath: row.path))
    }

    func reveal(_ row: Row) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
    }

    func export(word: Bool) {
        let list = shown
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: word ? "docx" : "xlsx") ?? .data]
        panel.nameFieldStringValue = "KongSeek 备注." + (word ? "docx" : "xlsx")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            try? FileManager.default.removeItem(at: url)
            if word {
                var blocks: [DocxWriter.Block] = [.heading("备注", level: 1)]
                for row in list {
                    blocks.append(.heading(row.name, level: 2))
                    blocks.append(.paragraph([DocxWriter.Run(row.text)]))
                    blocks.append(.paragraph([DocxWriter.Run((row.path as NSString).abbreviatingWithTildeInPath + " · " + formatter.string(from: row.date))]))
                }
                try DocxWriter.write(blocks, to: url)
            } else {
                var cells: [[XLSXWriter.Cell]] = [["文件", "备注", "日期", "位置"].map { .text($0) }]
                for row in list {
                    cells.append([.text(row.name), .text(row.text), .text(formatter.string(from: row.date)), .text(row.path)])
                }
                try XLSXWriter.write(rows: cells, columnWidths: [36, 60, 12, 60], sheetName: "备注", to: url)
            }
            status = "已导出 \(list.count) 条备注到 \(url.lastPathComponent)。"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct NotesView: View {
    @ObservedObject var model: NotesModel
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("筛选备注或文件名", text: $model.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Menu("导出") {
                    Button("导出 Excel…") { model.export(word: false) }
                    Button("导出 Word…") { model.export(word: true) }
                }
                .fixedSize()
                .disabled(model.shown.isEmpty)
            }
            Text(model.status).font(.callout).foregroundColor(.secondary)
            List(model.shown) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            .foregroundColor(row.exists ? .primary : .secondary)
                        if !row.exists { Text("文件已不在").font(.caption).foregroundColor(.orange) }
                        Spacer()
                        Text(row.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundColor(.secondary)
                        Button("打开") { model.open(row) }.controlSize(.small).disabled(!row.exists)
                        Button("显示") { model.reveal(row) }.controlSize(.small).disabled(!row.exists)
                        Button(editing == row.path ? String("保存") : String("修改")) {
                            if editing == row.path {
                                model.save(row, text: draft)
                                editing = nil
                            } else {
                                draft = row.text
                                editing = row.path
                            }
                        }
                        .controlSize(.small)
                        Button("删除") { model.delete(row) }.controlSize(.small)
                    }
                    if editing == row.path {
                        TextField("备注", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                            .onSubmit { model.save(row, text: draft); editing = nil }
                    } else {
                        Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SearchWindowController.displayLocation(of: row.path)).font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 480)
    }
}

final class NotesWindowController: NSWindowController {
    let model = NotesModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "备注一览"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: NotesView(model: model))
        window.setContentSize(NSSize(width: 720, height: 560))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        model.reload()
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
