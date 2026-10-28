import AppKit
import SwiftUI
import KongSeekCore
import KongSeekText

/// 批量补全书目信息 (0.41): the books of a search whose references lack something, each
/// looked up online (Open Library and Google Books, by ISBN or title), with what was
/// found offered as a table to confirm. Only matches by ISBN or the very title are
/// proposed; nothing is saved until 保存所选.
final class BatchBookLookupModel: ObservableObject {
    struct Row: Identifiable {
        enum State: Equatable { case waiting, searching, found, notFound, failed }

        let id = UUID()
        var path: String
        var current: EbookName
        var proposed: EbookName?
        var source = ""
        var state: State = .waiting
        var accepted = false

        var fileName: String { (path as NSString).lastPathComponent }
    }

    @Published var rows: [Row] = []
    @Published private(set) var running = false
    @Published private(set) var status = ""
    private var token = 0
    private static let workers = 2

    /// The books among `paths` whose reference lacks author, publisher, place or year,
    /// and have no confirmed record yet.
    func load(_ paths: [String]) {
        stop()
        let records = BookRecords.current()
        rows = paths.filter { DuplicateFinder.bookExtensions.contains(($0 as NSString).pathExtension.lowercased()) && records.record(for: $0) == nil }
            .compactMap { path -> Row? in
                let info = BookInfo.read(URL(fileURLWithPath: path), readMetadata: false)
                let missing = Citation.make(.gbt7714, name: info.name, fallbackTitle: info.name.title).missing
                return missing.isEmpty ? nil : Row(path: path, current: info.name)
            }
        status = rows.isEmpty ? "这些书的书目信息都已齐全，或已补全过。" : "\(rows.count) 本书的书目不全。点“开始查找”，逐本联网查找（每本约 1–3 秒）。"
    }

    func start() {
        guard !running, rows.contains(where: { $0.state == .waiting }) else { return }
        token += 1
        running = true
        for _ in 0..<Self.workers { next(token: token) }
    }

    func stop() {
        token += 1
        if running {
            running = false
            for index in rows.indices where rows[index].state == .searching { rows[index].state = .waiting }
            status = "已停止。" + summary
        }
    }

    private var summary: String {
        let found = rows.filter { $0.state == .found }.count
        let accepted = rows.filter(\.accepted).count
        return "查到 \(found) / \(rows.count) 本，已选 \(accepted) 本。"
    }

    private func next(token current: Int) {
        guard current == token else { return }
        guard let index = rows.firstIndex(where: { $0.state == .waiting }) else {
            if !rows.contains(where: { $0.state == .searching }) {
                running = false
                status = "查找完成。" + summary + "核对后点“保存所选”。"
            }
            return
        }
        rows[index].state = .searching
        let row = rows[index]
        status = "正在查找《\(row.current.title)》… " + summary
        let isbn = row.current.isbn ?? BookLookup.isbn(inName: row.fileName)
        let title = row.current.title
        let authors = row.current.authors
        let requests: [(URL?, (Data) -> [BookLookup.Candidate])] = [
            (BookLookup.openLibraryQuery(isbn: isbn, title: title, authors: authors), BookLookup.openLibrary),
            (BookLookup.googleQuery(isbn: isbn, title: title, authors: authors), BookLookup.googleBooks),
        ]
        let group = DispatchGroup()
        let collected = Collected()
        for (url, parse) in requests {
            guard let url else { continue }
            group.enter()
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("KongSeek (personal book list)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, response, error in
                let found = data.map(parse) ?? []
                let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400
                collected.add(found, ok: ok)
                group.leave()
            }.resume()
        }
        let id = row.id
        group.notify(queue: .main) { [weak self] in
            guard let self, current == self.token, let position = self.rows.firstIndex(where: { $0.id == id }) else { return }
            let (all, failed) = collected.snapshot()
            if let match = BookLookup.confidentMatch(all, title: title, isbn: isbn) {
                self.rows[position].proposed = BookLookup.completed(self.rows[position].current, with: match)
                self.rows[position].source = match.source
                self.rows[position].state = .found
                // Proposed for saving only when it adds something.
                self.rows[position].accepted = self.rows[position].proposed != self.rows[position].current
            } else {
                self.rows[position].state = failed >= 2 ? .failed : .notFound
            }
            // A pause between books, out of courtesy to the services.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.next(token: current) }
        }
    }

