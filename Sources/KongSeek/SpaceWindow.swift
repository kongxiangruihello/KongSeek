import AppKit
import SwiftUI
import KongSeekCore

/// "空间分析": the biggest files, big files untouched for years, and the folders
/// that use the most space, from the index (0.16).
final class SpaceModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case largest, stale, folders
        var id: String { rawValue }
        var title: String {
            switch self {
            case .largest: return "最大的文件"
            case .stale: return "久未修改的大文件"
            case .folders: return "占用最多的文件夹"
            }
        }
    }

    @Published var scope: DuplicatesModel.Scope = .everything
    @Published var view: Tab = .largest
    @Published var staleYears = 2
    @Published var localOnly = true
    @Published private(set) var running = false
    @Published private(set) var status = "点“分析”统计索引中的文件。只读取文件大小和日期，不打开文件。"
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var trashed: Set<String> = []

    private let service: IndexService

    init(service: IndexService) {
        self.service = service
    }

    private var roots: [String] {
        if case .folder(let path) = scope { return [Paths.canonical(path)] }
        return NameIndex.effectiveRoots(Preferences.roots, rules: Preferences.rules)
    }

    func analyze() {
        guard !running else { return }
        running = true
        status = "正在统计…"
        let folder: String? = { if case .folder(let path) = scope { return path } else { return nil } }()
        service.fileEntries(under: folder, minimumSize: 1) { [weak self] entries in
            guard let self else { return }
            self.files = entries
            self.trashed = []
            self.running = false
            let totals = SpaceReport.totals(entries)
            let size: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            self.status = "\(totals.files.formatted()) 个文件：占用本机 \(size(totals.local))" + (totals.cloudOnly > 0 ? "；另有 \(size(totals.cloudOnly)) 只在 iCloud 中，不占本机空间" : "") + "。"
        }
    }

    var largest: [FileEntry] { SpaceReport.largest(files.filter { !trashed.contains($0.path) }, localOnly: localOnly) }

    var stale: [FileEntry] {
        let before = Calendar.current.date(byAdding: .year, value: -staleYears, to: Date()) ?? Date()
        return SpaceReport.stale(files.filter { !trashed.contains($0.path) }, before: before, localOnly: localOnly)
    }

    var folders: [SpaceReport.FolderUsage] {
        SpaceReport.folders(files.filter { !trashed.contains($0.path) }, roots: roots, depth: 3, localOnly: localOnly)
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func trash(_ file: FileEntry) -> String? {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
            trashed.insert(file.path)
            return nil
        } catch {
            return "无法移到废纸篓：\(file.name)"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "分析哪个文件夹？"
        if panel.runModal() == .OK, let url = panel.url { scope = .folder(url.path) }
    }
}

struct SpaceView: View {
    @ObservedObject var model: SpaceModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("范围", selection: $model.scope) {
                    Text("全部已索引的文件夹").tag(DuplicatesModel.Scope.everything)
                    if case .folder(let path) = model.scope {
                        Text((path as NSString).abbreviatingWithTildeInPath).tag(model.scope)
                    }
                }
                .frame(width: 280)
                Button("选择文件夹…") { model.chooseFolder() }
                Toggle("只看占用本机空间的", isOn: $model.localOnly)
                    .help("只在 iCloud 中的文件（访达里带云朵图标）不占本机空间，默认不列出")
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("分析") { message = nil; model.analyze() }.keyboardShortcut(.defaultAction).disabled(model.running)
            }
            HStack {
                Picker("", selection: $model.view) {
                    ForEach(SpaceModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420)
                if model.view == .stale {
                    Picker("超过", selection: $model.staleYears) {
                        ForEach([1, 2, 3, 5], id: \.self) { Text("\($0) 年未修改").tag($0) }
                    }
                    .frame(width: 170)
                }
                Spacer()
            }
            Text(message ?? model.status).font(.callout).foregroundColor(message == nil ? .secondary : .orange).lineLimit(2)
            List {
                switch model.view {
                case .largest:
                    ForEach(model.largest, id: \.path) { fileRow($0) }
                case .stale:
                    ForEach(model.stale, id: \.path) { fileRow($0) }
                case .folders:
                    ForEach(model.folders, id: \.path) { folderRow($0) }
                }
            }
            .overlay {
                if model.files.isEmpty && !model.running {
                    Text("点“分析”开始").foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func fileRow(_ file: FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if !file.isLocal {
                        Text("仅在 iCloud").font(.caption2.weight(.semibold)).foregroundColor(.gray)
                    }
                }
                Text(SearchWindowController.displayLocation(of: file.path)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(size(file.size)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Text(file.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 100, alignment: .trailing)
            Button { model.open(file.path) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开")
            Button { model.reveal(file.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("在访达中显示")
            Button { confirmTrash(file) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("移到废纸篓（可从废纸篓放回）")
        }
        .padding(.vertical, 2)
    }

    private func folderRow(_ folder: SpaceReport.FolderUsage) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text((folder.path as NSString).lastPathComponent).lineLimit(1)
                Text(SearchWindowController.displayLocation(of: folder.path)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("\(folder.files.formatted()) 个文件").font(.caption).foregroundColor(.secondary)
            if folder.cloudOnly > 0 && !model.localOnly {
                Text("iCloud \(size(folder.cloudOnly))").font(.caption).foregroundColor(.secondary)
            }
            Text(size(folder.local)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Button { model.reveal(folder.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("在访达中显示")
        }
        .padding(.vertical, 2)
    }

    private func confirmTrash(_ file: FileEntry) {
        let alert = NSAlert()
        alert.messageText = "把“\(file.name)”移到废纸篓？"
        alert.informativeText = "\(size(file.size)) · \(SearchWindowController.displayLocation(of: file.path))\n\n可以从废纸篓放回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        message = model.trash(file)
    }
}

final class SpaceWindowController: NSWindowController {
    let model: SpaceModel

    init(service: IndexService) {
        model = SpaceModel(service: service)
        let window = NSWindow(contentViewController: NSHostingController(rootView: SpaceView(model: model)))
        window.title = "空间分析"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 620))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if model.files.isEmpty { model.analyze() }
    }
}
