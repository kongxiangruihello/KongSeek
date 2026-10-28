import AppKit
import SwiftUI
import KongSeekCore

/// One line of "状态与诊断" (0.18).
struct HealthItem: Identifiable {
    enum Level { case ok, warning, info }

    let id = UUID()
    var section: String
    var title: String
    var detail: String
    var level: Level
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ section: String, _ title: String, _ detail: String, _ level: Level, action: (title: String, run: () -> Void)? = nil) {
        self.section = section
        self.title = title
        self.detail = detail
        self.level = level
        actionTitle = action?.title
        self.action = action?.run
    }
}

final class StatusModel: ObservableObject {
    @Published private(set) var items: [HealthItem] = []
    @Published private(set) var cloud = "正在统计…"
    @Published var copied = false

    private let report: () -> [HealthItem]
    private let diagnosticText: () -> String
    private let service: IndexService

    init(service: IndexService, report: @escaping () -> [HealthItem], diagnosticText: @escaping () -> String) {
        self.service = service
        self.report = report
        self.diagnosticText = diagnosticText
    }

    private var spotlightToken = 0

    func refresh() {
        items = report()
        copied = false
        cloud = "正在统计…"
        spotlightToken += 1
        let token = spotlightToken
        service.fileEntries(under: nil, minimumSize: 1) { [weak self] entries in
            self?.checkSpotlight(entries, token: token)
            let cloudOnly = entries.filter { !$0.isLocal }
            let size = cloudOnly.reduce(Int64(0)) { $0 + $1.size }
            self?.cloud = cloudOnly.isEmpty
                ? "索引中的文件都在本机。"
                : "\(cloudOnly.count.formatted()) 个文件只在 iCloud 中（共 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))），未下载到本机：按名称可以搜到，但全文搜索和文字识别读不到它们。"
        }
    }

    /// 全文搜不到的原因 (0.28): whether Spotlight indexes each searched folder, from a
    /// sample of its documents, and whether indexing is on for their disks.
    private func checkSpotlight(_ entries: [FileEntry], token: Int) {
        let roots = NameIndex.effectiveRoots(Preferences.roots, rules: Preferences.rules)
            .filter { !$0.hasPrefix("/System") && !$0.hasSuffix("/Applications") }
        let samples = SpotlightCoverage.samples(roots: roots, files: entries.map { (path: $0.path, isLocal: $0.isLocal) })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [HealthItem] = []
            let group = "全文搜索"
            var volumes: [String: Bool?] = [:]
            var unindexed: [String] = []
            var checked = 0
            for root in roots {
                guard let files = samples[root], !files.isEmpty else { continue }
                let output = StatusModel.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemFSName"] + files)
                let flags = SpotlightCoverage.indexed(mdlsOutput: output, count: files.count)
                checked += 1
                let shown = (root as NSString).abbreviatingWithTildeInPath
                switch SpotlightCoverage.verdict(flags) {
                case .indexed:
                    break
                case .partly(let known, let total):
                    found.append(HealthItem(group, "“\(shown)”只有部分文件在 Spotlight 索引中", "抽查 \(total) 个文档，\(known) 个已建索引；可能刚加进来、Spotlight 还在建索引。过一阵再看；若一直如此，见下方说明。", .info))
                case .notIndexed:
                    unindexed.append(shown)
                }
                let volume = (try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
                if volumes[volume] == nil {
                    volumes[volume] = SpotlightCoverage.indexingEnabled(mdutilOutput: StatusModel.run("/usr/bin/mdutil", ["-s", volume]))
                }
            }
            let settings: (title: String, run: () -> Void) = ("打开 Spotlight 设置", {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
            })
            for (volume, enabled) in volumes where enabled == false {
                found.append(HealthItem(group, "磁盘“\(volume)”关闭了 Spotlight 索引", "这个磁盘上文件的正文搜不到。可在“终端”中执行 sudo mdutil -i on \(volume) 重新打开（需要管理员密码）。", .warning))
            }
            if !unindexed.isEmpty {
                found.append(HealthItem(group, unindexed.joined(separator: "、") + " 不在 Spotlight 索引中",
                                        "按名称能搜到，但全文搜索、引文查证、出处汇编都读不到这里的正文。通常是在 系统设置 › Spotlight › 搜索隐私 中被排除了：从列表中移除后，Spotlight 会重新建索引（可能要几小时）。",
                                        .warning, action: settings))
            }
            if found.isEmpty && checked > 0 {
                found.append(HealthItem(group, "索引的 \(checked) 个文件夹都在 Spotlight 索引中", "抽查各文件夹中的文档，Spotlight 都已建索引。扫描版 PDF 的正文还要先“文字识别”；只在 iCloud 中的文件见下方。", .ok))
            }
            DispatchQueue.main.async {
                guard let self, token == self.spotlightToken else { return }
                self.items += found
            }
        }
    }

    /// Output of a short command.
    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    var sections: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.section) { seen.append(item.section) }
        return seen
    }

    var warnings: Int { items.filter { $0.level == .warning }.count }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText(), forType: .string)
        copied = true
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.warnings == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.warnings == 0 ? .green : .orange)
                    .font(.title2)
                Text(model.warnings == 0 ? "一切正常" : "有 \(model.warnings) 项需要注意")
                    .font(.headline)
                Spacer()
                Button("刷新") { model.refresh() }
                Button(model.copied ? "已拷贝" : "拷贝诊断文本") { model.copyReport() }
                    .help("出问题时把这段文字发给开发者；完整的诊断包在 设置 › 通用 › 导出诊断包")
            }
            List {
                ForEach(model.sections, id: \.self) { section in
                    Section(header: Text(section)) {
                        ForEach(model.items.filter { $0.section == section }) { row($0) }
                    }
                }
                Section(header: Text("iCloud")) {
                    Text(model.cloud).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
    }

    private func row(_ item: HealthItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(item.level))
                .foregroundColor(color(item.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let title = item.actionTitle, let action = item.action {
                Button(title) { action() }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ level: HealthItem.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ level: HealthItem.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

final class StatusWindowController: NSWindowController {
    let model: StatusModel

    init(service: IndexService, report: @escaping () -> [HealthItem], diagnosticText: @escaping () -> String) {
        model = StatusModel(service: service, report: report, diagnosticText: diagnosticText)
        let window = NSWindow(contentViewController: NSHostingController(rootView: StatusView(model: model)))
        window.title = "状态与诊断"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 600))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        model.refresh()
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
