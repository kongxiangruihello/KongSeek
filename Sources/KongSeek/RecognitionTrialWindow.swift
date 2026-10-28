import AppKit
import SwiftUI
import PDFKit
import KongSeekCore
import KongSeekText

/// "识别试验" (0.22): the current page recognized by both engines side by side, to
/// judge on a real scan (e.g. vertical classical Chinese) which one to use.
final class RecognitionTrialModel: ObservableObject {
    struct Outcome {
        var text = ""
        var seconds = 0.0
        var failure: String?
        var characters: Int { text.filter { !$0.isWhitespace }.count }
    }

    @Published private(set) var title = ""
    @Published private(set) var vision: Outcome?
    @Published private(set) var liveText: Outcome?
    @Published private(set) var running = false

    func run(page: CGPDFPage, title: String) {
        self.title = title
        vision = nil
        liveText = nil
        running = true
        let media = page.getBoxRect(.mediaBox)
        let rotated = abs(Int(page.rotationAngle)) % 180 == 90
        let box = CGRect(x: 0, y: 0, width: rotated ? media.height : media.width, height: rotated ? media.width : media.height)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let image = SearchablePDF.render(page, box: box) else {
                DispatchQueue.main.async { self?.running = false }
                return
            }
            func measure(_ work: () throws -> String) -> Outcome {
                let start = Date()
                do { return Outcome(text: try work(), seconds: Date().timeIntervalSince(start)) } catch {
                    return Outcome(text: "", seconds: Date().timeIntervalSince(start), failure: error.localizedDescription)
                }
            }
            let first = measure { try TextRecognizer.recognize(image) }
            DispatchQueue.main.async { self?.vision = first }
            let second = measure { try LiveTextRecognizer.recognize(image) }
            DispatchQueue.main.async {
                self?.liveText = second
                self?.running = false
            }
        }
    }
}

struct RecognitionTrialView: View {
    @ObservedObject var model: RecognitionTrialModel
    @State private var engine = Preferences.ocrUseLiveText

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline)
            Text("同一页分别用两种引擎识别。竖排古籍请看哪一边按正确顺序读出了文字；横排文献两者通常都可用。")
                .font(.callout).foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 12) {
                column("标准引擎（Vision，目前在用）", model.vision)
                column("实况文本引擎（Live Text）", model.liveText)
            }
            HStack {
                if model.running { ProgressView().controlSize(.small); Text("正在识别…").font(.caption) }
                Spacer()
                Toggle("后台识别改用实况文本引擎", isOn: $engine)
                    .onChange(of: engine) { value in
                        Preferences.ocrUseLiveText = value
                        NotificationCenter.default.post(name: .ocrSettingsChanged, object: nil)
                    }
                    .help("只影响以后识别的文件；已识别的要在 设置 › 文字识别 中“清除识别结果”后重新识别")
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
    }

    private func column(_ title: String, _ outcome: RecognitionTrialModel.Outcome?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            if let outcome {
                Text(outcome.failure.map { "出错：\($0)" } ?? "\(outcome.characters) 字 · \(String(format: "%.1f", outcome.seconds)) 秒")
                    .font(.caption).foregroundColor(outcome.failure == nil ? .secondary : .orange)
                ScrollView {
                    Text(outcome.text.isEmpty ? "（没有识别出文字）" : outcome.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension Notification.Name {
    /// Posted when an OCR setting changes outside the settings window.
    static let ocrSettingsChanged = Notification.Name("KongSeekOCRSettingsChanged")
}

final class RecognitionTrialWindowController: NSWindowController {
    static let shared = RecognitionTrialWindowController()
    let model = RecognitionTrialModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "识别试验"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: RecognitionTrialView(model: model))
        window.setContentSize(NSSize(width: 900, height: 600))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func run(page: CGPDFPage, title: String) {
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.run(page: page, title: title)
    }
}
