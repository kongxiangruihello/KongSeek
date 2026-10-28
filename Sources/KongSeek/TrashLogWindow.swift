import AppKit
import SwiftUI
import KongSeekCore

/// "废纸篓记录" (0.24): what KongSeek moved to the Trash in the last three months,
/// from where and by which feature, with 放回 to the original folder.
final class TrashLogModel: ObservableObject {
    struct Row: Identifiable {
        var entry: TrashLog.Entry
        var state: TrashLog.State
        var id: UUID { entry.id }
        var name: String { entry.name }
        var date: Date { entry.date }
        var stateText: String {
            switch state {
            case .inTrash: return "在废纸篓中"
            case .restored: return "已放回"
            case .gone: return "已不在废纸篓"
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selection = Set<UUID>()
    @Published var filter = ""
    @Published var onlyInTrash = true
    @Published private(set) var status = ""

    var shown: [Row] {
        let words = filter.split(whereSeparator: \.isWhitespace).map { SearchText.fold(String($0)) }
        return rows.filter { row in
            (!onlyInTrash || row.state == .inTrash)
                && words.allSatisfy { SearchText.fold(row.entry.original + " " + row.entry.source).contains($0) }
        }
    }

    func reload() {
        let log = Records.trash
        rows = log.entries.map { Row(entry: $0, state: log.state(of: $0)) }
        let waiting = rows.filter { $0.state == .inTrash }
        let size = waiting.reduce(Int64(0)) { $0 + $1.entry.size }
        status = waiting.isEmpty
            ? "KongSeek 移到废纸篓的文件都已不在废纸篓中。记录保留三个月。"
            : "\(waiting.count) 个文件仍在废纸篓中（共 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))），可以放回原处。记录保留三个月。"
        selection = selection.filter { id in rows.contains { $0.id == id } }
    }

    func putBack(_ ids: Set<UUID>) {
        var log = Records.trash
        var restored: [String] = [], occupied: [String] = [], failed: [String] = []
        for row in shown where ids.contains(row.id) && row.state == .inTrash {
            switch log.putBack(row.id) {
            case .success: restored.append(row.name)
            case .failure(.occupied): occupied.append(row.name)
            case .failure: failed.append(row.name)
            }
        }
        Records.trash = log
        reload()
        var text = restored.isEmpty ? "" : "已放回 \(restored.count) 个：" + restored.prefix(5).joined(separator: "、") + (restored.count > 5 ? "等" : "") + "。"
        if !occupied.isEmpty { text += "原位置已有同名文件，未放回：" + occupied.joined(separator: "、") + "。" }
        if !failed.isEmpty { text += "无法放回：" + failed.joined(separator: "、") + "。" }
        if text.isEmpty { text = "所选文件已不在废纸篓中。" }
        status = text
    }

    func reveal(_ ids: Set<UUID>) {
        let urls = rows.filter { ids.contains($0.id) }.compactMap { row -> URL? in
            switch row.state {
            case .inTrash: return URL(fileURLWithPath: row.entry.trashed)
            case .restored: return URL(fileURLWithPath: row.entry.original)
            case .gone: return nil
            }
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openFolder(_ row: Row) {
        let folder = URL(fileURLWithPath: row.entry.folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) } else { status = "原文件夹已不存在：\(row.entry.folder)" }
    }
}

struct TrashLogView: View {
    @ObservedObject var model: TrashLogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("筛选文件名、文件夹或功能", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 260)
                Toggle("只看仍在废纸篓中的", isOn: $model.onlyInTrash)
                Spacer()
                Button("刷新") { model.reload() }
            }
            Table(model.shown, selection: $model.selection) {
                TableColumn("时间") { row in
                    Text(row.date.formatted(date: .numeric, time: .shortened)).foregroundColor(.secondary)
                }
                .width(min: 110, ideal: 130, max: 150)
                TableColumn("文件") { row in Text(row.name).help(row.entry.original) }
                TableColumn("原来的位置") { row in
                    Text(SearchWindowController.displayLocation(of: row.entry.original)).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("移除自") { row in Text(row.entry.source) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("大小") { row in Text(ByteCountFormatter.string(fromByteCount: row.entry.size, countStyle: .file)) }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("状态") { row in
                    Text(row.stateText).foregroundColor(row.state == .inTrash ? .orange : .secondary)
                }
                .width(min: 70, ideal: 90, max: 110)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("放回原处") { model.putBack(ids) }
                Button("在访达中显示") { model.reveal(ids) }
                if ids.count == 1, let row = model.rows.first(where: { ids.contains($0.id) }) {
                    Button("打开原来的文件夹") { model.openFolder(row) }
                }
            }
            HStack {
                Button("放回原处") { model.putBack(model.selection) }
                    .disabled(!model.shown.contains { model.selection.contains($0.id) && $0.state == .inTrash })
                Button("在访达中显示") { model.reveal(model.selection) }.disabled(model.selection.isEmpty)
                Spacer()
                Text("只记录 KongSeek 移到废纸篓的文件；KongSeek 不会清倒废纸篓。").font(.caption).foregroundColor(.secondary)
            }
            Text(model.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 460)
    }
}

final class TrashLogWindowController: NSWindowController {
    let model = TrashLogModel()
    private var observer: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "废纸篓记录"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: TrashLogView(model: model))
        window.setContentSize(NSSize(width: 900, height: 540))
        observer = NotificationCenter.default.addObserver(forName: Records.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.model.reload()
        }
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
