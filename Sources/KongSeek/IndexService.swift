import AppKit
import KongSeekCore

struct ResultItem: Equatable {
    let path: String
    let name: String
    let isFolder: Bool
    let score: Int
    /// Found in text recognized from a scan (OCR), not in the file's own text.
    var recognized = false
    /// A web search row ("hd 仁"): opens this address instead of a file.
    var link: URL? = nil
    /// A dictionary row ("cd 仁"): the word's definition, "" if the dictionaries have none.
    var definition: String? = nil
    /// A file inside a .zip archive: its path in the archive (`path` is the archive).
    var innerPath: String? = nil

    var isFile: Bool { link == nil && definition == nil }
    var isInArchive: Bool { innerPath != nil }

    static func web(_ link: QuickLink, query: String) -> ResultItem? {
        guard let url = link.url(for: query) else { return nil }
        return ResultItem(path: url.absoluteString, name: "用 \(link.name) 搜索“\(query)”", isFolder: false, score: 0, link: url)
    }
}

struct SearchOutcome {
    var items: [ResultItem] = []
    /// Listing a folder's contents; nil when it is not in the index.
    var browsedFolder: String?
    var folderNotIndexed = false
    /// Full-text (Spotlight) results; `gathering` while Spotlight is still searching.
    var isContent = false
    var gathering = false
    /// Showing recently opened items because the query is empty.
    var isRecentList = false
    /// Matches before the display limit and attribute filters.
    var matchCount = 0
    var highlightWords: [String] = []
    var notes: [String] = []
}

enum IndexState: Equatable {
    case loading
    case building(entries: Int)
    case ready(entries: Int, updated: Date)
}

/// Owns the name index: loads it at launch, builds it when needed, keeps it
/// current with FSEvents (resuming from the saved event id), saves it, and runs
/// searches. All index work happens on one serial queue; callbacks arrive on main.
final class IndexService {
    private let queue = DispatchQueue(label: "KongSeek.index", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "KongSeek.build", qos: .utility)
    let storeURL: URL

    // Only touched on `queue`.
    private var index: NameIndex?
    private var session: SearchSession?
    private var watcher: FileChangeWatcher?
    private var saveItem: DispatchWorkItem?
    private var buildCancel: CancelFlag?
    private var roots: [String]
    private var rules: ExclusionRules

    // Only touched on main.
    private var searchToken = 0
    private(set) var state: IndexState = .loading
    /// Names inside .zip archives, searched along with the index when set.
    var archives: ArchiveIndex?
    var onStateChange: ((IndexState) -> Void)?

    init(roots: [String], rules: ExclusionRules) {
        self.roots = roots
        self.rules = rules
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storeURL = support.appendingPathComponent("KongSeek/name-index.ksidx")
    }

    /// Loads the saved index if it still matches the settings; otherwise builds one.
    func start() {
        queue.async { [self] in
            if let saved = try? NameIndex.load(from: storeURL), isUsable(saved) {
                install(saved, watchingFrom: saved.lastEventID)
            } else {
                startBuild()
            }
        }
    }

    func rebuild() {
        queue.async { [self] in startBuild() }
    }

    func update(roots newRoots: [String], rules newRules: ExclusionRules) {
        queue.async { [self] in
            roots = newRoots
            rules = newRules
            startBuild()
        }
    }

    /// Writes the index now (used at quit).
    func saveNow() {
        queue.sync { save() }
    }

    // MARK: - Index lifecycle (on queue)

    private func isUsable(_ saved: NameIndex) -> Bool {
        guard saved.isComplete, saved.lastEventID > 0, saved.rules == rules,
              saved.roots == NameIndex.effectiveRoots(roots, rules: rules) else { return false }
        // Event ids from another FSEvents database (e.g. after a restore) mean nothing.
        let current = saved.roots.first.flatMap(FileChangeWatcher.eventDatabaseUUID(forPath:))
        return current == nil || current == saved.eventDatabaseUUID
    }

    private func startBuild() {
        buildCancel?.cancel()
        let cancel = CancelFlag()
        buildCancel = cancel
        let roots = self.roots, rules = self.rules
        // Events from this moment on are replayed onto the new index afterwards.
        let since = FileChangeWatcher.currentEventID
        publish(.building(entries: 0))
        buildQueue.async { [self] in
            let built = NameIndex.build(roots: roots, rules: rules, progress: { [weak self] progress in
                self?.publish(.building(entries: progress.entries))
            }, isCancelled: { cancel.isCancelled })
            guard !cancel.isCancelled else { return }
            built.lastEventID = since
            built.eventDatabaseUUID = built.roots.first.flatMap(FileChangeWatcher.eventDatabaseUUID(forPath:))
            queue.async { [self] in
                guard !cancel.isCancelled else { return }
                install(built, watchingFrom: since)
                save()
            }
        }
    }

    private func install(_ newIndex: NameIndex, watchingFrom eventID: UInt64) {
        index = newIndex
        session = SearchSession(index: newIndex)
        watcher?.stop()
        let watcher = FileChangeWatcher(paths: newIndex.roots, since: eventID, latency: 0.5, queue: queue) { [weak self] batch in
            self?.handle(batch)
        }
        watcher.start()
        self.watcher = watcher
        publishReady()
    }

