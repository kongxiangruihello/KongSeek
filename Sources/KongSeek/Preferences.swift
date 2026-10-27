import Foundation
import KongSeekCore

/// Settings kept in UserDefaults.
enum Preferences {
    private static let defaults = UserDefaults.standard

    /// Home folder, iCloud Drive (inside ~/Library, which is otherwise skipped) and applications.
    static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        var roots = [home]
        let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: cloud) { roots.append(cloud) }
        roots += ["/Applications", "/System/Applications"]
        return roots
    }

    static var roots: [String] {
        get { defaults.stringArray(forKey: "roots") ?? defaultRoots }
        set { defaults.set(newValue, forKey: "roots") }
    }

    static func resetRoots() {
        defaults.removeObject(forKey: "roots")
    }

    static var includeHidden: Bool {
        get { defaults.bool(forKey: "includeHidden") }
        set { defaults.set(newValue, forKey: "includeHidden") }
    }

    /// Let a word also match the folder a file is in (3.2 "名称及路径").
    static var matchFolderPath: Bool {
        get { defaults.bool(forKey: "matchFolderPath") }
        set { defaults.set(newValue, forKey: "matchFolderPath") }
    }

    static var precision: MatchPrecision { matchFolderPath ? .withPath : .fuzzyName }

    static var rules: ExclusionRules {
        var rules = ExclusionRules.standard()
        rules.includeHidden = includeHidden
        return rules
    }

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    /// How often each path was opened from KongSeek; breaks ties between equal scores.
    static var openCounts: [String: Int] {
        defaults.dictionary(forKey: "openCounts") as? [String: Int] ?? [:]
    }

    static func recordOpen(_ path: String) {
        var counts = openCounts
        counts[path, default: 0] += 1
        if counts.count > 3000 {
            // Keep the most used entries.
            counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(2000).map { ($0.key, $0.value) })
        }
        defaults.set(counts, forKey: "openCounts")
    }
}
