import Foundation

/// Where disk space goes, from the files in the index (0.16).
public enum SpaceReport {
    public struct Totals: Equatable, Sendable {
        public var files = 0
        /// Bytes stored on this Mac.
        public var local: Int64 = 0
        /// Bytes kept only in iCloud (not taking space here).
        public var cloudOnly: Int64 = 0
    }

    public struct FolderUsage: Equatable, Sendable {
        public var path: String
        public var local: Int64
        public var cloudOnly: Int64
        public var files: Int
    }

    public static func totals(_ files: [FileEntry]) -> Totals {
        var totals = Totals()
        for file in files {
            totals.files += 1
            if file.isLocal { totals.local += file.size } else { totals.cloudOnly += file.size }
        }
        return totals
    }

    /// The biggest files, largest first; with `localOnly`, iCloud-only files are left out.
    public static func largest(_ files: [FileEntry], localOnly: Bool = true, limit: Int = 300) -> [FileEntry] {
        Array(files.filter { !localOnly || $0.isLocal }.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }.prefix(limit))
    }

    /// Big files not changed since `before`, largest first.
    public static func stale(_ files: [FileEntry], before: Date, minimumSize: Int64 = 10_000_000, localOnly: Bool = true, limit: Int = 300) -> [FileEntry] {
        largest(files.filter { $0.modified < before && $0.size >= minimumSize }, localOnly: localOnly, limit: limit)
    }

    /// Folders up to `depth` levels below the roots (the roots themselves not listed),
    /// with the space their files use, largest first.
    public static func folders(_ files: [FileEntry], roots: [String], depth: Int = 3, localOnly: Bool = true, limit: Int = 100) -> [FolderUsage] {
        // Longest roots first, so a file in a nested root counts there.
        let sortedRoots = roots.sorted { $0.count > $1.count }
        var usage: [String: FolderUsage] = [:]
        for file in files {
            guard let root = sortedRoots.first(where: { Paths.isWithin(file.path, $0) && file.path != $0 }) else { continue }
            let relative = file.path.dropFirst(root == "/" ? 1 : root.count + 1)
            let components = relative.split(separator: "/")
            guard components.count > 1 else { continue }
            var folder = root == "/" ? "" : root
            for component in components.prefix(min(depth, components.count - 1)) {
                folder += "/" + component
                var entry = usage[folder] ?? FolderUsage(path: folder, local: 0, cloudOnly: 0, files: 0)
                entry.files += 1
                if file.isLocal { entry.local += file.size } else { entry.cloudOnly += file.size }
                usage[folder] = entry
            }
        }
        let size: (FolderUsage) -> Int64 = { localOnly ? $0.local : $0.local + $0.cloudOnly }
        return Array(usage.values.filter { size($0) > 0 }.sorted { size($0) != size($1) ? size($0) > size($1) : $0.path < $1.path }.prefix(limit))
    }
}
