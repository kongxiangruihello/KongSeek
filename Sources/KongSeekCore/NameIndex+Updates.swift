import Foundation

extension NameIndex {
    /// Applies a batch of changed paths. Each changed path makes its folder be
    /// re-read (one directory listing) and compared with the index; a folder that
    /// appeared is scanned, one that disappeared is removed with its contents.
    /// `rescanSubtree` changes re-read every folder below the path, keeping what did not change.
    /// Changes inside anything the rules leave out (hidden names, excluded names or folders)
    /// are ignored. Cost depends on the folders touched, not on the size of the index.
    @discardableResult
    public func apply(_ changes: [IndexChange], eventID: UInt64? = nil) -> UpdateSummary {
        var summary = UpdateSummary()
        let compiled = rules.compiled()
        var subtreeTargets = Set<Int32>()
        var shallowTargets = Set<Int32>()

        for change in changes {
            let path = Paths.canonical(change.path)
            // The innermost root holding the path.
            guard let root = roots.filter({ Paths.isWithin(path, $0) }).max(by: { $0.count < $1.count }) else {
                // Dropped events can name a folder above the roots, even "/" (0.46):
                // every root inside it is checked again instead of the change being lost.
                if change.rescanSubtree {
                    let covered = roots.filter { Paths.isWithin($0, path) }.compactMap { nearestIndexedFolder($0) }
                    if !covered.isEmpty {
                        subtreeTargets.formUnion(covered)
                        summary.relevantPaths.append(path)
                    }
                }
                continue
            }
            // Changes inside something the rules leave out — ~/Library, but also hidden
            // folders such as ~/.cache or a project's .build, node_modules, .git — can never
            // alter the index (0.46: before, these were only checked against excluded
            // folders, and a rescan reported in ~/.codex re-read the whole home folder).
            if Self.isSkipped(path, below: root, rules: compiled) { continue }
            summary.relevantPaths.append(path)
            if change.rescanSubtree {
                if let id = nearestIndexedFolder(path) { subtreeTargets.insert(id) }
            } else {
                // A changed root is re-read itself; anything else through its parent folder.
                let anchor = roots.contains(path) ? path : Paths.parent(path)
                if let id = nearestIndexedFolder(anchor) { shallowTargets.insert(id) }
            }
        }

        // Full rescans first; skip those already covered by a rescan above them.
        let minimalSubtrees = subtreeTargets.filter { target in
            !ancestors(of: target).contains(where: subtreeTargets.contains)
        }
        for target in minimalSubtrees.sorted() where !isDeleted(target) {
            if resyncSubtree(target, rules: compiled, summary: &summary) {
                summary.foldersRescanned += 1
            } else {
                // The folder itself is gone: let its parent drop it.
                shallowTargets.insert(parents[Int(target)])
            }
        }

        var queue = shallowTargets.sorted()
        var visited = Set<Int32>()
        while let folder = queue.popLast() {
            guard visited.insert(folder).inserted, !isDeleted(folder) else { continue }
            if minimalSubtrees.contains(folder) || ancestors(of: folder).contains(where: minimalSubtrees.contains) { continue }
            if !resync(folder, rules: compiled, summary: &summary) {
                let parent = parents[Int(folder)]
                if parent >= 0 { queue.append(parent) }
            }
        }

        if let eventID { lastEventID = max(lastEventID, eventID) }
        if summary.added > 0 || summary.removed > 0 {
            generation += 1
            updated = Date()
        }
        if deletedCount > 50_000 && deletedCount * 4 > flags.count { compact() }
        return summary
    }

    /// Brings a whole subtree in line with the disk, folder by folder (`resync` on
    /// each), keeping the entries that did not change (0.46). A rescan used to drop
    /// the subtree and scan it again, which recomputed the pinyin of every name with
    /// the system transliterator: a rescan of the home folder took over a minute of
    /// CPU, and FSEvents asks for rescans often enough to keep that going for hours.
    /// Returns false when the starting folder no longer exists.
    private func resyncSubtree(_ start: Int32, rules: CompiledExclusions, summary: inout UpdateSummary) -> Bool {
        var stack: [Int32] = [start]
        var isStart = true
        while let folder = stack.popLast() {
            if isDeleted(folder) { continue }
            let existing = Set(children[folder] ?? [])
            let readable = resync(folder, rules: rules, summary: &summary)
            if isStart {
                isStart = false
                if !readable { return false }
            }
            guard readable else { continue }
            // Folders that were already indexed are checked in turn; new ones were scanned whole by `resync`.
            for child in children[folder] ?? [] where existing.contains(child) && !isDeleted(child)
                && flags[Int(child)] & EntryFlags.directory.rawValue != 0 {
                stack.append(child)
            }
        }
        return true
    }

    /// True when `path`, below `root`, is or lies inside something the rules skip.
    static func isSkipped(_ path: String, below root: String, rules: CompiledExclusions) -> Bool {
        guard path != root else { return false }
        let base = root == "/" ? "" : root
        var prefix = base
        for component in path.dropFirst(base.count + 1).split(separator: "/") {
            let name = String(component)
            prefix += "/" + name
            if rules.skips(name: name, path: prefix) { return true }
        }
        return false
    }

