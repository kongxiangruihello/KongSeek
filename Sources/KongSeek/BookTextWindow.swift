import AppKit
import SwiftUI
import KongSeekCore

/// 正文索引管理 (0.43): what KongSeek's own text index holds, the books it could not
/// read and why (a scan can go to 文字识别), the folders left out, and 重建.
final class BookTextModel: ObservableObject {
    struct Problem: Identifiable {
        var id: String { path }
        var path: String
        var problem: String
        var isScan: Bool { problem == "扫描件" }
    }

    @Published private(set) var summary = ""
    @Published private(set) var problems: [Problem] = []
    @Published private(set) var excluded: [String] = Preferences.bookTextExcluded
    @Published private(set) var status = ""
    weak var service: IndexService?
    var ocr: OCRService?

    func reload() {
        let books = BookTextService.shared
        // The service's state is read here, on main; only the index (locked) is read in the background.
        let uncovered = books.uncoveredFolderCount
        let running = books.running
        let progress = books.progress
        let index = books.index
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let numbers = index.summary
            let size = index.diskSize
            let found = index.problems.map { Problem(path: $0.path, problem: $0.problem) }
            DispatchQueue.main.async {
                guard let self else { return }
                var text = Preferences.bookTextIndex ? "已收录 \(numbers.books) 本，约 \(max(1, numbers.characters / 10_000)) 万字，占用 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))。" : "正文索引已关闭（设置 › 搜索）。"
                if uncovered > 0 { text += "其中包括 Spotlight 未收录的 \(uncovered) 个文件夹中的文稿。" }
                if running { text += "正在读取 \(progress.done) / \(progress.total)。" }
                self.summary = text
                self.problems = found
            }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Adds the scan's folder to 文字识别; its recognized text then reaches full-text search.
    func recognize(_ problem: Problem) {
        let folder = (problem.path as NSString).deletingLastPathComponent
        let existing = Preferences.ocrFolders
        let canonical = existing.map(Paths.canonical)
        Preferences.ocrFolders = ScannedPDFs.adding([Paths.canonical(folder)], to: canonical).map { path in
            canonical.firstIndex(of: path).map { existing[$0] } ?? path
        }
        Preferences.ocrEnabled = true
        NotificationCenter.default.post(name: .ocrSettingsChanged, object: nil)
        status = "已把“\((folder as NSString).lastPathComponent)”加入文字识别，其中的扫描件会在后台识别（进度见 设置 › 文字识别）。"
    }

    func addExcluded() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "排除"
        panel.message = "选择不建立正文索引的文件夹"
        guard panel.runModal() == .OK else { return }
        var folders = Preferences.bookTextExcluded
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
        Preferences.bookTextExcluded = folders
        excluded = folders
        refreshIndex()
        status = "已排除。下次读取时，这些文件夹中的书会从正文索引中去掉。"
    }

    func removeExcluded(_ folder: String) {
        var folders = Preferences.bookTextExcluded
        folders.removeAll { $0 == folder }
        Preferences.bookTextExcluded = folders
        excluded = folders
        refreshIndex()
    }

    func rebuild() {
        guard let service else { return }
        BookTextService.shared.rebuild(service: service)
        status = "正在重建：每本书都会重新读一遍，进度见菜单栏图标。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reload() }
    }

    private func refreshIndex() {
        if let service { BookTextService.shared.refresh(service: service) }
    }
}

struct BookTextView: View {
    @ObservedObject var model: BookTextModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(model.summary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("刷新") { model.reload() }
                Button("重建正文索引…") {
                    let alert = NSAlert()
                    alert.messageText = "重建正文索引？"
                    alert.informativeText = "清除已读出的文字，每本书重新读一遍；书多时需要一些时间，期间全文搜索暂时找不到这些书。"
                    alert.addButton(withTitle: "重建")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn { model.rebuild() }
                }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox("读不出文字的书（\(model.problems.count)）") {
                if model.problems.isEmpty {
                    Text("没有。").foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List(model.problems) { problem in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((problem.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(SearchWindowController.displayLocation(of: problem.path)).font(.caption).foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Self.explain(problem.problem)).font(.caption).foregroundColor(.orange)
                            if problem.isScan {
                                Button("加入文字识别") { model.recognize(problem) }.controlSize(.small)
                            }
                            Button("显示") { model.reveal(problem.path) }.controlSize(.small)
                        }
                    }
                    .frame(minHeight: 200)
                }
            }
            GroupBox("不建立正文索引的文件夹") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.excluded, id: \.self) { folder in
                        HStack {
                            Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("移除") { model.removeExcluded(folder) }.controlSize(.small)
                        }
                    }
                    if model.excluded.isEmpty { Text("没有。").foregroundColor(.secondary) }
                    Button("添加文件夹…") { model.addExcluded() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("正文索引收录 Spotlight 读不到正文的 EPUB、Kindle 电子书和 GB18030 文本，以及 Spotlight 未收录的文件夹中的 PDF、Word、幻灯片。只读本机已下载的文件，不改动文件。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    static func explain(_ problem: String) -> String {
        switch problem {
        case "DRM": return "有 DRM 保护"
        case "扫描件": return "扫描件，需文字识别"
        case "没有文字": return "没有文字"
        case "无法读取": return "无法读取（可能已损坏）"
        default: return problem.hasPrefix("compression") ? "不支持的压缩方式" : problem
        }
    }
}

final class BookTextWindowController: NSWindowController {
    let model = BookTextModel()

    init(service: IndexService, ocr: OCRService) {
        model.service = service
        model.ocr = ocr
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "正文索引"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: BookTextView(model: model))
        window.setContentSize(NSSize(width: 700, height: 600))
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
