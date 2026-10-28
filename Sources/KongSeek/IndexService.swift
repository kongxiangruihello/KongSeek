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
    /// A row that fills the search field instead of opening something: a saved
    /// search, or an example from the syntax help.
    var fill: QueryFill? = nil
    /// A folder heading when results are grouped by folder (⌘G, 0.19); not selectable.
    var isHeader = false
    /// Other files with the same content, merged into this row (0.36).
    var copies: [String] = []
    /// For a book: "杨伯峻 · 中华书局 · 1980 · 在读" (0.40).
    var bookLine: String? = nil
    /// The reader's note on the file (0.40).
    var note: String? = nil
    /// How often the words occur in it (0.41), when ordering full text by hits.
    var hitCount: Int? = nil
    /// Found in KongSeek's own text index of e-books (0.37), not by Spotlight.
    var ownText = false

    var isFile: Bool { link == nil && definition == nil && fill == nil && !isHeader }
    var isInArchive: Bool { innerPath != nil }

    static func web(_ link: QuickLink, query: String) -> ResultItem? {
        guard let url = link.url(for: query) else { return nil }
        return ResultItem(path: url.absoluteString, name: "用 \(link.name) 搜索“\(query)”", isFolder: false, score: 0, link: url)
    }
}

/// What a saved-search or syntax-help row puts into the search field.
struct QueryFill: Equatable {
    var text: String
    /// Replace what is typed (saved searches, whole examples) rather than add to it.
    var replace: Bool
    /// Select this part of `text` after filling it (an example value to type over).
    var select: String?
    var explanation: String
    var isSaved = false
    var isHistory = false
    /// "添加常用收藏搜索…" (0.35): opens the list of preset searches.
    var isPresetPicker = false
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
    /// Not matches but suggestions (0.35): names that sound alike or differ in one character.
    var isSuggestion = false
    /// 相关文件 of one file (0.39), in groups with their own headings.
    var isRelated = false
    /// 文件夹跳转 "/讲义" (0.40): folders only; ↩ enters the folder.
    var isFolderJump = false
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
    /// While building: about how many items the finished index will have (the previous
    /// index's count), for a progress figure; 0 when unknown.
    private(set) var buildEstimate = 0
    /// Whether searches are answered (by the previous index) while a new one is built.
    var searchableWhileBuilding: Bool { buildEstimate > 0 }
    /// Names inside .zip archives, searched along with the index when set.
    var archives: ArchiveIndex?
    var onStateChange: ((IndexState) -> Void)?
    /// Paths FSEvents reported changed (0.38), on main: the e-book text index follows them.
    var onFilesChanged: (([String]) -> Void)?

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
                // An index from an earlier version (or with stale event ids) for the same
                // folders is searched while the new one is built, so search never stops (0.20).
                if let old = try? NameIndex.load(from: storeURL, acceptingOlderFormats: true), old.rules == rules,
                   old.roots == NameIndex.effectiveRoots(roots, rules: rules) {
                    install(old, watchingFrom: FileChangeWatcher.currentEventID, announce: false)
                }
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
        let estimate = index?.entryCount ?? 0
        DispatchQueue.main.async { [weak self] in self?.buildEstimate = estimate }
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

    private func install(_ newIndex: NameIndex, watchingFrom eventID: UInt64, announce: Bool = true) {
        index = newIndex
        session = SearchSession(index: newIndex)
        watcher?.stop()
        let watcher = FileChangeWatcher(paths: newIndex.roots, since: eventID, latency: 0.5, queue: queue) { [weak self] batch in
            self?.handle(batch)
        }
        watcher.start()
        self.watcher = watcher
        if announce { publishReady() }
    }

