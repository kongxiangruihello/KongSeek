import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// State of the "重复与相似文件" window.
final class DuplicatesModel: ObservableObject {
    enum Scope: Hashable {
        case everything
        case folder(String)
    }

    @Published var scope: Scope = .everything
    @Published var minimumSize: Int64 = 1_000_000
    @Published var includeVersions = true
    @Published var includeBooks = true
    @Published private(set) var running = false
    @Published private(set) var status = "选择范围后点“开始查找”。只读取文件内容做比较，不会改动任何文件。"
    @Published private(set) var groups: [DuplicateGroup] = []
    /// Files moved to the Trash from this window (so they leave the list).
    @Published private(set) var trashed: Set<String> = []

    private let service: IndexService
    private var cancelled = false
    private let lock = NSLock()

    static let sizes: [(Int64, String)] = [(100_000, "100 KB"), (1_000_000, "1 MB"), (10_000_000, "10 MB"), (100_000_000, "100 MB")]

    init(service: IndexService) {
        self.service = service
    }

    var reclaimable: Int64 {
        groups.filter { $0.kind == .identical }.reduce(0) { $0 + visible($1).dropFirst().reduce(0) { $0 + $1.size } }
    }

    func visible(_ group: DuplicateGroup) -> [FileEntry] {
        group.files.filter { !trashed.contains($0.path) }
    }

    func start() {
        guard !running else { return }
        running = true
        groups = []
        trashed = []
        setCancelled(false)
        status = "正在列出文件…"
        let folder: String? = { if case .folder(let path) = scope { return path } else { return nil } }()
        let minimum = minimumSize
        let versions = includeVersions
        let books = includeBooks
        service.fileEntries(under: folder, minimumSize: minimum) { [weak self] files in
            guard let self else { return }
            self.status = "共 \(files.count.formatted()) 个文件，正在比较内容…"
            DispatchQueue.global(qos: .userInitiated).async {
                let identical = DuplicateFinder.identical(files, minimumSize: minimum, progress: { done, total in
                    if done % 20 == 0 || done == total { self.report("正在比较大小相同的文件：\(done) / \(total)") }
                }, isCancelled: self.isCancelled)
                var all = identical
                var versionGroups: [DuplicateGroup] = []
                if versions && !self.isCancelled() {
                    versionGroups = DuplicateFinder.versions(files, identical: identical, minimumSize: minimum, text: Self.text, progress: { done, total in
                        self.report("正在读取并比较不同版本的文字：\(done) / \(total) 组")
                    }, isCancelled: self.isCancelled)
                    all += versionGroups
                }
                var bookGroups: [DuplicateGroup] = []
                if books && !self.isCancelled() {
                    bookGroups = DuplicateFinder.sameBooks(files, identical: identical, versions: versionGroups, minimumSize: minimum)
                    all += bookGroups
                }
                DispatchQueue.main.async {
                    self.groups = all
                    self.running = false
                    let identicalCount = identical.count
                    let versionCount = versionGroups.count
                    if self.isCancelled() {
                        self.status = "已停止。以下是停止前找到的结果。"
                    } else if all.isEmpty {
                        self.status = "没有找到重复或相似的文件（\(files.count.formatted()) 个文件，不小于 \(Self.label(minimum))）。"
                    } else {
                        self.status = "找到 \(identicalCount) 组完全相同的文件" + (versions ? "、\(versionCount) 组同一文件的不同版本" : "")
                            + (books ? "、\(bookGroups.count) 本书有多个文件（不同格式、繁简或来源）" : "")
                            + "；删除重复副本可腾出 \(ByteCountFormatter.string(fromByteCount: self.reclaimable, countStyle: .file))。"
                    }
                }
            }
        }
    }

    func cancel() {
        setCancelled(true)
        status = "正在停止…"
    }

