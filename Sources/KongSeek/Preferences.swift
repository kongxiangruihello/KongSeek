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

    /// The search shortcut; nil means none (double-tap only).
    static var searchShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "searchShortcutCleared") { return nil }
            guard let data = defaults.data(forKey: "searchShortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultSearch }
            return shortcut
        }
        set {
            defaults.set(newValue == nil, forKey: "searchShortcutCleared")
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "searchShortcut")
            } else {
                defaults.removeObject(forKey: "searchShortcut")
            }
        }
    }

    /// Modifier tapped twice to open the search window (Control by default, as in KongFetch).
    static var doubleTapModifier: TapModifier {
        get { TapModifier(rawValue: defaults.string(forKey: "doubleTapModifier") ?? "") ?? .control }
        set { defaults.set(newValue.rawValue, forKey: "doubleTapModifier") }
    }

    /// How often each path was opened from KongSeek; breaks ties between equal scores.
    static var openCounts: [String: Int] {
        defaults.dictionary(forKey: "openCounts") as? [String: Int] ?? [:]
    }

    /// When each path was last opened from KongSeek (seconds since 1970).
    static var lastOpened: [String: Double] {
        defaults.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
    }

    static func recordOpen(_ path: String) {
        var counts = openCounts
        counts[path, default: 0] += 1
        var times = lastOpened
        times[path] = Date().timeIntervalSince1970
        if counts.count > 3000 {
            // Keep the entries used most and most recently.
            let keep = Set(counts.sorted { $0.value > $1.value }.prefix(1500).map(\.key))
                .union(times.sorted { $0.value > $1.value }.prefix(500).map(\.key))
            counts = counts.filter { keep.contains($0.key) }
            times = times.filter { keep.contains($0.key) }
        }
        defaults.set(counts, forKey: "openCounts")
        defaults.set(times, forKey: "lastOpened")
    }

    static func forget(_ path: String) {
        var counts = openCounts
        var times = lastOpened
        counts[path] = nil
        times[path] = nil
        defaults.set(counts, forKey: "openCounts")
        defaults.set(times, forKey: "lastOpened")
    }
}
