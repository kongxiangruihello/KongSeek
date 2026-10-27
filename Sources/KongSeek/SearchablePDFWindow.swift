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
    @Published private(set) var running = false
    @Published private(set) var message = ""
    private let lock = NSLock()
    private var cancelled = false

    func start(_ url: URL) {
        guard !running else {
            message = "正在处理另一个文件，请等它完成或先停止。"
            return
        }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        source = url
        result = nil
        page = 0
        pages = 0
        if status == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            message = "这个文件只在 iCloud 中，已开始下载；下载完成后再试一次。"
            return
        }
        setCancelled(false)
        running = true
        message = "正在逐页识别文字（每页约 1–2 秒）…"
        let destination = SearchablePDF.destination(for: url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome: Result<SearchablePDF.Outcome, Error> = Result {
                try SearchablePDF.make(from: url, to: destination, progress: { done, total in
                    DispatchQueue.main.async { self.page = done; self.pages = total }
                }, isCancelled: { self.isCancelled() })
            }
            DispatchQueue.main.async {
                self.running = false
                switch outcome {
                case .success(let made):
                    self.result = destination
                    var text = "已生成“\(destination.lastPathComponent)”：\(made.recognized) 页加上了文字层"
                    if made.alreadyText > 0 { text += "，\(made.alreadyText) 页本来就有文字" }
                    if made.skippedRotated > 0 { text += "，\(made.skippedRotated) 页是旋转的页面，暂未加文字" }
                    self.message = text + "。原文件未改动。"
                case .failure(let error):
                    switch error as? SearchablePDF.Failure {
                    case .cancelled: self.message = "已停止，未生成文件。"
                    case .unreadable: self.message = "无法打开这个 PDF（可能已加密）。"
                    default: self.message = "无法写入新文件（文件夹可能只读）。"
                    }
                }
            }
        }
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
                    Text(model.pages > 0 ? "第 \(model.page) / \(model.pages) 页" : "正在打开…").font(.caption)
                }
            }
            Text(model.message).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("生成的是另一个文件：每页原样保留，识别出的文字以不可见的方式放在原位置上，在“预览”等应用中可以搜索、选中和拷贝。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.running {
                    Button("停止") { model.stop() }
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

    func start(_ url: URL) {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.start(url)
    }
}
