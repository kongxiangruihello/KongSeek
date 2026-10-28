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

    /// Proxy for update downloads, e.g. "127.0.0.1:7890"; empty means the system proxy (or none).
    static var updateProxy: String {
        get { defaults.string(forKey: "updateProxy") ?? "" }
        set { defaults.set(newValue, forKey: "updateProxy") }
    }

    /// Recent searches that led to opening something (newest first); ↑ in an empty field shows them.
    static var searchHistory: [String] {
        get { defaults.stringArray(forKey: "searchHistory") ?? [] }
        set { defaults.set(Array(newValue.prefix(50)), forKey: "searchHistory") }
    }

    static var keepSearchHistory: Bool {
        get { defaults.object(forKey: "keepSearchHistory") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "keepSearchHistory")
            if !newValue { searchHistory = [] }
        }
    }

    /// Names given to saved searches (search → name), such as "《论语》导读" (0.19).
    static var savedSearchNames: [String: String] {
        get { defaults.dictionary(forKey: "savedSearchNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "savedSearchNames") }
    }

    /// 通假字、古今字 counted as the same in 逐字异文 (0.29), as "说=悦" lines; the
    /// common examples until the reader edits them.
    static var quoteEquivalentLines: [String] {
        get { defaults.stringArray(forKey: "quoteEquivalents") ?? CharacterEquivalents.standardLines }
        set { defaults.set(newValue, forKey: "quoteEquivalents") }
    }

    static var quoteEquivalents: CharacterEquivalents {
        CharacterEquivalents(lines: quoteEquivalentLines)
    }

    /// Documents in folders Spotlight does not index also go into KongSeek's text index (0.39).
    static var indexUncoveredFolders: Bool {
        get { defaults.object(forKey: "indexUncoveredFolders") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "indexUncoveredFolders") }
    }

    /// 输入时自动补全 (0.41); on unless turned off.
    static var autocomplete: Bool {
        get { defaults.object(forKey: "autocomplete") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autocomplete") }
    }

    /// How search results are ordered (0.38): 相关度 unless changed.
    static var resultOrder: ResultOrder {
        get { ResultOrder(rawValue: defaults.string(forKey: "resultOrder") ?? "") ?? .relevance }
        set { defaults.set(newValue.rawValue, forKey: "resultOrder") }
    }

    /// KongSeek's own text index of e-books Spotlight does not read (0.37); on unless turned off.
    static var bookTextIndex: Bool {
        get { defaults.object(forKey: "bookTextIndex") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "bookTextIndex") }
    }

    /// 合并内容相同的副本 in the results (0.36); on unless turned off.
    static var mergeCopies: Bool {
        get { defaults.object(forKey: "mergeCopies") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mergeCopies") }
    }

    /// 筛选按钮 under the search field (0.36): "PDF=ext:pdf" lines.
    static var filterButtonLines: [String] {
        get { defaults.stringArray(forKey: "filterButtons") ?? FilterFragments.standardLines }
        set { defaults.set(newValue, forKey: "filterButtons") }
    }

    static var showFilterButtons: Bool {
        get { defaults.object(forKey: "showFilterButtons") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFilterButtons") }
    }

    /// 同义词与别名 (0.35): "王守仁=王阳明=阳明" lines; the common names until edited.
    static var searchAliasLines: [String] {
        get { defaults.stringArray(forKey: "searchAliases") ?? SearchAliases.standardLines }
        set {
            defaults.set(newValue, forKey: "searchAliases")
            cachedAliases = nil
        }
    }

    private static var cachedAliases: (lines: [String], aliases: SearchAliases)?

    /// Parsed once per change of the lines (the pinyin of each name is worked out then).
    static var searchAliases: SearchAliases {
        let lines = searchAliasLines
        if let cachedAliases, cachedAliases.lines == lines { return cachedAliases.aliases }
        let aliases = SearchAliases(lines: lines)
        cachedAliases = (lines, aliases)
        return aliases
    }

    /// 常用本的批量规则 (0.34): keywords in the file name, then formats, earlier first.
    static var editionRules: EditionRules {
        get {
            EditionRules(keywords: defaults.stringArray(forKey: "editionKeywords") ?? EditionRules.standard.keywords,
                         formats: defaults.stringArray(forKey: "editionFormats") ?? EditionRules.standard.formats)
        }
        set {
            defaults.set(newValue.keywords, forKey: "editionKeywords")
            defaults.set(newValue.formats, forKey: "editionFormats")
        }
    }

    /// Where PDFs opened at a page go (0.25): KongFolio when installed, or KongSeek's reading window.
    enum PDFReader: String, CaseIterable {
        case automatic, kongFolio, builtIn

        var title: String {
            switch self {
            case .automatic: return "自动（装了 KongFolio 就用它）"
            case .kongFolio: return "KongFolio"
            case .builtIn: return "KongSeek 阅读窗口"
            }
        }
    }

    static var pdfReader: PDFReader {
        get { PDFReader(rawValue: defaults.string(forKey: "pdfReader") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "pdfReader") }
    }

    /// How references and quotations are written (0.19).
    static var citationStyle: Citation.Style {
        get { Citation.Style(rawValue: defaults.string(forKey: "citationStyle") ?? "") ?? .gbt7714 }
        set { defaults.set(newValue.rawValue, forKey: "citationStyle") }
    }

    /// Results grouped by the folder they are in (⌘G, 0.19).
    static var groupByFolder: Bool {
        get { defaults.bool(forKey: "groupByFolder") }
        set { defaults.set(newValue, forKey: "groupByFolder") }
    }

    /// Searches saved with ⌘S, shown when the search field is empty.
    static var savedSearches: [String] {
        get { defaults.stringArray(forKey: "savedSearches") ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: "savedSearches") }
    }

    /// Let Claude (ks mcp) search inside and read documents, not just names.
    static var mcpReadContent: Bool {
        get { defaults.object(forKey: "mcpReadContent") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mcpReadContent") }
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

    /// Recognize with the Live Text engine (reads vertical text; 0.22).
    static var ocrUseLiveText: Bool {
        get { defaults.bool(forKey: "ocrUseLiveText") }
        set { defaults.set(newValue, forKey: "ocrUseLiveText") }
    }

    static var ocrSettings: OCRService.Settings {
        OCRService.Settings(enabled: ocrEnabled, folders: ocrFolders, pageLimit: ocrPageLimit, onlyOnPower: ocrOnlyOnPower,
                            downloadFromICloud: ocrDownloadFromICloud, useLiveText: ocrUseLiveText)
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

    /// Checks the text selected in any app with 引文查证 (0.23).
    static var quoteShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "quoteShortcutCleared") { return nil }
            guard let data = defaults.data(forKey: "quoteShortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultQuote }
            return shortcut
        }
        set {
            defaults.set(newValue == nil, forKey: "quoteShortcutCleared")
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "quoteShortcut")
            } else {
                defaults.removeObject(forKey: "quoteShortcut")
            }
        }
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
