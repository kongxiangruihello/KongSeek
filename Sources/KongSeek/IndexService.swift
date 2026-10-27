import Foundation
import KongSeekCore

struct ResultItem: Equatable {
    let path: String
    let name: String
    let isFolder: Bool
    let score: Int
}

struct SearchOutcome {
    var items: [ResultItem] = []
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
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.runSearch(text, precision: precision, limit: limit, counts: counts)
            DispatchQueue.main.async {
                guard token == self.searchToken else { return }
                completion(outcome)
            }
        }
    }

    private func runSearch(_ text: String, precision: MatchPrecision, limit: Int, counts: [String: Int]) -> SearchOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index, let session else { return SearchOutcome() }
        let query = SearchQuery(trimmed)
        var outcome = SearchOutcome(highlightWords: query.highlightWords, notes: query.descriptions + query.natural.descriptions)
        let hits = session.search(query, precision: precision)
        outcome.matchCount = hits.count
        // Highest score first; among equal scores, files opened more often, then
        // shorter names. Ties are re-ranked group by group, only as far as shown.
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
                let keys = Dictionary(uniqueKeysWithValues: group.map { hit in
                    (hit.id, (opens: counts[index.path(of: hit.id)] ?? 0, length: index.name(of: hit.id).count))
                })
                group.sort { a, b in
                    let ka = keys[a.id]!, kb = keys[b.id]!
                    if ka.opens != kb.opens { return ka.opens > kb.opens }
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
