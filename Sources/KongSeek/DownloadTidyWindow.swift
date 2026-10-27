import AppKit
import SwiftUI
import KongSeekCore

/// "整理新下载的电子书" (0.20): ebooks downloaded lately under long site names are
/// renamed to short ones and moved to the ebook folder, after the user looks at
/// the plan. Nothing happens without clicking 整理; 撤销 puts them back.
final class DownloadTidyModel: ObservableObject {
    @Published private(set) var plans: [DownloadTidy.Plan] = []
    @Published var selected = Set<String>()
    @Published var style: EbookName.Style = .full {
        didSet { replan() }
    }
    @Published private(set) var folder: String?
    @Published private(set) var message = ""
    @Published private(set) var undoMoves: [(from: String, to: String)] = []
    private var sources: [String] = []

    /// The folder ebooks go to; iCloud 云盘/ebook when it exists.
    static var defaultFolder: String? {
        if let saved = UserDefaults.standard.string(forKey: "ebookFolder"), FileManager.default.fileExists(atPath: saved) { return saved }
        let cloud = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/ebook"
        return FileManager.default.fileExists(atPath: cloud) ? cloud : nil
    }

    /// Paths not to offer again (the user chose 忽略).
    static var ignored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "tidyIgnored") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: "tidyIgnored") }
    }

    /// Downloads worth offering: ebooks with a site's name pattern, not already in the
    /// ebook folder, not ignored.
    static func candidates(_ downloads: [FileEntry]) -> [String] {
        let folder = defaultFolder
        let ignored = Self.ignored
        return downloads.map(\.path).filter { path in
            let url = URL(fileURLWithPath: path)
            guard DuplicateFinder.bookExtensions.contains(url.pathExtension.lowercased()), !ignored.contains(path) else { return false }
            if let folder, url.deletingLastPathComponent().path == folder { return false }
            return EbookName.parse(EbookName.splitMark(url.deletingPathExtension().lastPathComponent).stem) != nil
        }
    }

    func load(_ paths: [String]) {
        sources = paths
        folder = Self.defaultFolder
        undoMoves = []
        replan()
        selected = Set(plans.map(\.source))
        message = folder == nil ? "请先选择存放电子书的文件夹。" : "\(plans.count) 本新下载的电子书可以整理。勾选后点“整理所选”。"
    }

    private func replan() {
        guard let folder else {
            plans = DownloadTidy.plan(sources, into: NSTemporaryDirectory(), style: style) { _ in false }
            return
        }
        plans = DownloadTidy.plan(sources, into: folder, style: style) { FileManager.default.fileExists(atPath: $0) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "电子书整理到哪个文件夹？"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "ebookFolder")
        folder = url.path
        replan()
    }

    func tidy() {
        guard folder != nil else { chooseFolder(); return }
        var moves: [(from: String, to: String)] = []
        var failures: [String] = []
        for plan in plans where selected.contains(plan.source) {
            do {
                try FileManager.default.moveItem(atPath: plan.source, toPath: plan.destination)
                for tag in plan.tags { FinderTags.set(tag, on: plan.destination, adding: true) }
                moves.append((plan.destination, plan.source))
            } catch {
                failures.append((plan.source as NSString).lastPathComponent)
            }
        }
        undoMoves = moves
        let moved = Set(moves.map(\.to))
        sources.removeAll { moved.contains($0) }
        replan()
        message = "已整理 \(moves.count) 本到 \(SearchWindowController.displayLocation(of: (folder ?? "") + "/x"))" + (failures.isEmpty ? "。" : "；未能移动：" + failures.joined(separator: "、"))
    }

    func undo() {
        var back = 0
        for move in undoMoves where (try? FileManager.default.moveItem(atPath: move.from, toPath: move.to)) != nil {
            back += 1
            sources.append(move.to)
        }
        undoMoves = []
        replan()
        message = "已撤销，\(back) 本放回原处。"
    }

    func ignoreSelected() {
        Self.ignored = Self.ignored.union(selected)
        sources.removeAll { selected.contains($0) }
        selected = []
        replan()
        message = "已忽略，以后不再提示这些文件。"
    }
}

struct DownloadTidyView: View {
    @ObservedObject var model: DownloadTidyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("整理到：").font(.callout)
                Text(model.folder.map { SearchWindowController.displayLocation(of: $0 + "/x") } ?? "未选择").font(.callout.weight(.semibold))
                Button("更改…") { model.chooseFolder() }
                Spacer()
                Picker("新名称", selection: $model.style) {
                    ForEach(EbookName.Style.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 280)
            }
            Text(model.message).font(.callout).foregroundColor(.secondary)
            List {
                ForEach(model.plans, id: \.source) { plan in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { model.selected.contains(plan.source) },
                            set: { if $0 { model.selected.insert(plan.source) } else { model.selected.remove(plan.source) } }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.newName).lineLimit(1).truncationMode(.middle)
                            Text("原名：" + (plan.source as NSString).lastPathComponent).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            if !plan.tags.isEmpty { Text("标签：" + plan.tags.joined(separator: "、")).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            HStack {
                Button("忽略所选") { model.ignoreSelected() }.disabled(model.selected.isEmpty)
                if !model.undoMoves.isEmpty { Button("撤销") { model.undo() } }
                Spacer()
                Button("整理所选") { model.tidy() }.keyboardShortcut(.defaultAction).disabled(model.selected.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 420)
    }
}

final class DownloadTidyWindowController: NSWindowController {
    let model = DownloadTidyModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "整理新下载的电子书"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: DownloadTidyView(model: model))
        window.setContentSize(NSSize(width: 780, height: 480))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(_ paths: [String]) {
        model.load(paths)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
