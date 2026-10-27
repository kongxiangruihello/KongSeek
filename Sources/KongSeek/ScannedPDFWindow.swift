import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// "查找扫描版 PDF": lists the indexed PDFs without a text layer, by folder, and adds
/// the chosen folders to 设置 › 文字识别 in one click (0.16).
final class ScannedPDFModel: ObservableObject {
    @Published var scope: DuplicatesModel.Scope = .everything
    @Published private(set) var running = false
    @Published private(set) var checked = 0
    @Published private(set) var total = 0
    @Published private(set) var status = "点“开始检查”找出没有文字层的 PDF（扫描版）。只读取 PDF 的文字层，不改动文件，不从 iCloud 下载。"
    @Published private(set) var folders: [ScannedPDFs.Folder] = []
    @Published private(set) var finished = false
    @Published var selected: Set<String> = []

    private let service: IndexService
    private let ocr: OCRService
    private var token: CancelToken?

    init(service: IndexService, ocr: OCRService) {
        self.service = service
        self.ocr = ocr
    }

    final class CancelToken {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    func start() {
        guard !running else { return }
        running = true
        finished = false
        folders = []
        selected = []
        checked = 0
        total = 0
        status = "正在列出索引中的 PDF…"
        let folder: String? = { if case .folder(let path) = scope { return path } else { return nil } }()
        let token = CancelToken()
        self.token = token
        service.fileEntries(under: folder, minimumSize: 2_001, extensions: ["pdf"]) { [weak self] entries in
            guard let self, !token.isCancelled else { return }
            let ocrFolders = Preferences.ocrFolders.map(Paths.canonical)
            var covered = 0
            var inCloud = 0
            var local: [FileEntry] = []
            for entry in entries {
                if ScannedPDFs.isCovered(entry.path, by: ocrFolders) { covered += 1; continue }
                if entry.isLocal { local.append(entry) } else { inCloud += 1 }
            }
            self.total = local.count
            self.status = "正在检查 \(local.count.formatted()) 个 PDF 的文字层…"
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ScannedPDFModel.check(local, token: token) { done in
                    DispatchQueue.main.async { if !token.isCancelled { self.checked = done } }
                }
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    self.finish(found, checked: local.count, covered: covered, inCloud: inCloud)
                }
            }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        running = false
        status = "已停止。"
    }

    /// Opens each PDF in parallel and keeps those whose sampled pages have no text.
    private static func check(_ entries: [FileEntry], token: CancelToken, progress: @escaping (Int) -> Void) -> [ScannedPDFs.File] {
        let chunk = 16
        let count = (entries.count + chunk - 1) / chunk
        var parts = [[ScannedPDFs.File]](repeating: [], count: count)
        let lock = NSLock()
        var done = 0
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: count) { c in
                guard !token.isCancelled else { return }
                var found: [ScannedPDFs.File] = []
                for entry in entries[(c * chunk)..<min(entries.count, (c + 1) * chunk)] {
                    if token.isCancelled { break }
                    autoreleasepool {
                        if let layer = DocumentText.textLayer(of: URL(fileURLWithPath: entry.path)), !layer.hasText, layer.pages > 0 {
                            found.append(ScannedPDFs.File(path: entry.path, pages: layer.pages, size: entry.size))
                        }
                    }
                }
                output[c] = found
                lock.lock()
                done += min(chunk, entries.count - c * chunk)
                let now = done
                lock.unlock()
                progress(now)
            }
        }
        return parts.flatMap { $0 }
    }

    private func finish(_ found: [ScannedPDFs.File], checked: Int, covered: Int, inCloud: Int) {
        running = false
        finished = true
        token = nil
        folders = ScannedPDFs.folders(found)
        selected = Set(folders.map(\.path))
        let pages = found.reduce(0) { $0 + $1.pages }
        var text = found.isEmpty
            ? "检查了 \(checked.formatted()) 个 PDF，没有发现扫描版。"
            : "检查了 \(checked.formatted()) 个 PDF：\(found.count.formatted()) 个是扫描版（共 \(pages.formatted()) 页），在 \(folders.count) 个文件夹中。"
        if covered > 0 { text += "\n\(covered.formatted()) 个 PDF 已在“文字识别”的文件夹中，未列出。" }
        if inCloud > 0 { text += "\n另有 \(inCloud.formatted()) 个 PDF 只在 iCloud 中，未检查（加入文件夹后可在 设置 › 文字识别 中勾选“从 iCloud 下载”）。" }
        status = text
    }

    var selectedFiles: [ScannedPDFs.File] { folders.filter { selected.contains($0.path) }.flatMap(\.files) }

    var estimate: String {
        let files = selectedFiles
        guard !files.isEmpty else { return "未选择文件夹" }
        let pages = files.reduce(0) { $0 + min($1.pages, Preferences.ocrPageLimit) }
        let time = ScannedPDFs.describe(seconds: ScannedPDFs.estimatedSeconds(files, pageLimit: Preferences.ocrPageLimit))
        return "已选 \(selected.count) 个文件夹 · \(files.count.formatted()) 个文件 · 识别 \(pages.formatted()) 页 · 预计\(time)"
            + (Preferences.ocrOnlyOnPower ? "（只在接通电源时进行）" : "")
    }

    /// Adds the chosen folders to the OCR folders and starts recognition.
    func recognizeSelected() {
        let chosen = folders.map(\.path).filter { selected.contains($0) }
        guard !chosen.isEmpty else { return }
        let existing = Preferences.ocrFolders
        let canonical = existing.map(Paths.canonical)
        // Keep the user's own spelling of folders already in the list.
        Preferences.ocrFolders = ScannedPDFs.adding(chosen, to: canonical).map { path in
            canonical.firstIndex(of: path).map { existing[$0] } ?? path
        }
        Preferences.ocrEnabled = true
        if ocr.paused { ocr.setPaused(false) }
        ocr.configure(Preferences.ocrSettings)
        let count = selectedFiles.count
        folders.removeAll { chosen.contains($0.path) }
        selected = []
        status = "已把 \(chosen.count) 个文件夹加入“文字识别”，\(count.formatted()) 个扫描版 PDF 在后台排队识别。进度见 设置 › 文字识别；识别出的文字在全文模式（⇥）中可搜。"
    }

    func toggleAll() {
        selected = selected.count == folders.count ? [] : Set(folders.map(\.path))
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "在哪个文件夹里查找扫描版 PDF？"
        if panel.runModal() == .OK, let url = panel.url { scope = .folder(url.path) }
    }
}

