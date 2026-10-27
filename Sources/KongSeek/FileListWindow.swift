import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore
import KongSeekText

/// What a file list shows (0.19).
enum FileListSource {
    /// Search results passed on from the search window.
    case paths([String], title: String)
    /// A (saved) search, run again.
    case query(String)
    /// Everything in a folder and its subfolders.
    case folder(String)
    /// A list saved under a name (0.24).
    case saved(UUID)
}

/// One file in the list, with what its name (and, for books, its metadata) says.
struct FileRow: Identifiable {
    let id: String
    var name: String
    var format: String
    var size: Int64
    var modified: Date
    var isLocal: Bool
    var isBook: Bool
    var title: String
    var authors: String
    var publisher: String
    var year: String
    var state: String
    var book: EbookName
    var location: String
    /// "读到第 N 页 / 共 M 页" from KongSeek's reader (0.24), and 0…1 for sorting.
    var reading: String = ""
    var readingFraction: Double = -1

    var path: String { id }
}

/// "文件清单": search results or a folder as a table, to copy a reference list, export
/// a book list, set reading states or move files to the Trash in one go (0.19).
final class FileListModel: ObservableObject {
    @Published private(set) var rows: [FileRow] = []
    @Published var selection = Set<String>()
    @Published var filter = ""
    @Published var booksOnly = false
    @Published var sortOrder = [KeyPathComparator(\FileRow.title, comparator: .localizedStandard)]
    @Published private(set) var loading = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published var status = ""
    @Published private(set) var heading = ""
    /// The saved list being shown, if any (0.24).
    @Published private(set) var savedList: SavedFileList?
    /// Saved lists, for the 清单 menu.
    @Published private(set) var savedLists: [SavedFileList] = Records.lists.lists

    private let service: IndexService
    private var token = 0

    init(service: IndexService) {
        self.service = service
    }

    var shown: [FileRow] {
        let words = filter.split(separator: " ").map(String.init)
        return rows.filter { row in
            (!booksOnly || row.isBook) && words.allSatisfy { word in
                [row.name, row.title, row.authors, row.publisher].contains { $0.localizedCaseInsensitiveContains(word) }
                    || [row.name, row.title, row.authors].contains { SearchText.simplifiedChinese($0).localizedCaseInsensitiveContains(SearchText.simplifiedChinese(word)) }
            }
        }.sorted(using: sortOrder)
    }

    /// The selected rows, or all shown when none is selected.
    var targets: [FileRow] {
        let visible = shown
        let picked = visible.filter { selection.contains($0.id) }
        return picked.isEmpty ? visible : picked
    }

    var targetDescription: String {
        let picked = shown.filter { selection.contains($0.id) }.count
        return picked == 0 ? "全部 \(shown.count) 项" : "所选 \(picked) 项"
    }

    // MARK: Loading

    func load(_ source: FileListSource) {
        token += 1
        let current = token
        rows = []
        selection = []
        loading = true
        status = "正在读取…"
        savedList = nil
        savedLists = Records.lists.lists
        switch source {
        case .paths(let paths, let title):
            heading = "搜索“\(title)”的结果"
            build(paths, token: current)
        case .saved(let id):
            guard let list = Records.lists.lists.first(where: { $0.id == id }) else {
                heading = "清单"
                loading = false
                status = "这个清单已被删除。"
                return
            }
            savedList = list
            heading = "清单：\(list.name)"
            build(list.paths, token: current)
        case .query(let text):
            heading = "搜索“\(text)”的结果"
            service.search(text, precision: Preferences.precision, limit: 3_000) { [weak self] outcome in
                self?.build(outcome.items.filter { $0.isFile && !$0.isFolder && !$0.isInArchive }.map(\.path), token: current)
            }
        case .folder(let folder):
            heading = (folder as NSString).abbreviatingWithTildeInPath
            service.fileEntries(under: folder, minimumSize: 1) { [weak self] entries in
                self?.build(entries.map(\.path), token: current)
            }
        }
    }

