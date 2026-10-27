import Foundation

/// "扫描版一键识别": PDFs without a text layer, grouped by folder, and the OCR folder
/// list after adding some of those folders (0.16).
public enum ScannedPDFs {
    public struct File: Equatable, Sendable {
        public var path: String
        public var pages: Int
        public var size: Int64

        public init(path: String, pages: Int, size: Int64) {
            self.path = path
            self.pages = pages
            self.size = size
        }
    }

    public struct Folder: Equatable, Sendable, Identifiable {
        public var path: String
        public var files: [File]
        public var id: String { path }
        public var pages: Int { files.reduce(0) { $0 + $1.pages } }
    }

    /// Files grouped by the folder they are in, the folders with the most pages first.
    public static func folders(_ files: [File]) -> [Folder] {
        var byFolder: [String: [File]] = [:]
        for file in files { byFolder[(file.path as NSString).deletingLastPathComponent, default: []].append(file) }
        return byFolder.map { Folder(path: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.pages != $1.pages ? $0.pages > $1.pages : $0.path < $1.path }
    }

    /// Whether `path` is `folder` or inside it.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }

    /// True when the file is in one of the OCR folders (it will be, or was, recognized there).
    public static func isCovered(_ path: String, by folders: [String]) -> Bool {
        folders.contains { isWithin(path, $0) }
    }

    /// The OCR folder list with `added` folders: folders already covered by one in the
    /// list are skipped, and listed folders inside a newly added one are dropped.
    public static func adding(_ added: [String], to existing: [String]) -> [String] {
        var result = existing
        for folder in added.sorted(by: { $0.count < $1.count }) where !result.contains(where: { isWithin(folder, $0) }) {
            result.removeAll { isWithin($0, folder) }
            result.append(folder)
        }
        return result
    }

    /// Rough time for recognizing `pages` pages, each file capped at `pageLimit` pages.
    /// Apple Vision's accurate mode takes about 1–2 s a page on a recent Mac.
    public static func estimatedSeconds(_ files: [File], pageLimit: Int, secondsPerPage: Double = 1.5) -> Double {
        Double(files.reduce(0) { $0 + min(max(1, $1.pages), pageLimit) }) * secondsPerPage
    }

    /// "约 3 小时 20 分钟" / "约 12 分钟" / "不到 1 分钟".
    public static func describe(seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "不到 1 分钟" }
        if minutes < 60 { return "约 \(minutes) 分钟" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "约 \(hours) 小时" : "约 \(hours) 小时 \(rest) 分钟"
    }

    /// A page counts as text when it holds at least this many non-space characters
    /// (a scan often carries a stray page number in its text layer).
    public static let minimumCharacters = 20

    /// Whether the sampled pages have a real text layer: at least 40% of them hold
    /// text, or (slides with short titles) 80% hold a few characters. The same line
    /// on every page is a watermark, not text, and a scanned book with one typed
    /// cover still counts as scanned.
    public static func hasText(_ pageTexts: [String]) -> Bool {
        guard !pageTexts.isEmpty else { return false }
        let normalized = pageTexts.map { text in text.filter { !$0.isWhitespace } }
        var seen: [String: Int] = [:]
        for text in normalized { seen[text, default: 0] += 1 }
        let unique = normalized.filter { pageTexts.count == 1 || seen[$0] == 1 }
        let full = unique.filter { $0.count >= minimumCharacters }.count
        let some = unique.filter { $0.count >= 4 }.count
        let count = Double(pageTexts.count)
        return (full > 0 && Double(full) >= count * 0.4) || (some > 0 && Double(some) >= count * 0.8)
    }

    /// Which pages (0-based) to look at in a document of `count` pages: the first
    /// eight plus a few spread through the rest.
    public static func samplePages(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var pages = Array(0..<min(count, 8))
        if count > 8 {
            for fraction in [0.25, 0.5, 0.75] { pages.append(min(count - 1, Int(Double(count) * fraction))) }
        }
        return Array(Set(pages)).sorted()
    }
}
