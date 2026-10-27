import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore
import KongSeekText

/// "两版讲义对比" (0.20): which slides (pages, paragraphs) of a newer version were
/// added, removed or edited, with the lines that changed.
final class CompareModel: ObservableObject {
    @Published var oldURL: URL?
    @Published var newURL: URL?
    @Published private(set) var changes: [VersionDiff.Change] = []
    @Published private(set) var unit = "页"
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    @Published var onlyChanges = true
    private var token = 0

    var shown: [VersionDiff.Change] { onlyChanges ? changes.filter { $0.kind != .same } : changes }
    var summary: VersionDiff.Summary { VersionDiff.summary(changes) }

    func compare() {
        guard let oldURL, let newURL else {
            message = "请选择旧版和新版两个文件。"
            return
        }
        token += 1
        let current = token
        loading = true
        changes = []
        message = "正在读取两个文件的文字…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let old = CompareModel.units(oldURL), new = CompareModel.units(newURL)
            var result: [VersionDiff.Change] = []
            var problem: String?
            if let failure = old.failure ?? new.failure {
                problem = failure
            } else {
                result = VersionDiff.compare(old: old.units, new: new.units)
            }
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                self.loading = false
                self.unit = new.unit
                self.changes = result
                if let problem {
                    self.message = problem
                } else {
                    let s = VersionDiff.summary(result)
                    self.message = "旧版 \(old.units.count) \(new.unit)，新版 \(new.units.count) \(new.unit)：新增 \(s.added)，删除 \(s.removed)，修改 \(s.changed)，未变 \(s.same)。"
                }
            }
        }
    }

    /// Slides of a deck, pages of a PDF, or paragraphs of other documents.
    static func units(_ url: URL) -> (units: [String], unit: String, failure: String?) {
        do {
            let pages = try DocumentText.read(url, maximumPages: 5_000, downloadWait: 60)
            if pages.isPaged { return (pages.pages, pages.unit == "页" ? "页" : "张", nil) }
            let paragraphs = (pages.pages.first ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (paragraphs, "段", nil)
        } catch let failure as DocumentText.Failure {
            return ([], "页", "\(url.lastPathComponent)：\(failure.message)")
        } catch {
            return ([], "页", "\(url.lastPathComponent)：无法读取")
        }
    }

    func choose(old: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .init(filenameExtension: "pptx")!, .init(filenameExtension: "docx")!, .plainText, .rtf]
        panel.directoryURL = (old ? newURL : oldURL)?.deletingLastPathComponent()
        panel.message = old ? "选择旧版" : "选择新版"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if old { oldURL = url } else { newURL = url }
        if oldURL != nil && newURL != nil { compare() }
    }

    func swap() {
        (oldURL, newURL) = (newURL, oldURL)
        compare()
    }

    /// Opens the new version at a slide or page.
    func openNew(at position: Int) {
        guard let newURL else { return }
        switch newURL.pathExtension.lowercased() {
        case "pptx":
            PowerPoint.open(newURL.path, slide: position) { [weak self] message in
                if let message { self?.message = message }
            }
        case "pdf":
            ReaderWindowController.shared.open(newURL, page: position, words: [])
        default:
            NSWorkspace.shared.open(newURL)
        }
    }
}

struct CompareView: View {
    @ObservedObject var model: CompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fileRow("旧版", model.oldURL) { model.choose(old: true) }
            fileRow("新版", model.newURL) { model.choose(old: false) }
            HStack {
                Button("交换新旧") { model.swap() }.disabled(model.oldURL == nil || model.newURL == nil)
                Button("重新比较") { model.compare() }.disabled(model.loading)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("只看改动", isOn: $model.onlyChanges)
            }
            Text(model.message).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(Array(model.shown.enumerated()), id: \.offset) { _, change in
                    changeRow(change)
                }
            }
            .overlay {
                if model.shown.isEmpty && !model.loading && !model.changes.isEmpty {
                    Text("两版内容相同").foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }

    private func fileRow(_ label: String, _ url: URL?, choose: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.callout.weight(.semibold)).frame(width: 36, alignment: .leading)
            Text(url?.lastPathComponent ?? "未选择").lineLimit(1).truncationMode(.middle)
                .foregroundColor(url == nil ? .secondary : .primary)
                .help(url.map { SearchWindowController.displayLocation(of: $0.path) } ?? "")
            Spacer()
            Button("选择…", action: choose)
        }
    }

    private func title(_ change: VersionDiff.Change) -> String {
        let unit = model.unit
        switch change.kind {
        case .same: return "未变 · 旧版第 \(change.old ?? 0) \(unit) → 新版第 \(change.new ?? 0) \(unit)"
        case .changed: return "修改 · 旧版第 \(change.old ?? 0) \(unit) → 新版第 \(change.new ?? 0) \(unit)（文字相同约 \(Int((change.similarity * 100).rounded()))%）"
        case .added: return "新增 · 新版第 \(change.new ?? 0) \(unit)"
        case .removed: return "删除 · 旧版第 \(change.old ?? 0) \(unit)"
        }
    }

    private func color(_ kind: VersionDiff.Kind) -> Color {
        switch kind {
        case .same: return .secondary
        case .changed: return .orange
        case .added: return .green
        case .removed: return .red
        }
    }

    private func changeRow(_ change: VersionDiff.Change) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title(change)).font(.callout.weight(.semibold)).foregroundColor(color(change.kind))
                Spacer()
                if let position = change.new, model.unit != "段" {
                    Button("打开新版到此处") { model.openNew(at: position) }.controlSize(.small)
                }
            }
            ForEach(Array(change.addedLines.prefix(12).enumerated()), id: \.offset) { _, line in
                Text("＋ " + line).font(.callout).foregroundColor(.green).lineLimit(2)
            }
            if change.addedLines.count > 12 { Text("……另有 \(change.addedLines.count - 12) 行").font(.caption).foregroundColor(.secondary) }
            ForEach(Array(change.removedLines.prefix(12).enumerated()), id: \.offset) { _, line in
                Text("－ " + line).font(.callout).foregroundColor(.red).strikethrough().lineLimit(2)
            }
            if change.removedLines.count > 12 { Text("……另有 \(change.removedLines.count - 12) 行").font(.caption).foregroundColor(.secondary) }
        }
        .padding(.vertical, 3)
    }
}

final class CompareWindowController: NSWindowController {
    static let shared = CompareWindowController()
    let model = CompareModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "两版对比"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: CompareView(model: model))
        window.setContentSize(NSSize(width: 820, height: 640))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window comparing `old` with `new`; a missing one is asked for.
    func present(old: URL?, new: URL?) {
        model.oldURL = old
        model.newURL = new
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if old != nil && new != nil {
            model.compare()
            return
        }
        // Ask for what is missing; choosing the second one starts the comparison.
        if model.oldURL == nil { model.choose(old: true) }
        if model.oldURL != nil && model.newURL == nil { model.choose(old: false) }
    }
}
