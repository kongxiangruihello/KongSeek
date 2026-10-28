import AppKit
import KongSeekCore

/// KongSeek's own records (0.24): reading progress, saved file lists and the Trash log.
/// Main thread only.
enum Records {
    static let changed = Notification.Name("KongSeekRecordsChanged")

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongSeek")
    }

    /// Records are written here in order, off the main thread (0.44), so changing a note or
    /// a book's details does not wait for the disk; `flush()` at quit waits for them.
    private static let writeQueue = DispatchQueue(label: "KongSeek.records", qos: .utility)

    private static func write(_ url: URL, _ save: @escaping (URL) throws -> Void) {
        writeQueue.async { try? save(url) }
    }

    /// Waits until every record change is on disk.
    static func flush() {
        writeQueue.sync {}
    }

    // MARK: Reading progress

    private static let readingKey = "readingLog"
    private static var cachedReading: ReadingLog?

    static var reading: ReadingLog {
        get {
            if let cachedReading { return cachedReading }
            var log = ReadingLog()
            if let data = UserDefaults.standard.data(forKey: readingKey), let decoded = try? JSONDecoder().decode(ReadingLog.self, from: data) {
                log = decoded
            } else if let legacy = UserDefaults.standard.dictionary(forKey: "readerPages") as? [String: Int] {
                // Pages remembered by 0.19–0.23 (without dates or page counts).
                log = ReadingLog(legacyPages: legacy)
            }
            cachedReading = log
            return log
        }
        set {
            cachedReading = newValue
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: readingKey) }
        }
    }

    // MARK: Saved file lists

    private static var listsURL: URL { folder.appendingPathComponent("file-lists.json") }
    private static var cachedLists: SavedFileLists?

    static var lists: SavedFileLists {
        get {
            if let cachedLists { return cachedLists }
            let loaded = SavedFileLists.load(from: listsURL)
            cachedLists = loaded
            return loaded
        }
        set {
            cachedLists = newValue
            write(listsURL) { try newValue.save(to: $0) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Saved lists and page numbers follow files renamed by 批量重命名.
    static func followMoves(_ moves: [(from: String, to: String)]) {
        var updated = lists
        let before = updated
        for move in moves { updated.move(from: move.from, to: move.to) }
        if updated != before { lists = updated }
        var numbers = pageNumbers
        let numbersBefore = numbers
        for move in moves { numbers.move(from: move.from, to: move.to) }
        if numbers != numbersBefore { pageNumbers = numbers }
        var preferred = editions
        let preferredBefore = preferred
        for move in moves { preferred.move(from: move.from, to: move.to) }
        if preferred != preferredBefore { editions = preferred }
        var notesNow = notes
        let notesBefore = notesNow
        for move in moves { notesNow.move(from: move.from, to: move.to) }
        if notesNow != notesBefore { notes = notesNow }
        var choices = queryChoices
        let choicesBefore = choices
        for move in moves { choices.move(from: move.from, to: move.to) }
        if choices != choicesBefore { queryChoices = choices }
        var books = BookRecords.current()
        let booksBefore = books
        for move in moves { books.move(from: move.from, to: move.to) }
        if books != booksBefore { try? books.save() }
    }

    // MARK: 文件备注 (0.40)

    private static var notesURL: URL { folder.appendingPathComponent("file-notes.json") }
    private static var cachedNotes: FileNotes?

    static var notes: FileNotes {
        get {
            if let cachedNotes { return cachedNotes }
            let loaded = FileNotes.load(from: notesURL)
            cachedNotes = loaded
            return loaded
        }
        set {
            cachedNotes = newValue
            write(notesURL) { try newValue.save(to: $0) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: 按查询记住选择 (0.35)

    private static var choicesURL: URL { folder.appendingPathComponent("query-choices.json") }
    private static var cachedChoices: QueryChoices?

    static var queryChoices: QueryChoices {
        get {
            if let cachedChoices { return cachedChoices }
            let loaded = QueryChoices.load(from: choicesURL)
            cachedChoices = loaded
            return loaded
        }
        set {
            cachedChoices = newValue
            write(choicesURL) { try newValue.save(to: $0) }
        }
    }

    /// Remembers that `path` was opened after searching `query`.
    static func recordChoice(query: String, path: String) {
        var choices = queryChoices
        choices.record(query: query, path: path)
        queryChoices = choices
    }

    // MARK: 常用本 (0.28)

    private static var editionsURL: URL { folder.appendingPathComponent("preferred-editions.json") }
    private static var cachedEditions: PreferredEditions?

    static var editions: PreferredEditions {
        get {
            if let cachedEditions { return cachedEditions }
            let loaded = PreferredEditions.load(from: editionsURL)
            cachedEditions = loaded
            return loaded
        }
        set {
            cachedEditions = newValue
            write(editionsURL) { try newValue.save(to: $0) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Makes `path` the 常用本 of its book, or stops it being one.
    static func togglePreferred(_ path: String) {
        var preferred = editions
        if preferred.isPreferred(path) { preferred.remove(path) } else { preferred.prefer(path) }
        editions = preferred
    }

    // MARK: Printed page numbers (0.27)

    private static var pageNumbersURL: URL { folder.appendingPathComponent("page-numbers.json") }
    private static let pageNumbersLock = NSLock()
    private static var cachedPageNumbers: PageNumbers?

    /// "PDF 第 N 页 = 书上第 M 页" per book. Read from background work too, hence the lock.
    static var pageNumbers: PageNumbers {
        get {
            pageNumbersLock.lock()
            defer { pageNumbersLock.unlock() }
            if let cachedPageNumbers { return cachedPageNumbers }
            let loaded = PageNumbers.load(from: pageNumbersURL)
            cachedPageNumbers = loaded
            return loaded
        }
        set {
            pageNumbersLock.lock()
            cachedPageNumbers = newValue
            pageNumbersLock.unlock()
            write(pageNumbersURL) { try newValue.save(to: $0) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: Trash log

    private static var trashURL: URL { folder.appendingPathComponent("trash-log.json") }
    private static var cachedTrash: TrashLog?

    static var trash: TrashLog {
        get {
            if let cachedTrash { return cachedTrash }
            var loaded = TrashLog.load(from: trashURL)
            loaded.prune()
            cachedTrash = loaded
            return loaded
        }
        set {
            cachedTrash = newValue
            write(trashURL) { try newValue.save(to: $0) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Moves a file to the Trash and records it in the Trash log, so it can be put back
    /// later from 废纸篓记录. Returns where it went in the Trash.
    @discardableResult
    static func moveToTrash(_ url: URL, source: String) throws -> URL? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        let place = resulting.map { $0 as URL }
        if let place {
            var log = trash
            log.record(TrashLog.Entry(original: url.path, trashed: place.path, source: source, size: Int64(size)))
            trash = log
        }
        Preferences.forget(url.path)
        var choices = queryChoices
        choices.remove(url.path)
        queryChoices = choices
        return place
    }

    /// As `moveToTrash`, true when it worked.
    static func trashed(_ url: URL, source: String) -> Bool {
        do {
            try moveToTrash(url, source: source)
            return true
        } catch {
            return false
        }
    }

    /// Puts a file back from the Trash, through the log when it was recorded there.
    static func putBack(trashed: URL, to original: URL) -> Bool {
        var log = trash
        if let entry = log.entries.first(where: { $0.trashed == trashed.path && $0.restored == nil }) {
            if case .success(_) = log.putBack(entry.id) {
                trash = log
                return true
            }
            return false
        }
        guard !FileManager.default.fileExists(atPath: original.path) else { return false }
        return (try? FileManager.default.moveItem(at: trashed, to: original)) != nil
    }
}