    /// Folders whose changes can never alter the index, for FSEvents to filter out
    /// before they reach KongSeek (0.46): the excluded folders inside a root (~/Library),
    /// then hidden or excluded-name folders directly in a root (such as ~/.cache).
    /// Most of the file activity on a Mac happens in these places.
    public func watchExclusions() -> [String] {
        let compiled = rules.compiled()
        var result = compiled.paths.filter { path in roots.contains { $0 != path && Paths.isWithin(path, $0) } }.sorted()
        for root in roots where directoryIDs[root] != nil {
            for item in DirectoryReader.children(of: root) ?? [] where item.kind == .directory {
                let path = Paths.join(root, item.name)
                if compiled.skips(name: item.name, path: path), !result.contains(path),
                   !roots.contains(where: { Paths.isWithin($0, path) }) {
                    result.append(path)
                }
            }
        }
        return result
    }

    /// Re-reads one folder and reconciles its direct children.
    /// Returns false when the folder itself no longer exists.
    private func resync(_ folder: Int32, rules: CompiledExclusions, summary: inout UpdateSummary) -> Bool {
        guard let path = directoryPaths[folder] else { return true }
        guard let items = DirectoryReader.children(of: path) else {
            if isRoot(folder) {
                summary.removed += removeChildren(of: folder)
                return true
            }
            return false
        }
        summary.foldersResynced += 1
        var existing: [String: Int32] = [:]
        for child in children[folder] ?? [] { existing[names.string(at: Int(child))] = child }

        for item in items {
            let childPath = Paths.join(path, item.name)
            if rules.skips(name: item.name, path: childPath) { continue }
            let kind = Self.classify(item, path: childPath, rules: rules)
            if let old = existing.removeValue(forKey: item.name) {
                if EntryFlags(rawValue: flags[Int(old)]).intersection(.kindMask) == kind { continue }
                summary.removed += removeSubtree(old)
            }
            let before = flags.count
            let id = appendEntry(name: item.name, parent: folder, flags: kind, deriveInline: true)
            if kind.contains(.directory) { scanSubtree(of: id, rules: rules) }
            summary.added += flags.count - before
        }
        for (_, old) in existing { summary.removed += removeSubtree(old) }
        return true
    }

    func nearestIndexedFolder(_ path: String) -> Int32? {
        var current = path
        while true {
            if let id = directoryIDs[current], !isDeleted(id) { return id }
            guard roots.contains(where: { Paths.isWithin(current, $0) }) else { return nil }
            let up = Paths.parent(current)
            if up == current { return nil }
            current = up
        }
    }

    private func ancestors(of id: Int32) -> [Int32] {
        var result: [Int32] = []
        var current = parents[Int(id)]
        while current >= 0 {
            result.append(current)
            current = parents[Int(current)]
        }
        return result
    }

    func isDeleted(_ id: Int32) -> Bool { flags[Int(id)] & EntryFlags.deleted.rawValue != 0 }
    func isRoot(_ id: Int32) -> Bool { flags[Int(id)] & EntryFlags.root.rawValue != 0 }

    private func removeChildren(of folder: Int32) -> Int {
        var removed = 0
        for child in children[folder] ?? [] { removed += removeSubtree(child) }
        return removed
    }

    /// Marks an entry and everything below it deleted. Space is reclaimed by `compact()`.
    @discardableResult
    func removeSubtree(_ id: Int32) -> Int {
        let parent = parents[Int(id)]
        if parent >= 0 { children[parent]?.removeAll { $0 == id } }
        var stack = [id]
        var removed = 0
        while let current = stack.popLast() {
            let i = Int(current)
            if flags[i] & EntryFlags.deleted.rawValue != 0 { continue }
            flags[i] |= EntryFlags.deleted.rawValue
            deletedCount += 1
            removed += 1
            if let kids = children.removeValue(forKey: current) { stack.append(contentsOf: kids) }
            if let path = directoryPaths.removeValue(forKey: current) {
                directoryIDs.removeValue(forKey: path)
                foldedDirectoryPaths.removeValue(forKey: current)
            }
        }
        return removed
    }

    /// Drops deleted entries and renumbers the rest (ids change; sessions reset).
    public func compact() {
        guard deletedCount > 0 else { return }
        let total = flags.count
        var remap = [Int32](repeating: -1, count: total)
        var newNames = ByteColumn(), newFolded = ByteColumn(), newFull = ByteColumn(), newInitials = ByteColumn()
        var newParents: [Int32] = [], newFlags: [UInt8] = [], newStems: [UInt16] = []
        let live = total - deletedCount
        newNames.reserve(entries: live, bytes: names.bytes.count)
        newFolded.reserve(entries: live, bytes: folded.bytes.count)
        newParents.reserveCapacity(live)
        newFlags.reserveCapacity(live)
        newStems.reserveCapacity(live)
        for i in 0..<total where flags[i] & EntryFlags.deleted.rawValue == 0 {
            remap[i] = Int32(newFlags.count)
            let parent = parents[i]
            newParents.append(parent < 0 ? -1 : remap[Int(parent)])
            newFlags.append(flags[i])
            newNames.append(from: names, at: i)
            if derivedReady {
                newFolded.append(from: folded, at: i)
                newFull.append(from: pinyinFull, at: i)
                newInitials.append(from: pinyinInitials, at: i)
                newStems.append(stemLengths[i])
            }
        }
        names = newNames
        parents = newParents
        flags = newFlags
        if derivedReady {
            folded = newFolded
            pinyinFull = newFull
            pinyinInitials = newInitials
            stemLengths = newStems
        }
        deletedCount = 0
        generation += 1
        rebuildDirectoryTables()
    }
}
