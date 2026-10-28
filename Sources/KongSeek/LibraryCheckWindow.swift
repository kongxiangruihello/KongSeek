import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// "书库体检" (0.21): damaged, locked, empty and half-downloaded files, and ebooks
/// kept in several files, in the indexed folders or one folder.
final class LibraryCheckModel: ObservableObject {
    struct Item: Identifiable {
        var id: String { path }
        var path: String
        var size: Int64
        var problem: LibraryCheck.Problem
    }

    @Published var scope: DuplicatesModel.Scope = .everything
    @Published private(set) var items: [Item] = []
    @Published private(set) var sameBookGroups = 0
    /// Books kept in several files (0.32), to choose a 常用本 for.
    @Published private(set) var editionGroups: [[FileEntry]] = []
    @Published private(set) var running = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var status = "点“开始体检”检查索引中的文件。只打开 PDF 和 EPUB 读取结构，不改动任何文件，不从 iCloud 下载。"
    @Published private(set) var trashed: Set<String> = []
    var openDuplicates: (() -> Void)?

    private let service: IndexService
    private let lock = NSLock()
    private var cancelled = false

    init(service: IndexService) {
        self.service = service
    }

    var visible: [Item] { items.filter { !trashed.contains($0.path) } }

    func start() {
        guard !running else { return }
        running = true
        items = []
        trashed = []
        setCancelled(false)
        status = "正在列出文件…"
        let folder: String? = { if case .folder(let path) = scope { return path } else { return nil } }()
        service.fileEntries(under: folder, minimumSize: 0) { [weak self] entries in
            guard let self else { return }
            var found: [Item] = []
            var toOpen: [FileEntry] = []
            var inCloud = 0
            for entry in entries {
                if let problem = LibraryCheck.quickProblem(path: entry.path, size: entry.size) {
                    found.append(Item(path: entry.path, size: entry.size, problem: problem))
                    continue
                }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                guard ext == "pdf" || ext == "epub" else { continue }
                if entry.isLocal { toOpen.append(entry) } else { inCloud += 1 }
            }
            let groups = DuplicateFinder.sameBooks(entries)
            let sameBooks = groups.count
            self.progress = (0, toOpen.count)
            self.status = "正在检查 \(toOpen.count.formatted()) 个 PDF / EPUB…"
            DispatchQueue.global(qos: .userInitiated).async {
                let opened = self.inspect(toOpen)
                DispatchQueue.main.async {
                    self.running = false
                    self.items = (found + opened).sorted { $0.problem.rawValue != $1.problem.rawValue ? $0.problem.rawValue < $1.problem.rawValue : $0.path < $1.path }
                    self.sameBookGroups = sameBooks
                    self.editionGroups = groups.map(\.files)
                    var text = self.isCancelled() ? "已停止。" : ""
                    text += self.items.isEmpty ? "没有发现问题文件。" : "发现 \(self.items.count) 个问题文件。"
                    if sameBooks > 0 { text += "另有 \(sameBooks) 本书存有多个文件（不同格式或版本）。" }
                    if inCloud > 0 { text += "\(inCloud.formatted()) 个只在 iCloud 中的 PDF / EPUB 未检查。" }
                    self.status = text
                }
            }
        }
    }

