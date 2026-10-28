import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KongSeekCore

/// "课程材料打包" (0.22): the files of a saved search (a course) or a file list,
/// copied into one folder or one .zip to give to students or put on a USB stick.
final class CoursePackageModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published private(set) var message = ""
    @Published private(set) var result: URL?
    private let lock = NSLock()
    private var cancelled = false

    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Asks zip or folder, and where; then copies in the background.
    func start(paths: [String], name: String, window: NSWindow?) {
        let files = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else {
            message = "没有可打包的文件。"
            return
        }
        var size: Int64 = 0
        var inCloud = 0
        for path in files {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
            size += Int64(values?.fileSize ?? 0)
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded { inCloud += 1 }
        }
        let alert = NSAlert()
        alert.messageText = "打包“\(name)”的 \(files.count) 个文件"
        alert.informativeText = "共 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))。"
            + (inCloud > 0 ? "其中 \(inCloud) 个只在 iCloud 中，打包时会先下载。" : "")
            + "\n文件名相同的会自动加编号；原文件不改动。"
        alert.addButton(withTitle: "打包为 zip…")
        alert.addButton(withTitle: "复制到文件夹…")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        let date = Date().formatted(.iso8601.year().month().day())
        let base = "\(name) 材料 \(date)".replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        if choice == .alertFirstButtonReturn {
            guard size < 3_900_000_000 else {
                message = "超过 4 GB，zip 放不下，请改用“复制到文件夹”。"
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = base + ".zip"
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            run(files, title: name) { [weak self] entries in
                try? FileManager.default.removeItem(at: url)
                let zip = try ZipWriter(url: url)
                for (index, entry) in entries.enumerated() {
                    if self?.isCancelled() ?? true { break }
                    try zip.addFile(URL(fileURLWithPath: entry.path), as: base + "/" + entry.name)
                    self?.progress(index + 1)
                }
                try zip.finish()
                return url
            }
        } else if choice == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "放在这里"
            panel.message = "在所选文件夹中新建“\(base)”并复制进去"
            guard panel.runModal() == .OK, let parent = panel.url else { return }
            run(files, title: name) { [weak self] entries in
                var folder = parent.appendingPathComponent(base)
                var number = 2
                while FileManager.default.fileExists(atPath: folder.path) {
                    folder = parent.appendingPathComponent("\(base) (\(number))")
                    number += 1
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, entry) in entries.enumerated() {
                    if self?.isCancelled() ?? true { break }
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: entry.path), to: folder.appendingPathComponent(entry.name))
                    self?.progress(index + 1)
                }
                return folder
            }
        }
    }

    private func progress(_ count: Int) {
        DispatchQueue.main.async { self.done = count }
    }

    private func run(_ files: [String], title: String, work: @escaping ([(path: String, name: String)]) throws -> URL) {
        lock.lock(); cancelled = false; lock.unlock()
        self.title = title
        done = 0
        total = files.count
        running = true
        result = nil
        message = "正在打包…"
        let entries = PackageNames.unique(files)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try work(entries)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running = false
                    self.result = url
                    self.message = self.isCancelled() ? "已停止，已完成的部分在“\(url.lastPathComponent)”。" : "已完成：\(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.running = false
                    self?.message = "打包失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

struct CoursePackageView: View {
    @ObservedObject var model: CoursePackageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            if model.running {
                ProgressView(value: Double(model.done), total: Double(max(1, model.total))) {
                    Text("\(model.done) / \(model.total) 个文件").font(.caption)
                }
            }
            Text(model.message).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.running {
                    Button("停止") { model.stop() }
                } else if let result = model.result {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                }
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

final class CoursePackageWindowController: NSWindowController {
    static let shared = CoursePackageWindowController()
    let model = CoursePackageModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "课程材料打包"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: CoursePackageView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start(paths: [String], name: String) {
        NSApp.activate(ignoringOtherApps: true)
        model.start(paths: paths, name: name, window: window)
        guard model.running else { return }
        if window?.isVisible != true { window?.placeRemembered() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
