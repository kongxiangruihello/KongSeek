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

    func refresh() {
        items = report()
        copied = false
        cloud = "正在统计…"
        service.fileEntries(under: nil, minimumSize: 1) { [weak self] entries in
            let cloudOnly = entries.filter { !$0.isLocal }
            let size = cloudOnly.reduce(Int64(0)) { $0 + $1.size }
            self?.cloud = cloudOnly.isEmpty
                ? "索引中的文件都在本机。"
                : "\(cloudOnly.count.formatted()) 个文件只在 iCloud 中（共 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))），未下载到本机：按名称可以搜到，但全文搜索和文字识别读不到它们。"
        }
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
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
