import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// "补全书目信息" (0.28): a book's details for references, looked up online by ISBN or
/// title (Google Books, Open Library) and confirmed — or typed in — by the reader. Kept by
/// KongSeek (book-records.json); the file itself is not renamed or changed.
final class BookLookupModel: ObservableObject {
    @Published private(set) var path = ""
    @Published var title = ""
    @Published var authors = ""
    @Published var place = ""
    @Published var publisher = ""
    @Published var year = ""
    @Published var isbn = ""
    @Published private(set) var candidates: [BookLookup.Candidate] = []
    @Published private(set) var searching = 0
    @Published private(set) var status = ""
    @Published private(set) var hasRecord = false
    private var source = "手动"
    private var token = 0
    /// Services that did not answer in the current lookup.
    private var failures: [String] = []

    var fileName: String { (path as NSString).lastPathComponent }

    /// The details as they stand in the form.
    private var edited: EbookName {
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var name = EbookName(title: value(title) ?? fileName)
        name.authors = value(authors)
        name.place = value(place)
        name.publisher = value(publisher)
        name.year = value(year)
        name.isbn = value(isbn)
        return name
    }

    /// The reference the form gives, with what is still missing.
    var preview: Citation.Result {
        Citation.make(Preferences.citationStyle, name: edited, fallbackTitle: fileName)
    }

