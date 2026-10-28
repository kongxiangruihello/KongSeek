import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// Progress of "生成可搜索的 PDF" (0.20): one file at a time, in the background.
final class SearchablePDFModel: ObservableObject {
    @Published private(set) var source: URL?
    @Published private(set) var result: URL?
    @Published private(set) var page = 0
    @Published private(set) var pages = 0
    /// Batches (0.21): which file of how many.
    @Published private(set) var fileIndex = 0
    @Published private(set) var fileCount = 0
    @Published private(set) var running = false
    @Published private(set) var message = ""
    @Published private(set) var made: [URL] = []
    private let lock = NSLock()
    private var cancelled = false

    /// Makes searchable copies one file after another. Files that already have a
    /// "（可搜索）" copy beside them, and files only in iCloud, are skipped.
    func start(_ urls: [URL]) {
        guard !running else {
            message = "正在处理其他文件，请等它完成或先停止。"
            return
        }
        var queue: [URL] = []
        var inCloud = 0, done = 0
        for url in urls {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
            if status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                inCloud += 1
            } else if urls.count > 1, FileManager.default.fileExists(atPath: Self.firstCopy(of: url).path) {
                done += 1
            } else {
                queue.append(url)
            }
        }
        made = []
        result = nil
        source = queue.first
        fileCount = queue.count
        fileIndex = 0
        guard !queue.isEmpty else {
            message = (inCloud > 0 ? "\(inCloud) 个文件只在 iCloud 中，已开始下载；下载完成后再试一次。" : "")
                + (done > 0 ? "\(done) 个文件已有可搜索版本。" : "")
            return
        }
        setCancelled(false)
        running = true
        message = "正在逐页识别文字（每页约 1–2 秒）…" + (inCloud > 0 ? "另有 \(inCloud) 个只在 iCloud 中的文件已开始下载，这次先跳过。" : "")
            + (done > 0 ? "\(done) 个已有可搜索版本，跳过。" : "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var recognized = 0, failures: [String] = []
            for (number, url) in queue.enumerated() {
                if self.isCancelled() { break }
                let destination = SearchablePDF.destination(for: url)
                DispatchQueue.main.async { self.source = url; self.fileIndex = number + 1; self.page = 0; self.pages = 0 }
                do {
                    let outcome = try SearchablePDF.make(from: url, to: destination, progress: { done, total in
                        DispatchQueue.main.async { self.page = done; self.pages = total }
                    }, isCancelled: { self.isCancelled() })
                    recognized += outcome.recognized
                    DispatchQueue.main.async { self.made.append(destination); self.result = destination }
                } catch SearchablePDF.Failure.cancelled {
                    break
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            DispatchQueue.main.async {
                self.running = false
                let count = self.made.count
                var text = self.isCancelled() ? "已停止。" : ""
                text += count == 1 ? "已生成“\(self.made[0].lastPathComponent)”" : "已生成 \(count) 个可搜索的 PDF"
                text += "，共 \(recognized) 页加上了文字层，原文件未改动。"
                if !failures.isEmpty { text += "未能处理：" + failures.joined(separator: "、") + "（可能已加密）。" }
                self.message = text
            }
        }
    }

    /// The first name a searchable copy gets: "<name>（可搜索）.pdf".
    static func firstCopy(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "（可搜索）.pdf")
    }

    func stop() { setCancelled(true) }

    private func setCancelled(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct SearchablePDFView: View {
    @ObservedObject var model: SearchablePDFModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.source?.lastPathComponent ?? "").font(.headline).lineLimit(2).truncationMode(.middle)
            if model.running {
                ProgressView(value: Double(model.page), total: Double(max(1, model.pages))) {
                    Text((model.fileCount > 1 ? "第 \(model.fileIndex) / \(model.fileCount) 本 · " : "")
                         + (model.pages > 0 ? "第 \(model.page) / \(model.pages) 页" : "正在打开…")).font(.caption)
                }
            }
            Text(model.message).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("生成的是另一个文件：每页原样保留，识别出的文字以不可见的方式放在原位置上，在“预览”等应用中可以搜索、选中和拷贝。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.running {
                    Button("停止") { model.stop() }
                } else if model.made.count > 1 {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(model.made) }
                } else if let result = model.result {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    Button("打开") { NSWorkspace.shared.open(result) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

final class SearchablePDFWindowController: NSWindowController {
    static let shared = SearchablePDFWindowController()
    let model = SearchablePDFModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "生成可搜索的 PDF"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SearchablePDFView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start(_ url: URL) { start([url]) }

    func start(_ urls: [URL]) {
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.start(urls)
    }
}
