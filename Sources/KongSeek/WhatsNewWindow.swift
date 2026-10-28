import AppKit
import SwiftUI
import KongSeekCore

/// "KongSeek 已更新" (0.29): what changed since the version that was installed, as a
/// window that scrolls — one card per change, its name in bold, sub-points as a list —
/// instead of a long alert.
struct WhatsNewView: View {
    let version: String
    let previous: String
    let sections: [ReleaseNotes.Section]
    let openGuide: () -> Void
    let close: () -> Void

    private var itemCount: Int { sections.reduce(0) { $0 + ReleaseNotes.items($1.body).count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("KongSeek 已更新到 \(version)").font(.title2.weight(.semibold))
                    Text("原来的版本 \(previous)" + (itemCount > 0 ? " · \(sections.count) 个版本、\(itemCount) 项更新" : ""))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if sections.isEmpty {
                        Text("没有找到更新说明。").foregroundColor(.secondary)
                    }
                    ForEach(sections, id: \.version) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if sections.count > 1 {
                                Text(section.version).font(.headline).foregroundColor(.secondary)
                            }
                            ForEach(Array(ReleaseNotes.items(section.body).enumerated()), id: \.offset) { _, item in
                                card(item)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("全部更新记录见 设置 › 更新。").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("功能导览…", action: openGuide)
                Button("好", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 560)
    }

    private func card(_ item: ReleaseNotes.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead = item.lead {
                Text(lead).font(.body.weight(.semibold))
            }
            if !item.text.isEmpty {
                Text(styled(item.text)).foregroundColor(item.lead == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundColor(.secondary)
                    Text(styled(child)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    }

    /// `code` in monospace, as the CHANGELOG writes it.
    private func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: "`").enumerated() {
            var piece = AttributedString(part)
            if index % 2 == 1 { piece.font = .system(.body, design: .monospaced) }
            result += piece
        }
        return result
    }
}

final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    private var onClose: (() -> Void)?

    init(version: String, previous: String, sections: [ReleaseNotes.Section], openGuide: @escaping () -> Void, onClose: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "KongSeek 更新内容"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.onClose = onClose
        window.delegate = self
        let view = WhatsNewView(version: version, previous: previous, sections: sections,
                                openGuide: { openGuide() }, close: { [weak window] in window?.performClose(nil) })
        window.contentViewController = NSHostingController(rootView: view)
        // Short notes get a short window; long ones scroll inside 560 points.
        let lines = sections.reduce(0) { $0 + $1.body.components(separatedBy: "\n").count }
        window.setContentSize(NSSize(width: 600, height: min(560, max(360, 200 + lines * 22))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