    /// Reads names, sizes, reading states and (for books) metadata in the background.
    private func build(_ paths: [String], token current: Int) {
        let files = paths.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let missing = paths.count - files.count
        progress = (0, files.count)
        let reading = Records.reading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var built: [FileRow] = []
            for (index, path) in files.enumerated() {
                guard let self, current == self.token else { return }
                built.append(FileListModel.row(for: path, reading: reading))
                if index % 50 == 49 {
                    let done = index + 1
                    DispatchQueue.main.async { if current == self.token { self.progress = (done, files.count) } }
                }
            }
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                self.rows = built
                self.loading = false
                let books = built.filter(\.isBook).count
                self.status = "\(built.count) 个文件，其中电子书 \(books) 本。选中几项只处理所选，不选则处理全部。"
                if self.savedList != nil && missing > 0 {
                    self.status = "清单中有 \(missing) 个文件已不在原处（被移动、改名或删除），未列出。" + self.status
                }
            }
        }
    }

    static func row(for path: String, reading: ReadingLog? = nil) -> FileRow {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        let isBook = DuplicateFinder.bookExtensions.contains(ext)
        let book = isBook ? BookInfo.read(url).name : EbookName(title: url.deletingPathExtension().lastPathComponent)
        var row = FileRow(id: path, name: url.lastPathComponent, format: ext.uppercased(), size: Int64(values?.fileSize ?? 0),
                          modified: values?.contentModificationDate ?? .distantPast, isLocal: values?.ubiquitousItemDownloadingStatus != .notDownloaded,
                          isBook: isBook, title: book.title, authors: book.authors ?? "", publisher: book.publisher ?? "", year: book.year ?? "",
                          state: FinderTags.readingState(of: path) ?? "", book: book,
                          location: SearchWindowController.displayLocation(of: path))
        if let entry = reading?.entry(for: path) {
            row.reading = entry.progressText
            row.readingFraction = entry.fraction
        }
        return row
    }

    // MARK: Saved lists (0.24)

    /// Saves the files in the list (all of them, not only those shown) under a name.
    func saveList(window: NSWindow?) {
        guard !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = savedList == nil ? "把这份清单存起来" : "保存清单"
        alert.informativeText = "以后可从 菜单栏图标 › 写作与引文 › 已保存的清单，或本窗口的“清单”菜单中再次打开。共 \(rows.count) 个文件。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = savedList?.name ?? suggestedName
        field.placeholderString = "如：本学期书单、论文参考书"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = SavedFileLists.cleanName(field.stringValue)
        guard !name.isEmpty else {
            status = "清单名称不能为空。"
            return
        }
        var lists = Records.lists
        if let existing = lists.list(named: name), existing.id != savedList?.id {
            let confirm = NSAlert()
            confirm.messageText = "已有名为“\(name)”的清单，替换它吗？"
            confirm.informativeText = "原清单有 \(existing.paths.count) 个文件。"
            confirm.addButton(withTitle: "替换")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        if let current = savedList, current.name != name, lists.list(named: name) == nil {
            // Renaming the list being shown.
            _ = lists.rename(id: current.id, to: name)
        }
        guard let saved = lists.save(name: name, paths: rows.map(\.path)) else { return }
        Records.lists = lists
        savedList = saved
        savedLists = lists.lists
        heading = "清单：\(saved.name)"
        status = "已保存清单“\(saved.name)”（\(saved.paths.count) 个文件）。"
    }

    func deleteSavedList() {
        guard let list = savedList else { return }
        let alert = NSAlert()
        alert.messageText = "删除清单“\(list.name)”？"
        alert.informativeText = "只删除这份清单本身，清单中的文件不受影响。"
        alert.addButton(withTitle: "删除清单")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var lists = Records.lists
        lists.remove(id: list.id)
        Records.lists = lists
        savedLists = lists.lists
        savedList = nil
        status = "已删除清单“\(list.name)”，文件未动。"
    }

    private var suggestedName: String {
        heading.replacingOccurrences(of: "搜索“", with: "").replacingOccurrences(of: "”的结果", with: "")
    }

    // MARK: Actions

    /// Sorting key for a reference list: the first author's (or the title's) pinyin.
    static func sortKey(_ row: FileRow) -> String {
        let lead = row.authors.isEmpty ? row.title : row.authors
        let latin = lead.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? lead
        return latin.lowercased()
    }

    func copyReferences(_ style: Citation.Style) {
        let books = targets.filter(\.isBook).sorted { Self.sortKey($0) < Self.sortKey($1) }
        guard !books.isEmpty else {
            status = "没有电子书（PDF、EPUB 等）可生成参考文献。"
            return
        }
        var incomplete = 0
        let lines = books.map { row -> String in
            let result = Citation.make(style, name: row.book, fallbackTitle: row.title)
            if !result.missing.isEmpty { incomplete += 1 }
            return result.text
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        status = "已拷贝 \(books.count) 条参考文献（按作者拼音排序）" + (incomplete > 0 ? "；其中 \(incomplete) 条缺出版地、出版者或出版年，请补全。" : "。")
    }

    /// The book list as an Excel workbook (bold, frozen header, column widths; 0.22) or as CSV.
    func exportList(window: NSWindow?, excel: Bool = true) {
        let rows = targets
        let panel = NSSavePanel()
        panel.allowedContentTypes = [excel ? (UTType(filenameExtension: "xlsx") ?? .data) : .commaSeparatedText]
        panel.nameFieldStringValue = excel ? "书单.xlsx" : "书单.csv"
        panel.message = excel ? "导出为 Excel 表格" : "导出为 CSV 表格（Excel、Numbers 可直接打开）"
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if excel {
                let header = ["书名", "作者", "出版社", "出版年", "格式", "大小（MB）", "阅读状态", "文件名", "位置"].map { XLSXWriter.Cell.text($0) }
                let body = rows.map { row -> [XLSXWriter.Cell] in
                    [.text(row.title), .text(row.authors), .text(row.publisher), .text(row.year), .text(row.format),
                     .number((Double(row.size) / 100_000).rounded() / 10), .text(row.state), .text(row.name), .text(row.path)]
                }
                do {
                    try? FileManager.default.removeItem(at: url)
                    try XLSXWriter.write(rows: [header] + body, columnWidths: [40, 22, 22, 8, 8, 11, 10, 40, 60], sheetName: "书单", to: url)
                    self?.status = "已导出 \(rows.count) 项到 \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self?.status = "导出失败：\(error.localizedDescription)"
                }
                return
            }
            func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var lines = [["书名", "作者", "出版社", "出版年", "格式", "大小（MB）", "阅读状态", "文件名", "位置"].map(field).joined(separator: ",")]
            for row in rows {
                lines.append([row.title, row.authors, row.publisher, row.year, row.format, String(format: "%.1f", Double(row.size) / 1_000_000),
                              row.state, row.name, row.path].map(field).joined(separator: ","))
            }
            do {
                // A byte-order mark so Excel reads the Chinese as UTF-8.
                try ("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
                self?.status = "已导出 \(rows.count) 项到 \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.status = "导出失败：\(error.localizedDescription)"
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    func setState(_ state: String?) {
        var changed = 0
        for row in targets where FinderTags.setReadingState(state, on: row.path) {
            changed += 1
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].state = state ?? "" }
        }
        status = state.map { "已把 \(changed) 项标为“\($0)”" } ?? "已清除 \(changed) 项的阅读状态"
    }

    func trash() {
        let victims = targets
        guard !victims.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "把\(selection.isEmpty ? "清单中全部" : "所选") \(victims.count) 个文件移到废纸篓？"
        alert.informativeText = victims.prefix(8).map { "• \($0.name)" }.joined(separator: "\n") + (victims.count > 8 ? "\n…" : "") + "\n\n可以从废纸篓放回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var moved: Set<String> = []
        for row in victims where Records.trashed(URL(fileURLWithPath: row.path), source: "文件清单") {
            moved.insert(row.id)
        }
        rows.removeAll { moved.contains($0.id) }
        selection.subtract(moved)
        status = "已移到废纸篓 \(moved.count) 个" + (moved.count < victims.count ? "；\(victims.count - moved.count) 个未能移动" : "")
    }

    func open(_ ids: Set<String>) {
        for id in ids.prefix(10) { NSWorkspace.shared.open(URL(fileURLWithPath: id)) }
    }

    func reveal(_ ids: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }
}

struct FileListView: View {
    @ObservedObject var model: FileListModel
    var window: () -> NSWindow?

    private var saveTitle: String { model.savedList == nil ? "保存为清单…" : "保存 / 重命名清单…" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(model.heading).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu("清单") {
                    Button(saveTitle) { model.saveList(window: window()) }
                        .disabled(model.rows.isEmpty)
                    if model.savedList != nil {
                        Button("删除此清单…") { model.deleteSavedList() }
                    }
                    if !model.savedLists.isEmpty {
                        Divider()
                        ForEach(model.savedLists) { list in
                            Button("\(list.name)（\(list.paths.count)）") { model.load(.saved(list.id)) }
                        }
                    }
                }
                .frame(width: 80)
                TextField("筛选书名、作者、出版社", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle("只看电子书", isOn: $model.booksOnly)
            }
            if model.loading {
                ProgressView(value: Double(model.progress.done), total: Double(max(1, model.progress.total))) {
                    Text("正在读取 \(model.progress.done) / \(model.progress.total)").font(.caption)
                }
            }
            Table(model.shown, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("封面", value: \.name, comparator: .localizedStandard) { row in
                    ThumbnailView(path: row.path, size: 40)
                }
                .width(36)
                TableColumn("书名 / 文件", value: \.title, comparator: .localizedStandard) { row in
                    Text(row.title).help(row.name)
                }
                TableColumn("作者", value: \.authors, comparator: .localizedStandard) { row in Text(row.authors) }
                TableColumn("出版社", value: \.publisher, comparator: .localizedStandard) { row in Text(row.publisher) }
                TableColumn("年份", value: \.year) { row in Text(row.year) }
                    .width(min: 40, ideal: 48, max: 60)
                TableColumn("格式", value: \.format) { row in Text(row.format) }
                    .width(min: 40, ideal: 48, max: 60)
                TableColumn("大小", value: \.size) { row in
                    Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)).foregroundColor(row.isLocal ? .primary : .secondary)
                        .help(row.isLocal ? "" : "只在 iCloud 中")
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("阅读状态", value: \.state) { row in Text(row.state) }
                    .width(min: 50, ideal: 60, max: 80)
                TableColumn("阅读进度", value: \.readingFraction) { row in
                    Text(row.reading).foregroundColor(.secondary).help(row.reading.isEmpty ? "在 KongSeek 的阅读窗口中读过的 PDF 会显示读到第几页" : row.reading)
                }
                .width(min: 80, ideal: 130, max: 170)
                TableColumn("位置", value: \.location, comparator: .localizedStandard) { row in
                    Text(row.location).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("打开") { model.open(ids) }
                Button("在访达中显示") { model.reveal(ids) }
            } primaryAction: { ids in
                model.open(ids)
            }
            HStack(spacing: 8) {
                Menu("拷贝参考文献（\(model.targetDescription)）") {
                    ForEach(Citation.Style.allCases, id: \.self) { style in
                        Button(style.title) { model.copyReferences(style) }
                    }
                }
                .frame(width: 250)
                Menu("导出书单") {
                    Button("Excel 表格（.xlsx）…") { model.exportList(window: window(), excel: true) }
                    Button("CSV 表格…") { model.exportList(window: window(), excel: false) }
                }
                .frame(width: 110)
                Menu("阅读状态") {
                    ForEach(FinderTags.readingStates, id: \.self) { state in
                        Button(state) { model.setState(state) }
                    }
                    Divider()
                    Button("清除") { model.setState(nil) }
                }
                .frame(width: 110)
                Button("打包…") {
                    CoursePackageWindowController.shared.start(paths: model.targets.map(\.path), name: model.heading)
                }
                .help("把所选（或全部）文件复制到一个文件夹或打成 zip，方便发给学生或拷进 U 盘")
                Spacer()
                Button("移到废纸篓…") { model.trash() }
            }
            .disabled(model.loading || model.rows.isEmpty)
            Text(model.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
    }
}

final class FileListWindowController: NSWindowController {
    let model: FileListModel

    init(service: IndexService) {
        model = FileListModel(service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "文件清单"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: FileListView(model: model, window: { [weak window] in window }))
        window.setContentSize(NSSize(width: 1000, height: 640))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(_ source: FileListSource) {
        model.load(source)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Asks for a folder and lists it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "列出"
        panel.message = "列出哪个文件夹中的文件（含子文件夹）？"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { present(.folder(url.path)) }
    }
}