    private func handle(_ batch: FileChangeWatcher.Batch) {
        guard let index else { return }
        if batch.requiresFullRebuild {
            startBuild()
            return
        }
        let summary = index.apply(batch.changes, eventID: batch.lastEventID > 0 ? batch.lastEventID : nil)
        if summary.added > 0 || summary.removed > 0 { publishReady() }
        scheduleSave()
    }

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveItem = item
        queue.asyncAfter(deadline: .now() + 20, execute: item)
    }

    private func save() {
        saveItem?.cancel()
        saveItem = nil
        guard let index else { return }
        try? index.save(to: storeURL)
    }

    private func publishReady() {
        guard let index else { return }
        publish(.ready(entries: index.entryCount, updated: index.updated))
    }

    private func publish(_ newState: IndexState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = newState
            self.onStateChange?(newState)
        }
    }

    // MARK: - Search

    /// Searches on the index queue and calls `completion` on main, unless a newer
    /// search has started meanwhile.
    func search(_ text: String, precision: MatchPrecision, limit: Int = 200, completion: @escaping (SearchOutcome) -> Void) {
        searchToken += 1
        let token = searchToken
        let counts = Preferences.openCounts
        let opened = Preferences.lastOpened
        let archives = Preferences.archiveSearch ? self.archives : nil
        queue.async { [weak self] in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var outcome = trimmed.isEmpty
                ? Self.recentItems(counts: counts, opened: opened)
                : self.runSearch(trimmed, precision: precision, limit: limit, counts: counts)
            if !trimmed.isEmpty, let archives {
                Self.mergeArchiveHits(into: &outcome, query: SearchQuery(trimmed), archives: archives, limit: limit)
            }
            DispatchQueue.main.async {
                guard token == self.searchToken else { return }
                completion(outcome)
            }
        }
    }

    /// The contents of an indexed folder: all of it (folders first, then by
    /// name) when `filter` is empty, otherwise the matches ranked like a search.
    func browse(folder: String, filter: String, limit: Int = 500, completion: @escaping (SearchOutcome) -> Void) {
        searchToken += 1
        let token = searchToken
        let counts = Preferences.openCounts
        queue.async { [weak self] in
            guard let self else { return }
            var outcome = SearchOutcome()
            outcome.browsedFolder = folder
            if let index = self.index, let kids = index.childIDs(ofFolder: folder) {
                let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let items = kids.map { id -> ResultItem in
                        let flags = index.flags(of: id)
                        return ResultItem(path: index.path(of: id), name: index.name(of: id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: 0)
                    }.sorted { a, b in
                        if a.isFolder != b.isFolder { return a.isFolder }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                    outcome.matchCount = items.count
                    outcome.items = Array(items.prefix(limit))
                } else {
                    let query = SearchQuery(trimmed)
                    outcome = self.rank(index.refined(index.search(query, precision: .fuzzyName, within: kids), query: query), query: query, index: index, limit: limit, counts: counts)
                    outcome.browsedFolder = folder
                }
            } else {
                outcome.folderNotIndexed = true
            }
            DispatchQueue.main.async {
                guard token == self.searchToken else { return }
                completion(outcome)
            }
        }
    }

    /// Items opened from KongSeek, most used and most recent first: each open
    /// counts less the longer ago the item was last opened.
    static func recentItems(counts: [String: Int], opened: [String: Double], limit: Int = 30) -> SearchOutcome {
        let now = Date().timeIntervalSince1970
        let fileManager = FileManager.default
        let ranked = opened.map { path, time -> (String, Double) in
            let ageDays = max(0, now - time) / 86_400
            return (path, Double(counts[path] ?? 1) / (1 + ageDays / 7))
        }.sorted { $0.1 > $1.1 }
        var items: [ResultItem] = []
        for (path, _) in ranked where items.count < limit {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let isPackage = isDirectory.boolValue && NSWorkspace.shared.isFilePackage(atPath: path)
            items.append(ResultItem(path: path, name: (path as NSString).lastPathComponent, isFolder: isDirectory.boolValue && !isPackage, score: 0))
        }
        var outcome = SearchOutcome(items: items)
        outcome.isRecentList = true
        outcome.matchCount = items.count
        return outcome
    }

    /// Files in the index (optionally below `folder`) with size and date, for the
    /// duplicate finder. Calls back on main; an empty list while no index is loaded.
    func fileEntries(under folder: String?, minimumSize: Int64, completion: @escaping ([FileEntry]) -> Void) {
        queue.async { [weak self] in
            let entries = self?.index?.fileEntries(under: folder, minimumSize: minimumSize) ?? []
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// The archive paths in the index (ext:zip), for the archive scan. Calls back on
    /// the index queue, and not at all while no index is loaded.
    func archivePaths(completion: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            // Not loaded yet: skip, rather than report "no archives" and forget them all.
            guard let index = self?.index else { return }
            completion(index.search(SearchQuery("ext:zip")).map { index.path(of: $0.id) })
        }
    }

    /// Files inside archives whose name matches, placed a little below files of
    /// the same score on disk (KongFetch 4: score − 40). Type and date filters
    /// need attributes an archive entry does not have, so such queries skip archives.
    static func mergeArchiveHits(into outcome: inout SearchOutcome, query: SearchQuery, archives: ArchiveIndex, limit: Int) {
        let words = query.words + query.phrases
        let advanced = query.advanced
        guard query.valid, !words.isEmpty, !query.needsMetadata, !advanced.dupe, !advanced.attributes.isActive else { return }
        var exists: [String: Bool] = [:]
        let hits = archives.search(words, limit: 60, accept: { path in
            if let known = exists[path] { return known }
            let found = FileManager.default.fileExists(atPath: path)
            exists[path] = found
            return found
        }, acceptName: query.acceptsName).filter { hit in
            advanced.acceptsPath(hit.archive + "/" + hit.inner, isFolder: false)
        }
        guard !hits.isEmpty else { return }
        var items = outcome.items
        for hit in hits {
            let name = (hit.inner as NSString).lastPathComponent
            // Ordered like names in the index, a little below a file on disk with the same name.
            let score = Relevance.combined(relevance: Relevance.score(name: name, words: words), base: hit.score - 40)
            let item = ResultItem(path: hit.archive, name: name, isFolder: false, score: score, innerPath: hit.inner)
            let position = items.firstIndex { $0.score < item.score } ?? items.count
            items.insert(item, at: position)
        }
        outcome.items = Array(items.prefix(limit))
        outcome.matchCount += hits.count
    }

    private func runSearch(_ trimmed: String, precision: MatchPrecision, limit: Int, counts: [String: Int]) -> SearchOutcome {
        guard let index, let session else { return SearchOutcome() }
        let query = SearchQuery(trimmed)
        return rank(index.refined(session.search(query, precision: precision), query: query), query: query, index: index, limit: limit, counts: counts)
    }

    /// Orders hits for display and applies the attribute filters (type, date, size, tag).
    private func rank(_ hits: [SearchHit], query: SearchQuery, index: NameIndex, limit: Int, counts: [String: Int]) -> SearchOutcome {
        var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions + query.natural.descriptions)
        outcome.matchCount = hits.count
        // Highest score first; among equal scores: applications, then items opened
        // more often, then recently modified, then shorter names. Ties are
        // re-ranked group by group, only as far as shown.
        // dupe: keeps the index's order (same names together).
        if query.advanced.dupe {
            outcome.items = hits.prefix(limit).map { hit in
                let flags = index.flags(of: hit.id)
                return ResultItem(path: index.path(of: hit.id), name: index.name(of: hit.id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: hit.score)
            }
            return outcome
        }
        let sorted = hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
        var examined = 0
        var items: [ResultItem] = []
        var position = 0
        while position < sorted.count && items.count < limit {
            // Take the whole group with this score so open counts can reorder it.
            let score = sorted[position].score
            var end = position
            while end < sorted.count && sorted[end].score == score { end += 1 }
            var group = Array(sorted[position..<end])
            if group.count > 1 && group.count <= 2000 {
                struct TieKey { let isApp: Bool; let opens: Int; let modified: Double; let length: Int }
                let keys = Dictionary(uniqueKeysWithValues: group.map { hit -> (Int32, TieKey) in
                    let name = index.name(of: hit.id)
                    let path = index.path(of: hit.id)
                    let isApp = index.flags(of: hit.id).contains(.package) && name.lowercased().hasSuffix(".app")
                    return (hit.id, TieKey(isApp: isApp, opens: counts[path] ?? 0, modified: Self.modificationTime(path), length: name.count))
                })
                group.sort { a, b in
                    let ka = keys[a.id]!, kb = keys[b.id]!
                    if ka.isApp != kb.isApp { return ka.isApp }
                    if ka.opens != kb.opens { return ka.opens > kb.opens }
                    if ka.modified != kb.modified { return ka.modified > kb.modified }
                    if ka.length != kb.length { return ka.length < kb.length }
                    return a.id < b.id
                }
            }
            for hit in group {
                if items.count >= limit { break }
                let path = index.path(of: hit.id)
                if query.needsMetadata {
                    // Type, date, size and tag filters read file attributes; bounded so a
                    // broad query cannot stall the panel.
                    examined += 1
                    if examined > 3_000 { break }
                    guard query.acceptsMetadata(EntryMetadata.read(path: path)) else { continue }
                }
                let flags = index.flags(of: hit.id)
                items.append(ResultItem(path: path, name: index.name(of: hit.id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: hit.score))
            }
            if examined > 3_000 { break }
            position = end
        }
        outcome.items = items
        return outcome
    }
}

extension IndexService {
    /// Modification time without following symlinks; 0 if unreadable.
    static func modificationTime(_ path: String) -> Double {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    }
}

/// Thread-safe cancellation flag for a background build.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