    private func setCancelled(_ value: Bool) {
        lock.lock(); cancelled = value; lock.unlock()
    }

    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { if self.running { self.status = text } }
    }

    /// Document text for the version comparison (local files only).
    private static func text(_ path: String) -> String? {
        guard let pages = try? DocumentText.read(URL(fileURLWithPath: path), maximumPages: 3_000) else { return nil }
        let joined = pages.pages.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    static func label(_ size: Int64) -> String {
        sizes.first { $0.0 == size }?.1 ?? ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: Actions

    func reveal(_ file: FileEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    func open(_ file: FileEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    func trash(_ files: [FileEntry]) -> String? {
        var failures: [String] = []
        for file in files {
            do {
                try Records.moveToTrash(URL(fileURLWithPath: file.path), source: "查找重复")
                trashed.insert(file.path)
            } catch {
                failures.append(file.name)
            }
        }
        return failures.isEmpty ? nil : "无法移到废纸篓：" + failures.joined(separator: "、")
    }

    /// Whether "keep the newest" is offered: always for identical files; for versions
    /// only when every older one is known to be largely contained in the newest.
    func canKeepNewest(_ group: DuplicateGroup) -> Bool {
        let files = visible(group)
        guard files.count > 1 else { return false }
        if group.kind == .identical { return true }
        return files.dropFirst().allSatisfy { (group.similarity[$0.path] ?? 0) >= 0.9 }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "在哪个文件夹中查找重复与相似文件？"
        if panel.runModal() == .OK, let url = panel.url { scope = .folder(url.path) }
    }
}

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Text(message ?? model.status)
                .font(.callout)
                .foregroundColor(message == nil ? .secondary : .orange)
                .lineLimit(2)
            List {
                ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                    let files = model.visible(group)
                    if files.count > 1 {
                        Section(header: header(group, files)) {
                            ForEach(Array(files.enumerated()), id: \.element.path) { position, file in
                                row(file, group: group, isNewest: position == 0)
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.groups.isEmpty && !model.running {
                    Text("结果会按可腾出的空间从大到小列出").foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 540)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("范围", selection: $model.scope) {
                Text("全部已索引的文件夹").tag(DuplicatesModel.Scope.everything)
                if case .folder(let path) = model.scope {
                    Text((path as NSString).abbreviatingWithTildeInPath).tag(model.scope)
                }
            }
            .frame(width: 280)
            Button("选择文件夹…") { model.chooseFolder() }
            Picker("至少", selection: $model.minimumSize) {
                ForEach(DuplicatesModel.sizes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .frame(width: 130)
            Toggle("不同版本", isOn: $model.includeVersions)
                .help("同一文件的不同版本：名称相同、只差“副本”“(1)”“[自动保存]”“_v2”或日期；会读取文字计算相似度，较慢")
            Toggle("同一本书", isOn: $model.includeBooks)
                .help("同一本电子书的多个文件：PDF 与 EPUB 等不同格式、繁体与简体、不同网站下载的版本（按书名判断，不读内容）")
            Spacer()
            if model.running {
                ProgressView().controlSize(.small)
                Button("停止") { model.cancel() }
            } else {
                Button("开始查找") { message = nil; model.start() }.keyboardShortcut(.defaultAction)
            }
        }
        .disabled(false)
    }

    private func header(_ group: DuplicateGroup, _ files: [FileEntry]) -> some View {
        let extra = files.dropFirst().reduce(Int64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: extra, countStyle: .file)
        return HStack {
            switch group.kind {
            case .identical:
                Text("完全相同 · \(files.count) 个 · 每个 \(ByteCountFormatter.string(fromByteCount: files[0].size, countStyle: .file)) · 可腾出 \(size)")
            case .versions:
                Text("同一文件的 \(files.count) 个版本 · 旧版本共 \(size)")
            case .sameBook:
                Text("同一本书的 \(files.count) 个文件 · 共 \(ByteCountFormatter.string(fromByteCount: files.reduce(Int64(0)) { $0 + $1.size }, countStyle: .file)) · 请打开核对版本后再决定保留哪个")
            }
            Spacer()
            if model.canKeepNewest(group) {
                Button("保留最新，其余移到废纸篓…") { keepNewest(group, files) }
                    .controlSize(.small)
            }
        }
        .font(.callout.weight(.semibold))
    }

    private func row(_ file: FileEntry, group: DuplicateGroup, isNewest: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if isNewest && group.kind != .sameBook { badge("最新", .green) }
                    if group.kind == .sameBook {
                        badge((file.path as NSString).pathExtension.uppercased(), .purple)
                        if SearchText.simplifiedChinese(file.name) != file.name { badge("繁体", .brown) }
                    }
                    if !file.isLocal { badge("仅在 iCloud", .gray) }
                    if group.kind == .versions && !isNewest {
                        if let share = group.similarity[file.path] {
                            badge("与最新版相同 \(Int((share * 100).rounded()))%", share >= 0.9 ? .blue : (share >= 0.5 ? .orange : .red))
                                .help(share < 0.5 ? "内容差别较大，可能不是同一文件的版本，请先打开核对" : "此版本的文字有这么多也出现在最新版中")
                        } else {
                            badge("未比较内容", .gray)
                        }
                    }
                }
                Text(SearchWindowController.displayLocation(of: file.path))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 70, alignment: .trailing)
            Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 130, alignment: .trailing)
            if group.kind == .versions && !isNewest, let newest = model.visible(group).first {
                Button("对比") {
                    CompareWindowController.shared.present(old: URL(fileURLWithPath: file.path), new: URL(fileURLWithPath: newest.path))
                }
                .controlSize(.small)
                .help("逐张（逐页）对比这个旧版本与最新版本，看改了哪些内容")
            }
            Button { model.open(file) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开")
            Button { model.reveal(file) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("在访达中显示")
            Button { message = model.trash([file]) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("移到废纸篓（可从废纸篓放回）")
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundColor(color)
    }

    private func keepNewest(_ group: DuplicateGroup, _ files: [FileEntry]) {
        let older = Array(files.dropFirst())
        let alert = NSAlert()
        alert.messageText = "把 \(older.count) 个文件移到废纸篓？"
        alert.informativeText = "保留最新的“\(files[0].name)”（\(SearchWindowController.displayLocation(of: files[0].path))）。\n\n"
            + older.prefix(8).map { "• \($0.name) — \(SearchWindowController.displayLocation(of: $0.path))" }.joined(separator: "\n")
            + (older.count > 8 ? "\n…" : "") + "\n\n可以从废纸篓放回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        message = model.trash(older)
    }
}

final class DuplicatesWindowController: NSWindowController {
    let model: DuplicatesModel

    init(service: IndexService) {
        model = DuplicatesModel(service: service)
        let host = NSHostingController(rootView: DuplicatesView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "重复与相似文件"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
