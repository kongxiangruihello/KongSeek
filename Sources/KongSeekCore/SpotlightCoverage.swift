import Foundation

/// 全文搜不到的原因 (0.28): full-text search asks Spotlight, which reads only the folders
/// it indexes. A sample of documents from each indexed folder is checked: if Spotlight
/// knows none of them, the folder is outside its index (excluded in 系统设置 › Spotlight,
/// or on a disk with indexing turned off).
public enum SpotlightCoverage {
    public static let documentExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "txt", "md", "pages", "pptx", "key", "epub"]

    /// Up to `perRoot` local documents from each root, spread over the root's files.
    public static func samples(roots: [String], files: [(path: String, isLocal: Bool)], perRoot: Int = 12) -> [String: [String]] {
        var byRoot: [String: [String]] = [:]
        for root in roots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let documents = files.filter { $0.isLocal && $0.path.hasPrefix(prefix)
                && documentExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }.map(\.path).sorted()
            guard !documents.isEmpty else { continue }
            let step = max(1, documents.count / perRoot)
            byRoot[root] = Array(stride(from: 0, to: documents.count, by: step).map { documents[$0] }.prefix(perRoot))
        }
        return byRoot
    }

    /// `mdls -raw -name kMDItemFSName file…` prints each value followed by a NUL, and
    /// "(null)" for a file Spotlight does not know.
    public static func indexed(mdlsOutput: String, count: Int) -> [Bool] {
        var values = mdlsOutput.components(separatedBy: "\u{0}")
        if values.last == "" { values.removeLast() }
        guard values.count == count else { return Array(repeating: true, count: count) }
        return values.map { $0 != "(null)" && !$0.isEmpty }
    }

    public enum Verdict: Equatable, Sendable {
        case indexed
        /// Some known, some not: probably files added in the last few minutes.
        case partly(known: Int, of: Int)
        case notIndexed
    }

    public static func verdict(_ flags: [Bool]) -> Verdict {
        let known = flags.filter { $0 }.count
        if known == flags.count { return .indexed }
        if known == 0 { return .notIndexed }
        // A few new files Spotlight has not reached yet are normal.
        return Double(known) / Double(flags.count) >= 0.75 ? .indexed : .partly(known: known, of: flags.count)
    }

    /// "Indexing enabled." / "Indexing disabled." from `mdutil -s <volume>`.
    public static func indexingEnabled(mdutilOutput: String) -> Bool? {
        if mdutilOutput.contains("Indexing enabled") { return true }
        if mdutilOutput.contains("Indexing disabled") || mdutilOutput.contains("Indexing and searching disabled") { return false }
        return nil
    }
}
