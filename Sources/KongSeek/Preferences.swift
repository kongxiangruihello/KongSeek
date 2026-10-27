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

    /// Check GitHub for a newer version after launch and every six hours.
    static var autoCheckUpdates: Bool {
        get { defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCheckUpdates") }
    }

    /// List the files inside .zip archives in the index, so a search finds them too.
    static var archiveSearch: Bool {
        get { defaults.object(forKey: "archiveSearch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "archiveSearch") }
    }

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

    // MARK: - Text recognition (OCR)

    static var ocrEnabled: Bool {
        get { defaults.object(forKey: "ocrEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ocrEnabled") }
    }

    /// Folders whose scanned PDFs and images are recognized. Empty by default:
    /// recognition is slow, so the user picks where it is worth it.
    static var ocrFolders: [String] {
        get { defaults.stringArray(forKey: "ocrFolders") ?? [] }
        set { defaults.set(newValue, forKey: "ocrFolders") }
    }

    static var ocrPageLimit: Int {
        get { (defaults.object(forKey: "ocrPageLimit") as? Int) ?? 200 }
        set { defaults.set(newValue, forKey: "ocrPageLimit") }
    }

    static var ocrOnlyOnPower: Bool {
        get { defaults.object(forKey: "ocrOnlyOnPower") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ocrOnlyOnPower") }
    }

    static var ocrDownloadFromICloud: Bool {
        get { defaults.bool(forKey: "ocrDownloadFromICloud") }
        set { defaults.set(newValue, forKey: "ocrDownloadFromICloud") }
    }

    static var ocrSettings: OCRService.Settings {
        OCRService.Settings(enabled: ocrEnabled, folders: ocrFolders, pageLimit: ocrPageLimit, onlyOnPower: ocrOnlyOnPower, downloadFromICloud: ocrDownloadFromICloud)
    }

    // MARK: - Clipboard history

    /// Off until the user turns it on (as in KongFetch 3.2): copies can be private.
    static var clipboardEnabled: Bool {
        get { defaults.bool(forKey: "clipboardEnabled") }
        set { defaults.set(newValue, forKey: "clipboardEnabled") }
    }

    static var clipboardPaused: Bool {
        get { defaults.bool(forKey: "clipboardPaused") }
        set { defaults.set(newValue, forKey: "clipboardPaused") }
    }

    static var clipboardShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "clipboardShortcutCleared") { return nil }
            guard let data = defaults.data(forKey: "clipboardShortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultClipboard }
            return shortcut
        }
        set {
            defaults.set(newValue == nil, forKey: "clipboardShortcutCleared")
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "clipboardShortcut")
            } else {
                defaults.removeObject(forKey: "clipboardShortcut")
            }
        }
    }

    /// Unpinned entries unused for this many days are removed; 0 keeps them.
    static var clipboardRetentionDays: Int {
        get { (defaults.object(forKey: "clipboardRetentionDays") as? Int) ?? 30 }
        set { defaults.set(newValue, forKey: "clipboardRetentionDays") }
    }

    static var clipboardMaximumItems: Int {
        get { (defaults.object(forKey: "clipboardMaximumItems") as? Int) ?? 300 }
        set { defaults.set(newValue, forKey: "clipboardMaximumItems") }
    }

    static var clipboardLimits: ClipboardHistory.Limits {
        ClipboardHistory.Limits(maximumItems: max(20, min(clipboardMaximumItems, 2000)),
                                retentionDays: clipboardRetentionDays > 0 ? clipboardRetentionDays : nil)
    }

    /// Paste into the app in front after choosing an entry (needs Accessibility).
    static var autoPaste: Bool {
        get { defaults.object(forKey: "autoPaste") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPaste") }
    }

    /// Recognize text in copied pictures, so they can be searched and pasted as text.
    static var clipboardOCR: Bool {
        get { defaults.object(forKey: "clipboardOCR") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardOCR") }
    }

    /// Password managers: never recorded, and snippets never expand there.
    static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.dashlane.Dashlane", "com.apple.Passwords", "com.apple.keychainaccess", "org.keepassxc.keepassxc",
    ]

    /// Bundle identifiers whose copies are never recorded.
    static var clipboardExcludedApps: [String] {
        get { defaults.stringArray(forKey: "clipboardExcludedApps") ?? defaultExcludedApps }
        set { defaults.set(newValue, forKey: "clipboardExcludedApps") }
    }

    /// What ⌘J does to text before pasting.
    static var cleanupOperations: [TextCleanup.Operation] {
        get {
            guard let raw = defaults.stringArray(forKey: "cleanupOperations") else { return [.joinLines, .chinesePunctuation, .spaces] }
            return raw.compactMap(TextCleanup.Operation.init(rawValue:))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "cleanupOperations") }
    }

    // MARK: - Web search, lookup, snippets

    /// Keywords for web searches typed in the search window ("hd 仁").
    static var quickLinks: [QuickLink] {
        get {
            guard let data = defaults.data(forKey: "quickLinks"),
                  let links = try? JSONDecoder().decode([QuickLink].self, from: data) else { return QuickLinks.defaults }
            return links
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "quickLinks") }
        }
    }

    static func resetQuickLinks() {
        defaults.removeObject(forKey: "quickLinks")
    }

    /// Look up the selected text in the system dictionary.
    static var lookupShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "lookupShortcutCleared") { return nil }
            guard let data = defaults.data(forKey: "lookupShortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultLookup }
            return shortcut
        }
        set {
            defaults.set(newValue == nil, forKey: "lookupShortcutCleared")
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "lookupShortcut")
            } else {
                defaults.removeObject(forKey: "lookupShortcut")
            }
        }
    }

    /// Replace a typed snippet keyword with the snippet (needs Input Monitoring and Accessibility).
    static var snippetExpansion: Bool {
        get { defaults.object(forKey: "snippetExpansion") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "snippetExpansion") }
    }
}