    func load(_ path: String) {
        token += 1
        self.path = path
        let info = BookInfo.read(URL(fileURLWithPath: path))
        let name = info.name
        title = name.title
        authors = name.authors ?? ""
        place = name.place ?? ""
        publisher = name.publisher ?? ""
        year = name.year ?? ""
        let fileName = (path as NSString).lastPathComponent
        isbn = name.isbn ?? fileName.range(of: #"97[89]\d{10}"#, options: .regularExpression).map { String(fileName[$0]) } ?? ""
        hasRecord = BookRecords.current().record(for: path) != nil
        source = BookRecords.current().record(for: path)?.source ?? "手动"
        candidates = []
        searching = 0
        status = preview.missing.isEmpty ? "书目信息已齐全，可直接核对。" : "缺" + preview.missing.joined(separator: "、") + "。可点“联网查找”，或直接填写。"
    }

    /// Asks Google Books and Open Library at the same time; the answers are only offered.
    func lookUp() {
        token += 1
        let current = token
        candidates = []
        let isbnValue = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        let titleValue = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorValue = authors.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls: [(String, URL?, (Data) -> [BookLookup.Candidate])] = [
            ("Google Books", BookLookup.googleQuery(isbn: isbnValue.isEmpty ? nil : isbnValue, title: titleValue, authors: authorValue.isEmpty ? nil : authorValue), BookLookup.googleBooks),
            ("Open Library", BookLookup.openLibraryQuery(isbn: isbnValue.isEmpty ? nil : isbnValue, title: titleValue, authors: authorValue.isEmpty ? nil : authorValue), BookLookup.openLibrary),
        ]
        searching = urls.count
        status = "正在查找" + (isbnValue.isEmpty ? "书名“\(titleValue)”" : "ISBN \(isbnValue)") + "…"
        failures = []
        for (name, url, parse) in urls {
            guard let url else { searching -= 1; continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("KongSeek (personal book list)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let found = data.map(parse) ?? []
                let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400
                DispatchQueue.main.async {
                    guard let self, current == self.token else { return }
                    self.searching -= 1
                    if !ok { self.failures.append(name) }
                    for candidate in found where !self.candidates.contains(where: { $0.id == candidate.id }) {
                        self.candidates.append(candidate)
                    }
                    if self.searching == 0 {
                        var text = self.candidates.isEmpty ? "没有查到。可直接填写，或改用书名、作者再查。" : "查到 \(self.candidates.count) 条，点一条填入下面，核对后再保存。"
                        if !self.failures.isEmpty {
                            text += self.failures.joined(separator: "、") + " 连不上" + (self.failures.contains("Google Books") ? "（在中国大陆通常需要代理）" : "") + "。"
                        }
                        self.status = text
                    }
                }
            }.resume()
        }
    }

    /// Fills the form with a candidate's details (nothing is saved yet).
    func use(_ candidate: BookLookup.Candidate) {
        // A Chinese title in the file name is kept rather than a romanized one from abroad.
        if EbookName.containsHan(candidate.title) || !EbookName.containsHan(title) { title = candidate.title }
        if let value = candidate.authors, EbookName.containsHan(value) || authors.isEmpty { authors = value }
        if let value = candidate.place, EbookName.containsHan(value) || place.isEmpty { place = value }
        if let value = candidate.publisher, EbookName.containsHan(value) || publisher.isEmpty { publisher = value }
        if let value = candidate.year { year = value }
        if let value = candidate.isbn { isbn = value }
        source = candidate.source
        status = "已填入 \(candidate.source) 的信息，请核对（尤其出版地与出版社）后保存。"
    }

    func save() {
        let name = edited
        var records = BookRecords.current()
        records.set(.init(title: name.title, authors: name.authors, place: name.place, publisher: name.publisher, year: name.year,
                          isbn: name.isbn, source: source), for: path)
        do {
            try records.save()
            hasRecord = true
            status = "已保存。以后拷贝参考文献、引文出处都用这些信息：" + preview.text
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }

    func clear() {
        var records = BookRecords.current()
        records.remove(path)
        try? records.save()
        load(path)
        status = "已清除补充的书目信息，恢复按文件名。"
    }

    func copyReference() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.text, forType: .string)
        status = "已拷贝：" + preview.text
    }
}

struct BookLookupView: View {
    @ObservedObject var model: BookLookupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            Form {
                TextField("书名", text: $model.title)
                TextField("作者", text: $model.authors, prompt: Text("如 杨伯峻译注"))
                TextField("出版地", text: $model.place, prompt: Text("如 北京"))
                TextField("出版者", text: $model.publisher, prompt: Text("如 中华书局"))
                TextField("出版年", text: $model.year, prompt: Text("如 1980"))
                TextField("ISBN", text: $model.isbn)
            }
            HStack {
                Button("联网查找") { model.lookUp() }.disabled(model.searching > 0)
                if model.searching > 0 { ProgressView().controlSize(.small) }
                Spacer()
                if model.hasRecord { Button("清除补充的信息") { model.clear() } }
                Button("拷贝参考文献") { model.copyReference() }
                Button("保存") { model.save() }.keyboardShortcut(.defaultAction)
            }
            Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("参考文献预览") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !model.preview.missing.isEmpty {
                        Text("缺：" + model.preview.missing.joined(separator: "、")).font(.caption).foregroundColor(.orange)
                    }
                    if !model.preview.notes.isEmpty {
                        Text(model.preview.notes.joined(separator: "；")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if !model.candidates.isEmpty {
                Text("查到的书目（点一条填入上面）").font(.callout.weight(.semibold))
                List(model.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(candidate.title).lineLimit(1)
                            Spacer()
                            Text(candidate.source).font(.caption2).foregroundColor(.secondary)
                        }
                        Text(candidate.summary + (candidate.isbn.map { " · ISBN \($0)" } ?? "")).font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.use(candidate) }
                }
                .frame(minHeight: 140)
            }
            Text("只记在 KongSeek 中，不改文件名，也不改文件本身。网上书目常有错漏（尤其古籍整理本的出版地、责任方式），请以版权页为准。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 560)
    }
}

final class BookLookupWindowController: NSWindowController {
    static let shared = BookLookupWindowController()
    let model = BookLookupModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "补全书目信息"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: BookLookupView(model: model))
        window.setContentSize(NSSize(width: 600, height: 640))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(path: String) {
        model.load(path)
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
