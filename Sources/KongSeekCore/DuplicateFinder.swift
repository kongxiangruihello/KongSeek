import Foundation
import CryptoKit

/// A file considered by the duplicate finder.
public struct FileEntry: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date
    /// False for a file kept only in iCloud (reading it would download it).
    public var isLocal: Bool

    public init(path: String, size: Int64, modified: Date, isLocal: Bool = true) {
        self.path = path
        self.size = size
        self.modified = modified
        self.isLocal = isLocal
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Files that are the same, or versions of the same document.
public struct DuplicateGroup: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Byte-for-byte identical.
        case identical
        /// Version names of one document ("x (1)", "x副本", "x_v2", "x 2024-10-01"…).
        case versions
    }

    public var kind: Kind
    /// Newest first.
    public var files: [FileEntry]
    /// For versions: how much of each older file's text the newest one shares (0…1),
    /// by path; missing when the text could not be read.
    public var similarity: [String: Double] = [:]

    /// Space freed by keeping only the newest file.
    public var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

public enum DuplicateFinder {
    // MARK: Identical files

    /// Groups files with the same content: same size first, then the first and last
    /// 64 KB, then a SHA-256 of everything. Files only in iCloud are skipped.
    public static func identical(_ files: [FileEntry], minimumSize: Int64 = 1, progress: ((Int, Int) -> Void)? = nil,
                                 isCancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: files.filter { $0.isLocal && $0.size >= max(1, minimumSize) }, by: \.size)
            .values.filter { $0.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for sameSize in candidates {
            if isCancelled() { break }
            var byQuick: [String: [FileEntry]] = [:]
            for file in sameSize {
                if let key = quickHash(file.path, size: file.size) { byQuick[key, default: []].append(file) }
                done += 1
                progress?(done, total)
            }
            for sameQuick in byQuick.values where sameQuick.count > 1 {
                // Small files are covered completely by the quick hash.
                let confirmed: [[FileEntry]]
                if sameQuick[0].size <= 131_072 {
                    confirmed = [sameQuick]
                } else {
                    var byFull: [String: [FileEntry]] = [:]
                    for file in sameQuick {
                        if isCancelled() { break }
                        if let key = fullHash(file.path) { byFull[key, default: []].append(file) }
                    }
                    confirmed = Array(byFull.values)
                }
                for group in confirmed where group.count > 1 {
                    groups.append(DuplicateGroup(kind: .identical, files: newestFirst(group)))
                }
            }
        }
        return groups.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.files[0].path < $1.files[0].path }
    }

    static func quickHash(_ path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 65_536
        let head: Data?
        do { head = try handle.read(upToCount: chunk) } catch { return nil }
        hasher.update(data: head ?? Data())
        if size > Int64(chunk) * 2 {
            do {
                try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
                hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
            } catch {
                return nil
            }
        } else {
            do { hasher.update(data: try handle.readToEnd() ?? Data()) } catch { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // read(upToCount:) returns nil (not an error) at the end of the file.
            let data: Data?
            do { data = try handle.read(upToCount: 4 << 20) } catch { return nil }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func newestFirst(_ files: [FileEntry]) -> [FileEntry] {
        files.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
    }

    // MARK: Versions of one document

    /// The document a name refers to, without version marks: "中华文明史 (1).pptx",
    /// "中华文明史副本.pptx", "中华文明史_v2.pptx" and "中华文明史 2024-10-01.pptx" all give
    /// "中华文明史". URL-encoded names (from downloads) are decoded first.
    public static func versionKey(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        var stem = SearchText.fold((decoded as NSString).deletingPathExtension)
        let marks = "副本|copy|自动保存|已恢复|recovered|备份|bak|backup|old|new|旧版?|新版|最终版?|终稿|定稿|修改[版稿]?|修订版?|final|草稿|draft"
        let patterns = [
            "[(（\\[【]\\s*(\\d{1,3}|\(marks))\\s*[)）\\]】]",            // (1)  [自动保存]  （副本）
            "(\\d{4})[-_.年/]?(\\d{1,2})[-_.月/]?(\\d{1,2})日?",           // 2024-10-01, 20241001
            "[-_\\s]*(v|ver|版本)\\s*\\d+(\\.\\d+)*$",                      // _v2, v1.3
            "[-_\\s]*(的)?(\(marks))(\\s*\\d{1,3})?$",                       // 副本 2, final, 最终版
            // Not "x 2": that is as often chapter 2 as a second copy.
        ]
        // Applied until nothing changes, so "x 副本 (2)" and "x_v2 最终版" also reduce.
        var previous = ""
        while previous != stem {
            previous = stem
            for pattern in patterns {
                stem = stem.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            }
        }
        let key = stem.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return key.isEmpty ? SearchText.fold((decoded as NSString).deletingPathExtension) : key
    }

    /// Extensions that count as the same kind of document for versions.
    static func family(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ppt", "pptx", "key": return "slides"
        case "doc", "docx", "pages", "rtf", "odt": return "text"
        case "xls", "xlsx", "numbers", "csv": return "sheet"
        case "jpg", "jpeg", "png", "heic", "tif", "tiff": return "image"
        default: return ext
        }
    }

    /// Groups of files whose names are versions of the same document (same kind of
    /// file, different content). `text` returns a document's text for the similarity
    /// figure (nil when unreadable); files already found identical are passed in
    /// `identical` and only their newest copy takes part.
    public static func versions(_ files: [FileEntry], identical: [DuplicateGroup] = [], minimumSize: Int64 = 1,
                                text: ((String) -> String?)? = nil, progress: ((Int, Int) -> Void)? = nil,
                                isCancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        let extraCopies = Set(identical.flatMap { $0.files.dropFirst().map(\.path) })
        let considered = files.filter { $0.size >= minimumSize && !extraCopies.contains($0.path) }
        let grouped = Dictionary(grouping: considered) { family($0.path) + "\u{0}" + versionKey($0.name) }
            .values.filter { $0.count > 1 }
        let total = grouped.count
        var groups: [DuplicateGroup] = []
        for (number, members) in grouped.enumerated() {
            if isCancelled() { break }
            var group = DuplicateGroup(kind: .versions, files: newestFirst(members))
            if let text, let newest = group.files.first, newest.isLocal, let reference = text(newest.path) {
                let base = shingles(reference)
                for file in group.files.dropFirst() where file.isLocal {
                    if let other = text(file.path) { group.similarity[file.path] = containment(of: shingles(other), in: base) }
                }
            }
            groups.append(group)
            progress?(number + 1, total)
        }
        return groups.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.files[0].path < $1.files[0].path }
    }

    // MARK: Text similarity

    /// Hashes of the 4-character pieces of a text (spaces ignored, up to 400,000 characters).
    static func shingles(_ text: String) -> Set<UInt64> {
        let scalars = Array(SearchText.fold(String(text.prefix(400_000))).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard scalars.count >= 4 else { return Set(scalars.isEmpty ? [] : [hash(scalars[...])]) }
        var result = Set<UInt64>()
        result.reserveCapacity(scalars.count)
        for start in 0...(scalars.count - 4) { result.insert(hash(scalars[start..<start + 4])) }
        return result
    }

    private static func hash(_ piece: ArraySlice<Unicode.Scalar>) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325 // FNV-1a
        for scalar in piece {
            value ^= UInt64(scalar.value)
            value &*= 0x100000001b3
        }
        return value
    }

    /// Share of `part`'s pieces that also occur in `whole` (an older version's text
    /// kept in the newest one gives a high figure even when the newest one grew).
    static func containment(of part: Set<UInt64>, in whole: Set<UInt64>) -> Double {
        guard !part.isEmpty else { return whole.isEmpty ? 1 : 0 }
        return Double(part.intersection(whole).count) / Double(part.count)
    }

    /// Similarity of two texts, 0…1 (shared pieces of the shorter one).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = shingles(a), y = shingles(b)
        return x.count <= y.count ? containment(of: x, in: y) : containment(of: y, in: x)
    }
}