    private func handle(_ batch: FileChangeWatcher.Batch) {
        guard let index else { return }
        if batch.requiresFullRebuild {
            startBuild()
            return
        }
        let summary = index.apply(batch.changes, eventID: batch.lastEventID > 0 ? batch.lastEventID : nil)
        if summary.added > 0 || summary.removed > 0 { publishReady() }
        let paths = batch.changes.map(\.path)
        if !paths.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onFilesChanged?(paths) }
        }
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
        let aliases = Preferences.searchAliases
        let chosen = Records.queryChoices.preferred(for: text)
        let mergeCopies = Preferences.mergeCopies
        let order = Preferences.resultOrder
        let notes = Records.notes
        let jump = FolderJump.query(text)
        queue.async { [weak self] in
            guard let self else { return }
            let trimmed = (jump ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
            var outcome = trimmed.isEmpty
                ? Self.recentItems(counts: counts, opened: opened)
                : self.runSearch(trimmed, precision: precision, limit: limit, counts: counts, opened: opened, aliases: aliases, chosen: chosen,
                                 order: order, notes: notes)
            if jump != nil {
                // Folders the reader works in first: opens of what is inside them.
                let affinity = Dictionary(outcome.items.map { ($0.path, FolderJump.affinity(of: $0.path, counts: counts)) }, uniquingKeysWith: { first, _ in first })
                let ranked = outcome.items.enumerated().sorted { a, b in
                    let x = affinity[a.element.path] ?? 0, y = affinity[b.element.path] ?? 0
                    return x != y ? x > y : a.offset < b.offset
                }
                outcome.items = ranked.map { $0.element }
                outcome.isFolderJump = true
                outcome.notes.append("文件夹跳转：常去的在前 · ↩ 进入浏览 · ⌘↩ 在访达中显示")
            }
            if !trimmed.isEmpty, let archives {
                Self.mergeArchiveHits(into: &outcome, query: SearchQuery(trimmed), archives: archives, limit: limit)
            }
            if mergeCopies, !trimmed.isEmpty, !SearchQuery(trimmed).advanced.dupe {
                outcome.items = Self.mergingCopies(outcome.items)
            }
            Self.annotate(&outcome.items, notes: notes)
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
        let notes = Records.notes
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
            Self.annotate(&outcome.items, notes: notes)
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
    func fileEntries(under folder: String?, minimumSize: Int64, extensions: Set<String>? = nil, completion: @escaping ([FileEntry]) -> Void) {
        queue.async { [weak self] in
            let entries = self?.index?.fileEntries(under: folder, minimumSize: minimumSize, extensions: extensions) ?? []
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// 相关文件 (0.39): other editions of the same book, other versions of the same
    /// document, and what changed lately in the same folder. Calls back on main.
    func related(to path: String, completion: @escaping (SearchOutcome) -> Void) {
        queue.async { [weak self] in
            guard let self, let index = self.index else { return }
            let ext = (path as NSString).pathExtension.lowercased()
            var wanted = RelatedFiles.familyExtensions(of: path)
            if DuplicateFinder.bookExtensions.contains(ext) { wanted.formUnion(DuplicateFinder.bookExtensions) }
            let groups = RelatedFiles.find(for: path, among: index.fileEntries(under: nil, minimumSize: 1, extensions: wanted))
            let folder = (path as NSString).deletingLastPathComponent
            let listed = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                       includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            let shown = Set(groups.editions + groups.versions)
            let recent = listed.compactMap { url -> (String, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true, url.path != path, !shown.contains(url.path) else { return nil }
                return (url.path, values?.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }.prefix(10).map { $0.0 }

            var outcome = SearchOutcome()
            outcome.isRelated = true
            outcome.notes = ["“\((path as NSString).lastPathComponent)”的相关文件 · ⎋ 返回搜索"]
            func add(_ title: String, _ paths: [String]) {
                guard !paths.isEmpty else { return }
                outcome.items.append(ResultItem(path: "header:related:" + title, name: title, isFolder: false, score: paths.count, isHeader: true))
                outcome.items += paths.map { ResultItem(path: $0, name: ($0 as NSString).lastPathComponent, isFolder: false, score: 0) }
            }
            add("同一部书的其他版本", groups.editions)
            add("同一文稿的其他版本", groups.versions)
            add("同一文件夹中最近改过的", Array(recent))
            outcome.matchCount = outcome.items.filter { !$0.isHeader }.count
            if outcome.items.isEmpty { outcome.notes.append("没有找到其他版本，文件夹中也没有其他文件") }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Files downloaded in the last `days` days, newest first (menu bar › 最近下载).
    /// Calls back on main; empty while no index is loaded.
    func recentDownloads(days: Int = 7, limit: Int = 12, completion: @escaping ([FileEntry]) -> Void) {
        queue.async { [weak self] in
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            let entries = self?.index?.recentlyCreated(since: since, limit: limit) ?? []
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

    private func runSearch(_ trimmed: String, precision: MatchPrecision, limit: Int, counts: [String: Int],
                           opened: [String: Double] = [:], aliases: SearchAliases = .none, chosen: [String] = [],
                           order: ResultOrder = .relevance, notes: FileNotes = FileNotes()) -> SearchOutcome {
        guard let index, let session else { return SearchOutcome() }
        let query = SearchQuery(trimmed)
        // 打开过: (0.35) searches only what was opened from KongSeek, in that time.
        var within: [Int32]?
        if query.advanced.opened {
            within = opened.compactMap { path, time -> Int32? in
                query.advanced.acceptsOpened(at: Date(timeIntervalSince1970: time)) ? index.id(forPath: path) : nil
            }.sorted()
            if within?.isEmpty ?? true {
                var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions)
                outcome.notes.append("没有符合条件的打开记录（只记从 KongSeek 打开的文件）")
                return outcome
            }
        }
        // 备注: (0.40) searches only the files with such a note.
        if let terms = query.advanced.noteTerms {
            let noted = Set(notes.paths(matching: terms).compactMap { index.id(forPath: $0) })
            within = (within.map { Set($0).intersection(noted) } ?? noted).sorted()
            if within?.isEmpty ?? true {
                var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions)
                outcome.notes.append("没有这样的备注（⌘K › 写备注… 可给文件写备注）")
                return outcome
            }
        }
        var hits = within == nil
            ? index.refined(session.search(query, precision: precision), query: query)
            : index.refined(index.search(query, precision: precision, within: within), query: query)
        var extraWords: [String] = []
        var extraNotes: [String] = []

        // 同义词与别名 (0.35): files named with another name of the person or book,
        // one relevance level below those named as typed.
        if query.valid, !query.words.isEmpty {
            let expansions = aliases.expansions(of: query.words)
            if !expansions.isEmpty {
                var best = Dictionary(hits.map { ($0.id, $0.score) }, uniquingKeysWith: { max($0, $1) })
                for words in expansions {
                    let alternative = query.replacingWords(words)
                    for hit in index.refined(index.search(alternative, precision: precision, within: within), query: alternative) {
                        let score = hit.score >= 100_000 ? hit.score - 100_000 : hit.score - 50
                        if score > (best[hit.id] ?? Int.min) { best[hit.id] = score }
                    }
                }
                hits = best.map { SearchHit(id: $0.key, score: $0.value) }
                for (position, word) in query.words.enumerated() {
                    let others = Set(expansions.map { $0[position] }).subtracting([word])
                    guard !others.isEmpty else { continue }
                    let ordered = aliases.alternatives(for: word).filter { others.contains($0) }
                    extraWords += ordered
                    extraNotes.append("同义词：\(word) = " + ordered.joined(separator: "、"))
                }
            }
        }

        // 作者: / 出版社: / 年: (0.38): books only, by their details.
        if query.advanced.book.isActive {
            let records = BookRecords.current()
            hits = hits.filter { hit in
                let path = index.path(of: hit.id)
                guard DuplicateFinder.bookExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
                return query.advanced.book.accepts(details: Self.bookDetails(path, records: records), fileName: index.name(of: hit.id), aliases: aliases)
            }
            if hits.isEmpty {
                var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions)
                outcome.notes.append("书目信息取自文件名、EPUB 自带书目和补全过的书目；可在搜索结果上 ⌘K › 补全书目信息")
                return outcome
            }
            extraWords += (query.advanced.book.authors + query.advanced.book.publishers).filter { !$0.excluded }.map(\.text)
        }

        // 搜不到时的建议 (0.35): names that sound the same or differ in one character.
        if hits.isEmpty, query.valid, !query.words.isEmpty, within == nil {
            let suggested = suggestions(for: query, index: index)
            if !suggested.hits.isEmpty {
                var outcome = rank(suggested.hits, query: query, index: index, limit: limit, counts: counts)
                outcome.highlightWords += suggested.words
                outcome.notes.insert("没有名称含“\(query.words.joined(separator: " "))”的文件；以下是读音相同或只差一个字的名称，您是不是要找它们", at: 0)
                outcome.isSuggestion = true
                return outcome
            }
        }
        // 命中次数 is for full text; names are ordered by relevance then.
        var outcome = order == .relevance || order == .hits || query.advanced.dupe
            ? rank(hits, query: query, index: index, limit: limit, counts: counts, chosen: chosen)
            : ordered(hits, by: order, query: query, index: index, limit: limit)
        outcome.highlightWords += extraWords
        outcome.notes += extraNotes
        return outcome
    }

    /// Results sorted by date, size or name instead of relevance (0.38). Up to 50,000 of
    /// the best matches are sorted (their dates and sizes read from disk).
    private func ordered(_ hits: [SearchHit], by order: ResultOrder, query: SearchQuery, index: NameIndex, limit: Int) -> SearchOutcome {
        var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions + query.natural.descriptions)
        outcome.matchCount = hits.count
        outcome.notes.append("按\(order.title)排序")
        var pool = hits
        if pool.count > 50_000 {
            pool = Array(pool.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(50_000))
            outcome.notes.append("只排了最匹配的 5 万项")
        }
        struct Keyed { let hit: SearchHit; let modified: Double; let size: Int64; let name: String }
        let keyed = pool.map { hit -> Keyed in
            var info = stat()
            let path = index.path(of: hit.id)
            let found = lstat(path, &info) == 0
            let modified = found ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 : 0
            return Keyed(hit: hit, modified: modified, size: found ? Int64(info.st_size) : 0, name: order == .name ? index.name(of: hit.id) : "")
        }
        let sorted: [Keyed]
        switch order {
        case .modified: sorted = keyed.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.hit.id < $1.hit.id }
        case .size: sorted = keyed.sorted { $0.size != $1.size ? $0.size > $1.size : $0.hit.id < $1.hit.id }
        case .name: sorted = keyed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .relevance, .hits: sorted = keyed
        }
        var items: [ResultItem] = []
        var examined = 0
        for entry in sorted where items.count < limit {
            let path = index.path(of: entry.hit.id)
            if query.needsMetadata {
                examined += 1
                if examined > 3_000 { break }
                guard query.acceptsMetadata(EntryMetadata.read(path: path)) else { continue }
            }
            let flags = index.flags(of: entry.hit.id)
            items.append(ResultItem(path: path, name: index.name(of: entry.hit.id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: entry.hit.score))
        }
        outcome.items = items
        return outcome
    }

    /// Names that sound like the words (同音字), or hold a word with one character
    /// different, missing or added; for when nothing matches as typed.
    private func suggestions(for query: SearchQuery, index: NameIndex) -> (hits: [SearchHit], words: [String]) {
        var best: [Int32: Int] = [:]
        var words: [String] = []
        func add(_ found: [SearchHit], _ alternative: SearchQuery, keep: (Int32) -> Bool) {
            for hit in index.refined(found, query: alternative) where keep(hit.id) {
                best[hit.id] = max(best[hit.id] ?? Int.min, hit.score)
            }
        }
        if let spelled = SpellingVariants.pinyinWords(query.words) {
            let alternative = query.replacingWords(spelled)
            add(index.search(alternative, precision: .fuzzyName), alternative) { _ in true }
            words += spelled
        }
        var tries = 0
        for (position, word) in query.words.enumerated() {
            for parts in SpellingVariants.gaps(word) where tries < 12 {
                tries += 1
                var replaced = query.words
                replaced.replaceSubrange(position...position, with: parts)
                let alternative = query.replacingWords(replaced)
                add(index.search(alternative, precision: .fuzzyName), alternative) { id in
                    SpellingVariants.withinOneEdit(index.name(of: id), of: word)
                }
                words += parts
            }
        }
        return (best.map { SearchHit(id: $0.key, score: $0.value) }, words)
    }

    /// Orders hits for display and applies the attribute filters (type, date, size, tag).
    /// `chosen` (0.35): files opened after this very query before, put first.
    private func rank(_ hits: [SearchHit], query: SearchQuery, index: NameIndex, limit: Int, counts: [String: Int], chosen: [String] = []) -> SearchOutcome {
        var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions + query.natural.descriptions)
        outcome.matchCount = hits.count
        // Highest score first. Among matches that are equally good (the same relevance
        // level, or the same 3.2 score for matches not refined), applications come
        // first, then items opened more often from KongSeek (0.19), then the finer
        // score, recently modified, shorter names. Re-ranked group by group, only as
        // far as shown.
        // dupe: keeps the index's order (same names together).
        if query.advanced.dupe {
            outcome.items = hits.prefix(limit).map { hit in
                let flags = index.flags(of: hit.id)
                return ResultItem(path: index.path(of: hit.id), name: index.name(of: hit.id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: hit.score)
            }
            return outcome
        }
        // Items opened often from KongSeek move up a little among refined matches
        // (0.19): up to 12 relevance points, about what separates a match at a word
        // boundary from one inside a word, never enough to pass a much better match.
        var boosted = hits
        if !counts.isEmpty {
            for (k, hit) in hits.enumerated() where hit.score >= 100_000 {
                let opens = counts[index.path(of: hit.id)] ?? 0
                if opens > 0 { boosted[k] = SearchHit(id: hit.id, score: hit.score + Self.openBonus(opens) * 100_000) }
            }
        }
        let sorted = boosted.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
        var examined = 0
        var items: [ResultItem] = []
        var position = 0
        while position < sorted.count && items.count < limit {
            // Take the whole group with this relevance level so open counts can reorder it.
            let level = Self.relevanceLevel(sorted[position].score)
            var end = position
            while end < sorted.count && Self.relevanceLevel(sorted[end].score) == level { end += 1 }
            var group = Array(sorted[position..<end])
            if group.count > 1 && group.count <= 2000 {
                struct TieKey { let isApp: Bool; let opens: Int; let score: Int; let modified: Double; let length: Int }
                let keys = Dictionary(uniqueKeysWithValues: group.map { hit -> (Int32, TieKey) in
                    let name = index.name(of: hit.id)
                    let path = index.path(of: hit.id)
                    let isApp = index.flags(of: hit.id).contains(.package) && name.lowercased().hasSuffix(".app")
                    return (hit.id, TieKey(isApp: isApp, opens: counts[path] ?? 0, score: hit.score, modified: Self.modificationTime(path), length: name.count))
                })
                group.sort { a, b in
                    let ka = keys[a.id]!, kb = keys[b.id]!
                    if ka.isApp != kb.isApp { return ka.isApp }
                    if ka.opens != kb.opens { return ka.opens > kb.opens }
                    if ka.score != kb.score { return ka.score > kb.score }
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
        if !chosen.isEmpty {
            let found = Set(hits.map(\.id))
            for path in chosen.reversed() {
                if let current = items.firstIndex(where: { $0.path == path && !$0.isInArchive }) {
                    items.insert(items.remove(at: current), at: 0)
                } else if let id = index.id(forPath: path), found.contains(id),
                          !query.needsMetadata || query.acceptsMetadata(EntryMetadata.read(path: path)) {
                    let flags = index.flags(of: id)
                    items.insert(ResultItem(path: path, name: index.name(of: id), isFolder: flags.contains(.directory) && !flags.contains(.package), score: Int.max / 2), at: 0)
                }
            }
            items = Array(items.prefix(limit))
        }
        outcome.items = items
        return outcome
    }
}

extension IndexService {
    /// Results with the same content shown once (0.36): the best placed, with the
    /// others as its copies. Files only in iCloud are not read.
    static func mergingCopies(_ items: [ResultItem]) -> [ResultItem] {
        let files = items.compactMap { item -> (path: String, size: Int64)? in
            guard item.isFile, !item.isFolder, !item.isInArchive else { return nil }
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { return nil }
            return (item.path, Int64(info.st_size))
        }
        let groups = CopyGroups.group(files) { path, size in copyHashes.hash(path, size: size) }
        guard !groups.isEmpty else { return items }
        let hidden = Set(groups.values.flatMap { $0 })
        return items.compactMap { item -> ResultItem? in
            guard !item.isInArchive else { return item }
            if hidden.contains(item.path) { return nil }
            var merged = item
            if let copies = groups[item.path] { merged.copies = copies }
            return merged
        }
    }

    static let copyHashes = ContentHashCache()

    /// A book's details for 作者: / 出版社: / 年: (0.38): from its name, an EPUB's package
    /// (read once while the file is unchanged), then the confirmed record. Nil when nothing is known.
    static func bookDetails(_ path: String, records: BookRecords) -> EbookName? {
        let url = URL(fileURLWithPath: path)
        let stem = EbookName.splitMark(url.deletingPathExtension().lastPathComponent).stem
        var details = EbookName.parse(stem)
        if url.pathExtension.lowercased() == "epub", details?.authors == nil || details?.publisher == nil || details?.year == nil,
           let package = epubDetails.details(path) {
            var merged = details ?? EbookName(title: stem)
            merged.authors = merged.authors ?? package.authors
            merged.publisher = merged.publisher ?? package.publisher
            merged.year = merged.year ?? package.year
            details = merged
        }
        if records.record(for: path) != nil {
            details = records.apply(to: details ?? EbookName(title: stem), path: path)
        }
        return details
    }

    static let epubDetails = EpubDetailsCache()

    /// The book line and note of each result (0.40). An EPUB's package is used only if
    /// read before; the others are read in the background for next time.
    static func annotate(_ items: inout [ResultItem], notes: FileNotes) {
        let records = BookRecords.current()
        var unread: [String] = []
        for index in items.indices where items[index].isFile && !items[index].isFolder && !items[index].isInArchive {
            let path = items[index].path
            items[index].note = notes.note(for: path)?.text
            let ext = (path as NSString).pathExtension.lowercased()
            guard DuplicateFinder.bookExtensions.contains(ext) else { continue }
            let stem = EbookName.splitMark(((path as NSString).lastPathComponent as NSString).deletingPathExtension).stem
            var details = EbookName.parse(stem)
            if ext == "epub" {
                switch epubDetails.cached(path) {
                case .some(let package):
                    if let package {
                        var merged = details ?? EbookName(title: stem)
                        merged.authors = merged.authors ?? package.authors
                        merged.publisher = merged.publisher ?? package.publisher
                        merged.year = merged.year ?? package.year
                        details = merged
                    }
                case .none:
                    unread.append(path)
                }
            }
            if records.record(for: path) != nil { details = records.apply(to: details ?? EbookName(title: stem), path: path) }
            var parts = [details?.authors, details?.publisher, details?.year].compactMap { $0 }.filter { !$0.isEmpty }
            if let state = FinderTags.readingState(of: path) { parts.append(state) }
            items[index].bookLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if !unread.isEmpty {
            DispatchQueue.global(qos: .utility).async { for path in unread.prefix(200) { _ = IndexService.epubDetails.details(path) } }
        }
    }

    /// How good a match is, without the finer 3.2 score folded into refined scores
    /// (Relevance.combined = relevance × 100,000 + 3.2 score): matches at one level
    /// may be reordered by how often they were opened.
    /// Relevance points for having opened an item: 1 → 4, 3 → 8, 7 or more → 12.
    static func openBonus(_ opens: Int) -> Int {
        min(12, Int((4 * log2(Double(1 + max(0, opens)))).rounded()))
    }

    static func relevanceLevel(_ score: Int) -> Int {
        score >= 100_000 ? score / 100_000 * 100_000 : score
    }

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

/// Content hashes of files, kept while their size and date stay the same (0.36), so
/// merging copies in the results reads a file once, not on every keystroke.
final class ContentHashCache {
    private let lock = NSLock()
    private var entries: [String: (size: Int64, modified: Double, hash: String)] = [:]

    func hash(_ path: String, size: Int64) -> String? {
        let modified = IndexService.modificationTime(path)
        lock.lock()
        if let entry = entries[path], entry.size == size, entry.modified == modified {
            lock.unlock()
            return entry.hash
        }
        lock.unlock()
        // A file only in iCloud would be downloaded by reading it.
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded { return nil }
        guard let hash = CopyGroups.contentHash(path, size: size) else { return nil }
        lock.lock()
        if entries.count > 5_000 { entries.removeAll() }
        entries[path] = (size, modified, hash)
        lock.unlock()
        return hash
    }
}

/// The authors, publisher and year an EPUB's package gives (0.38), kept while the file
/// is unchanged, so 作者: does not open every EPUB on every keystroke. Files only in
/// iCloud are not read.
final class EpubDetailsCache {
    private let lock = NSLock()
    private var entries: [String: (modified: Double, details: EbookName?)] = [:]

    /// What was read before, without reading: .none when not read yet (0.40).
    func cached(_ path: String) -> EbookName?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path] else { return .none }
        return .some(entry.details)
    }

    func details(_ path: String) -> EbookName? {
        let modified = IndexService.modificationTime(path)
        lock.lock()
        if let entry = entries[path], entry.modified == modified {
            lock.unlock()
            return entry.details
        }
        lock.unlock()
        let url = URL(fileURLWithPath: path)
        var details: EbookName?
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != .notDownloaded,
           let package = EpubMetadata.read(url) {
            details = EbookName(title: package.title ?? "", authors: package.creators.isEmpty ? nil : package.creators.joined(separator: "、"),
                                publisher: package.publisher, year: package.year)
        }
        lock.lock()
        if entries.count > 20_000 { entries.removeAll() }
        entries[path] = (modified, details)
        lock.unlock()
        return details
    }
}

/// How results are ordered (0.38): by how well they match, or by date, size or name.
enum ResultOrder: String, CaseIterable {
    case relevance, modified, size, name, hits

    var title: String {
        switch self {
        case .relevance: return "相关度"
        case .modified: return "修改时间"
        case .size: return "大小"
        case .name: return "名称"
        case .hits: return "命中次数（全文）"
        }
    }
}