    /// What the services answered for one book, from their threads.
    private final class Collected {
        private let lock = NSLock()
        private var candidates: [BookLookup.Candidate] = []
        private var failures = 0

        func add(_ found: [BookLookup.Candidate], ok: Bool) {
            lock.lock()
            candidates += found
            if !ok { failures += 1 }
            lock.unlock()
        }

        func snapshot() -> ([BookLookup.Candidate], Int) {
            lock.lock()
            defer { lock.unlock() }
            return (candidates, failures)
        }
    }

    /// Saves the chosen rows as confirmed records.
    func save() {
        var records = BookRecords.current()
        var saved = 0
        for row in rows where row.accepted {
            guard let name = row.proposed else { continue }
            records.set(.init(title: name.title, authors: name.authors, place: name.place, publisher: name.publisher, year: name.year,
                              isbn: name.isbn, source: row.source), for: row.path)
            saved += 1
        }
        do {
            try records.save()
            rows.removeAll { $0.accepted && $0.proposed != nil }
            status = "已保存 \(saved) 本的书目信息。作者:、出版社:、年: 搜索和参考文献都会用到。"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }

    func edit(_ row: Row) {
        BookLookupWindowController.shared.present(path: row.path)
    }
}

struct BatchBookLookupView: View {
    @ObservedObject var model: BatchBookLookupModel

    private func line(_ name: EbookName) -> String {
        [name.authors, [name.place, name.publisher].compactMap { $0 }.joined(separator: "："), name.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func stateText(_ state: BatchBookLookupModel.Row.State) -> String {
        switch state {
        case .waiting: return "待查"
        case .searching: return "查找中…"
        case .found: return "查到"
        case .notFound: return "没有可靠的结果"
        case .failed: return "连不上"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.status).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("停止") { model.stop() }
                } else {
                    Button("开始查找") { model.start() }.disabled(!model.rows.contains { $0.state == .waiting })
                }
                Button("保存所选") { model.save() }.keyboardShortcut(.defaultAction)
                    .disabled(model.running || !model.rows.contains { $0.accepted })
            }
            List {
                ForEach($model.rows) { $row in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $row.accepted).labelsHidden().disabled(row.proposed == nil)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.fileName).lineLimit(1).truncationMode(.middle)
                            Text("现有：" + (line(row.current).isEmpty ? "（无）" : line(row.current))).font(.caption).foregroundColor(.secondary)
                            if let proposed = row.proposed {
                                Text("查到：" + line(proposed) + (proposed.title != row.current.title ? "（书名：\(proposed.title)）" : "") + " · " + row.source)
                                    .font(.caption).foregroundColor(.blue)
                            }
                        }
                        Spacer()
                        Text(stateText(row.state)).font(.caption).foregroundColor(row.state == .found ? .green : .secondary)
                        Button("逐本核对…") { model.edit(row) }.controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("只提议 ISBN 相同或书名完全相同的结果，请逐条核对（网上书目常有错漏，尤其古籍整理本的出版地与责任方式）。只记在 KongSeek 中，不改文件。Google Books 在中国大陆通常需要代理。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }
}

final class BatchBookLookupWindowController: NSWindowController {
    static let shared = BatchBookLookupWindowController()
    let model = BatchBookLookupModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "批量补全书目信息"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: BatchBookLookupView(model: model))
        window.setContentSize(NSSize(width: 820, height: 600))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(paths: [String]) {
        model.load(paths)
        if window?.isVisible != true { window?.placeRemembered() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