extension NameIndex {
    /// Every file (not folders or app bundles) in the index, optionally only below
    /// `folder`, at least `minimumSize` bytes, with size, date and whether it is on
    /// this Mac (iCloud placeholders are "dataless").
    /// With `extensions` (lowercased, without "."), only files with those extensions.
    public func fileEntries(under folder: String? = nil, minimumSize: Int64 = 1, extensions: Set<String>? = nil) -> [FileEntry] {
        let scope = folder.map(Paths.canonical)
        let ids = liveEntryIDs().filter { flags[Int($0)] & (EntryFlags.directory.rawValue | EntryFlags.package.rawValue) == 0 }
        let chunk = 2048
        let count = (ids.count + chunk - 1) / chunk
        var parts = [[FileEntry]](repeating: [], count: count)
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: count) { c in
                var found: [FileEntry] = []
                for id in ids[(c * chunk)..<min(ids.count, (c + 1) * chunk)] {
                    let filePath = self.path(of: id)
                    if let scope, !Paths.isWithin(filePath, scope) || filePath == scope { continue }
                    if let extensions, !extensions.contains((filePath as NSString).pathExtension.lowercased()) { continue }
                    var info = stat()
                    guard lstat(filePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int64(info.st_size) >= minimumSize else { continue }
                    let dataless = info.st_flags & 0x4000_0000 != 0 // SF_DATALESS
                    let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                    found.append(FileEntry(path: filePath, size: Int64(info.st_size), modified: modified, isLocal: !dataless))
                }
                output[c] = found
            }
        }
        return parts.flatMap { $0 }
    }
}