struct ScannedPDFView: View {
    @ObservedObject var model: ScannedPDFModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Button("开始检查") { model.start() }.keyboardShortcut(.defaultAction)
                }
            }
            if model.running {
                if model.total > 0 {
                    ProgressView(value: Double(model.checked), total: Double(model.total)) {
                        Text("已检查 \(model.checked.formatted()) / \(model.total.formatted())").font(.caption)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.folders) { folder in
                    folderRow(folder)
                    if expanded.contains(folder.path) {
                        ForEach(folder.files, id: \.path) { fileRow($0) }
                    }
                }
            }
            .overlay {
                if model.folders.isEmpty && !model.running {
                    Text(model.finished ? "没有需要识别的扫描版 PDF" : "点“开始检查”").foregroundColor(.secondary)
                }
            }
            if !model.folders.isEmpty {
                HStack {
                    Button(model.selected.count == model.folders.count ? "全不选" : "全选") { model.toggleAll() }
                    Text(model.estimate).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("另存为可搜索 PDF…") {
                        SearchablePDFWindowController.shared.start(model.selectedFiles.map { URL(fileURLWithPath: $0.path) })
                    }
                    .disabled(model.selected.isEmpty)
                    .help("为所选文件夹中的扫描版 PDF 各另存一份带文字层的副本，在“预览”等应用中也能搜索；已有副本的跳过")
                    Button("识别所选文件夹中的扫描版 PDF") { model.recognizeSelected() }
                        .disabled(model.selected.isEmpty)
                }
                Text("所选文件夹会加入 设置 › 文字识别，用本机 Apple Vision 在后台识别（不上传），文件夹中的图片也会一并识别。识别结果不改动原文件。")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func folderRow(_ folder: ScannedPDFs.Folder) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(folder.path) },
                set: { if $0 { model.selected.insert(folder.path) } else { model.selected.remove(folder.path) } }
            ))
            .labelsHidden()
            Button {
                if expanded.contains(folder.path) { expanded.remove(folder.path) } else { expanded.insert(folder.path) }
            } label: {
                Image(systemName: expanded.contains(folder.path) ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .buttonStyle(.borderless)
            .help("显示或隐藏文件")
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text((folder.path as NSString).lastPathComponent).lineLimit(1)
                Text(SearchWindowController.displayLocation(of: folder.path)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("\(folder.files.count) 个文件 · \(folder.pages.formatted()) 页").font(.callout.monospacedDigit()).foregroundColor(.secondary)
            Button { model.reveal(folder.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("在访达中显示")
        }
        .padding(.vertical, 2)
    }

    private func fileRow(_ file: ScannedPDFs.File) -> some View {
        HStack(spacing: 8) {
            Text((file.path as NSString).lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(file.pages) 页 · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Button("生成可搜索 PDF") { SearchablePDFWindowController.shared.start(URL(fileURLWithPath: file.path)) }
                .controlSize(.small)
                .help("另存一份带文字层的 PDF，在“预览”等应用中也能搜索、拷贝文字")
            Button { model.open(file.path) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("打开")
            Button { model.reveal(file.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("在访达中显示")
        }
        .padding(.leading, 70)
    }
}

final class ScannedPDFWindowController: NSWindowController {
    let model: ScannedPDFModel

    init(service: IndexService, ocr: OCRService) {
        model = ScannedPDFModel(service: service, ocr: ocr)
        let window = NSWindow(contentViewController: NSHostingController(rootView: ScannedPDFView(model: model)))
        window.title = "查找扫描版 PDF"
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
    }
}