    /// Opens files in parallel; stops early when cancelled.
    private func inspect(_ entries: [FileEntry]) -> [Item] {
        let chunk = 16
        let count = (entries.count + chunk - 1) / chunk
        var parts = [[Item]](repeating: [], count: count)
        let progressLock = NSLock()
        var done = 0
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: count) { c in
                guard !self.isCancelled() else { return }
                var found: [Item] = []
                for entry in entries[(c * chunk)..<min(entries.count, (c + 1) * chunk)] {
                    autoreleasepool {
                        if let problem = LibraryCheck.inspect(URL(fileURLWithPath: entry.path)) {
                            found.append(Item(path: entry.path, size: entry.size, problem: problem))
                        }
                    }
                }
                output[c] = found
                progressLock.lock()
                done += min(chunk, entries.count - c * chunk)
                let now = done
                progressLock.unlock()
                DispatchQueue.main.async { self.progress = (now, entries.count) }
            }
        }
        return parts.flatMap { $0 }
    }

    func stop() { setCancelled(true) }
    private func setCancelled(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// The books with several files and no 常用本 yet (0.32).
    var unsetEditions: [[FileEntry]] {
        let unset = Set(Records.editions.unset(editionGroups.map { $0.map(\.path) }).compactMap(\.first))
        return editionGroups.filter { group in group.first.map { unset.contains($0.path) } ?? false }
    }

    func prefer(_ path: String) {
        var editions = Records.editions
        editions.prefer(path)
        Records.editions = editions
        objectWillChange.send()
        status = "已设常用本：\((path as NSString).lastPathComponent)。"
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func trash(_ paths: [String]) -> String? {
        var failures = 0
        for path in paths {
            if Records.trashed(URL(fileURLWithPath: path), source: "书库体检") { trashed.insert(path) } else { failures += 1 }
        }
        return failures > 0 ? "\(failures) 个文件无法移到废纸篓" : nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "检查哪个文件夹？"
        if panel.runModal() == .OK, let url = panel.url { scope = .folder(url.path) }
    }
}

struct LibraryCheckView: View {
    @ObservedObject var model: LibraryCheckModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("范围", selection: $model.scope) {
                    Text("全部已索引的文件夹").tag(DuplicatesModel.Scope.everything)
                    if case .folder(let path) = model.scope {
                        Text((path as NSString).abbreviatingWithTildeInPath).tag(model.scope)
                    }
                }
                .frame(width: 300)
                .disabled(model.running)
                Button("选择文件夹…") { model.chooseFolder() }.disabled(model.running)
                Spacer()
                if model.running {
                    Button("停止") { model.stop() }
                } else {
                    Button("开始体检") { message = nil; model.start() }.keyboardShortcut(.defaultAction)
                }
            }
            if model.running && model.progress.total > 0 {
                ProgressView(value: Double(model.progress.done), total: Double(model.progress.total)) {
                    Text("已检查 \(model.progress.done) / \(model.progress.total)").font(.caption)
                }
            }
            Text(message ?? model.status).font(.callout).foregroundColor(message == nil ? .secondary : .orange).fixedSize(horizontal: false, vertical: true)
            if model.sameBookGroups > 0, let openDuplicates = model.openDuplicates {
                Button("查看 \(model.sameBookGroups) 本有多个文件的书…") { openDuplicates() }.controlSize(.small)
            }
            List {
                ForEach(LibraryCheck.Problem.allCases, id: \.self) { problem in
                    let rows = model.visible.filter { $0.problem == problem }
                    if !rows.isEmpty {
                        Section(header: sectionHeader(problem, rows)) {
                            ForEach(rows) { row($0) }
                        }
                    }
                }
                let editions = model.unsetEditions
                if !editions.isEmpty {
                    Section(header: VStack(alignment: .leading, spacing: 1) {
                        Text("有多个版本、尚未设常用本的书（\(editions.count)）").font(.callout.weight(.semibold))
                        Text("同一部书的几个文件（不同格式、繁简或版本）。设一个常用本，引文查证、稿件核对、出处汇编中它排在最前，拷贝出处也用它。")
                            .font(.caption).foregroundColor(.secondary)
                    }) {
                        ForEach(editions, id: \.first?.path) { group in
                            Text(bookTitle(group)).font(.callout.weight(.medium)).padding(.top, 4)
                            ForEach(group, id: \.path) { file in editionRow(file) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func bookTitle(_ group: [FileEntry]) -> String {
        guard let first = group.first else { return "" }
        let stem = EbookName.splitMark(((first.path as NSString).lastPathComponent as NSString).deletingPathExtension).stem
        return "《" + (EbookName.parse(stem)?.title ?? stem) + "》"
    }

    private func editionRow(_ file: FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(SearchWindowController.displayLocation(of: file.path)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Button { model.open(file.path) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开")
            Button("设为常用本") { model.prefer(file.path) }.controlSize(.small)
        }
        .padding(.leading, 12)
    }

    private func sectionHeader(_ problem: LibraryCheck.Problem, _ rows: [LibraryCheckModel.Item]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(problem.title)（\(rows.count)）").font(.callout.weight(.semibold))
                Text(problem.advice).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if problem == .partialDownload || problem == .empty {
                Button("全部移到废纸篓…") { confirmTrash(rows.map(\.path), title: problem.title) }.controlSize(.small)
            }
        }
    }

    private func row(_ item: LibraryCheckModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(SearchWindowController.displayLocation(of: item.path)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Button { model.open(item.path) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开")
            Button { model.reveal(item.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("在访达中显示")
            Button { confirmTrash([item.path], title: (item.path as NSString).lastPathComponent) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("移到废纸篓（可放回）")
        }
    }

    private func confirmTrash(_ paths: [String], title: String) {
        let alert = NSAlert()
        alert.messageText = paths.count == 1 ? "把“\(title)”移到废纸篓？" : "把 \(paths.count) 个“\(title)”移到废纸篓？"
        alert.informativeText = paths.prefix(8).map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n") + (paths.count > 8 ? "\n…" : "") + "\n\n可以从废纸篓放回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        message = model.trash(paths)
    }
}

final class LibraryCheckWindowController: NSWindowController {
    let model: LibraryCheckModel

    init(service: IndexService) {
        model = LibraryCheckModel(service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "书库体检"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: LibraryCheckView(model: model))
        window.setContentSize(NSSize(width: 860, height: 620))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
