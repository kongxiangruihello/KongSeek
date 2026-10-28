import Foundation

/// 记录防损坏 (0.44): KongSeek's own records — 备注、补全的书目、书上页码、常用本、文件清单、
/// 废纸篓记录 — are JSON files. One that cannot be read (cut short by a power failure, or
/// written in a form this version does not know) is moved aside rather than taken as empty,
/// so the next save does not overwrite what it held.
public enum RecordFile {
    /// Part of the name a file moved aside gets: "file-notes.损坏-20261029-063000.json".
    public static let damagedMark = ".损坏-"

    /// The record at `url`; `empty` when there is none, or when it cannot be read (then the
    /// file is moved aside).
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, iso8601Dates: Bool = true, empty: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return empty }
        let decoder = JSONDecoder()
        if iso8601Dates { decoder.dateDecodingStrategy = .iso8601 }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            setAside(url)
            return empty
        }
    }

    /// Moves an unreadable record next to itself under a dated name; the new name, or nil.
    @discardableResult
    public static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let aside = url.deletingLastPathComponent().appendingPathComponent(base + damagedMark + formatter.string(from: now) + ext)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    /// Records moved aside in `folder` (also the snippets' older "corrupt-" ones), by name.
    public static func damagedFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.contains(damagedMark) || $0.contains(".corrupt-") }.sorted().map { folder.appendingPathComponent($0) }
    }
}

/// 记录备份 (0.44): once a day the records are copied into 记录备份/2026-10-29; the newest
/// `keep` days are kept, and one can be put back.
public enum RecordBackup {
    public static let folderName = "记录备份"
    /// The record files, by name in Application Support/KongSeek.
    public static let fileNames = ["file-notes.json", "book-records.json", "page-numbers.json", "preferred-editions.json",
                                   "file-lists.json", "trash-log.json", "query-choices.json", "quote-history.json", "snippets.json"]

    /// Makes today's backup unless there is one; the new folder, or nil.
    @discardableResult
    public static func backUpIfDue(from folder: URL, now: Date = Date(), keep: Int = 14) throws -> URL? {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(folderName, isDirectory: true)
        let target = root.appendingPathComponent(stamp(now, format: "yyyy-MM-dd"), isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { return nil }
        let present = fileNames.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return nil }
        try copy(present, from: folder, to: target)
        prune(root, keep: keep)
        return target
    }

    /// The backups, newest first.
    public static func backups(in folder: URL) -> [URL] {
        let root = folder.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }

    /// Puts the files of `backup` back into `folder`. The records as they are now are first
    /// kept in a backup of their own ("2026-10-29 恢复前 063000"). Returns the files put back.
    @discardableResult
    public static func restore(_ backup: URL, into folder: URL, now: Date = Date()) throws -> [String] {
        let fm = FileManager.default
        let names = fileNames.filter { fm.fileExists(atPath: backup.appendingPathComponent($0).path) }
        guard !names.isEmpty else { return [] }
        let current = fileNames.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if !current.isEmpty {
            let before = folder.appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(stamp(now, format: "yyyy-MM-dd") + " 恢复前 " + stamp(now, format: "HHmmss"), isDirectory: true)
            try copy(current, from: folder, to: before)
        }
        for name in names {
            let data = try Data(contentsOf: backup.appendingPathComponent(name))
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        return names
    }

    private static func copy(_ names: [String], from folder: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names {
            let destination = target.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: folder.appendingPathComponent(name), to: destination)
        }
    }

    private static func prune(_ root: URL, keep: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >)
        for name in names.dropFirst(max(1, keep)) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static func stamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// 异常退出提示 (0.44): what macOS wrote in DiagnosticReports about KongSeek.
public struct CrashReport: Equatable, Sendable {
    public var name: String
    public var date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }

    /// Whether a report file is about the KongSeek app (not ks, not the tests).
    public static func isAboutApp(_ name: String) -> Bool {
        guard name.hasPrefix("KongSeek") else { return false }
        let rest = name.dropFirst("KongSeek".count)
        return rest.first.map { "-_.".contains($0) } ?? false
    }

    /// What happened, in words: 异常退出, 无响应, CPU 占用过高…
    public var kind: String {
        let lower = name.lowercased()
        if lower.contains("cpu_resource") { return "CPU 占用过高" }
        if lower.contains("diskwrites_resource") { return "磁盘写入过多" }
        if lower.contains("wakeups_resource") { return "后台唤醒过多" }
        if lower.hasSuffix(".hang") || lower.hasSuffix(".spin") { return "无响应" }
        return "异常退出"
    }

    /// The reports after `since`, newest first.
    public static func newer(_ reports: [CrashReport], than since: Date) -> [CrashReport] {
        reports.filter { $0.date > since }.sorted { $0.date > $1.date }
    }
}

/// 卡顿记录 (0.44): times the main thread did not answer for a while (the spinning
/// cursor), with what KongSeek was doing then. Kept on disk across launches.
public struct HitchLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var milliseconds: Double
        public var activity: String
    }

    public private(set) var entries: [Entry] = []
    public var capacity = 50

    public init() {}

    public mutating func add(date: Date, milliseconds: Double, activity: String) {
        entries.append(Entry(date: date, milliseconds: milliseconds, activity: activity))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The hitches of the last `days` days.
    public func recent(days: Double, now: Date = Date()) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.date) <= days * 86_400 }
    }

    /// "最近 7 天 3 次，最长 2.4 秒（预览：论语译注.pdf，10月28日 21:05）", or nil when none.
    public func summary(days: Double = 7, now: Date = Date()) -> String? {
        let list = recent(days: days, now: now)
        guard let longest = list.max(by: { $0.milliseconds < $1.milliseconds }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let seconds = String(format: "%.1f", longest.milliseconds / 1000)
        let what = longest.activity.isEmpty ? "" : longest.activity + "，"
        return "最近 \(Int(days)) 天 \(list.count) 次，最长 \(seconds) 秒（\(what)\(formatter.string(from: longest.date))）"
    }

    public static func load(from url: URL) -> HitchLog {
        RecordFile.load(HitchLog.self, from: url, empty: HitchLog())
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
