import Foundation

/// Files downloaded lately (菜单栏 › 最近下载, 0.18): created after a date and carrying
/// the "where from" mark that browsers, Mail and AirDrop put on what they save
/// (the com.apple.metadata:kMDItemWhereFroms extended attribute).
public enum RecentDownloads {
    public static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// Whether the file was downloaded (has a "where from" mark).
    public static func isDownloaded(_ path: String) -> Bool {
        getxattr(path, whereFromsAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    public static func birthDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9)
    }
}

extension NameIndex {
    /// Files (not folders) created at or after `since`, newest first; with
    /// `downloadedOnly`, only those with a "where from" mark.
    public func recentlyCreated(since: Date, downloadedOnly: Bool = true, limit: Int = 20) -> [FileEntry] {
        let ids = liveEntryIDs().filter { flags[Int($0)] & (EntryFlags.directory.rawValue | EntryFlags.package.rawValue) == 0 }
        let chunk = 2048
        let count = (ids.count + chunk - 1) / chunk
        var parts = [[(FileEntry, Date)]](repeating: [], count: count)
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: count) { c in
                var found: [(FileEntry, Date)] = []
                for id in ids[(c * chunk)..<min(ids.count, (c + 1) * chunk)] {
                    let filePath = self.path(of: id)
                    var info = stat()
                    guard lstat(filePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                    let created = RecentDownloads.birthDate(info)
                    guard created >= since else { continue }
                    if downloadedOnly && !RecentDownloads.isDownloaded(filePath) { continue }
                    let dataless = info.st_flags & 0x4000_0000 != 0 // SF_DATALESS
                    let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                    found.append((FileEntry(path: filePath, size: Int64(info.st_size), modified: modified, isLocal: !dataless), created))
                }
                output[c] = found
            }
        }
        return Array(parts.flatMap { $0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }.prefix(limit).map { $0.0 })
    }
}
