import Foundation

/// A file holding KongSeek's settings and text snippets, for moving them to another
/// Mac or keeping a copy (adapted from KongFetch 4.7). Clipboard history, recently
/// opened items and the indexes are never included.
///
/// Paths under the home folder are stored as "~/…" and expanded again on import,
/// so folder settings carry over to a Mac with a different user name.
public struct SettingsArchive {
    public static let fileExtension = "kssettings"
    static let format = "KongSeek settings"

    /// Choices worth carrying over. Facts about this Mac (first launch, permission
    /// prompts already shown) and personal history (open counts) are left out.
    public static let transferableKeys: Set<String> = [
        "roots", "includeHidden", "matchFolderPath", "archiveSearch",
        "searchShortcut", "searchShortcutCleared", "doubleTapModifier",
        "ocrEnabled", "ocrFolders", "ocrPageLimit", "ocrOnlyOnPower", "ocrDownloadFromICloud",
        "clipboardEnabled", "clipboardShortcut", "clipboardShortcutCleared", "clipboardRetentionDays",
        "clipboardMaximumItems", "autoPaste", "clipboardOCR", "clipboardExcludedApps", "cleanupOperations",
        "quickLinks", "lookupShortcut", "lookupShortcutCleared", "snippetExpansion", "autoCheckUpdates",
    ]

    public var defaults: [String: Any]
    public var snippets: [TextSnippet]
    public var created: Date
    public var appVersion: String

    /// `defaults` as read from this Mac; `home` is abbreviated to "~".
    public init(defaults: [String: Any], snippets: [TextSnippet], created: Date = Date(), appVersion: String, home: String) {
        self.init(stored: Self.portable(defaults.filter { Self.transferableKeys.contains($0.key) }, home: home),
                  snippets: snippets, created: created, appVersion: appVersion)
    }

    private init(stored: [String: Any], snippets: [TextSnippet], created: Date, appVersion: String) {
        defaults = stored
        self.snippets = snippets
        self.created = created
        self.appVersion = appVersion
    }

    /// The settings to write on this Mac, with "~" expanded to `home`.
    public func restoredDefaults(home: String) -> [String: Any] {
        defaults.mapValues { Self.mapPaths($0) { $0 == "~" ? home : ($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) } }
    }

    static func portable(_ values: [String: Any], home: String) -> [String: Any] {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return values.mapValues { Self.mapPaths($0) { $0 == base ? "~" : ($0.hasPrefix(base + "/") ? "~" + $0.dropFirst(base.count) : $0) } }
    }

    /// Applies `transform` to strings and arrays of strings; other values pass unchanged.
    private static func mapPaths(_ value: Any, _ transform: (String) -> String) -> Any {
        if let text = value as? String { return transform(text) }
        if let list = value as? [String] { return list.map(transform) }
        return value
    }

    public enum ArchiveError: LocalizedError {
        case unreadable
        case notKongSeek

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取这个文件。"
            case .notKongSeek: return "这不是 KongSeek 导出的设置文件。"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plist: [String: Any] = [
            "format": Self.format,
            "version": 1,
            "appVersion": appVersion,
            "created": created,
            "defaults": defaults,
            "snippets": try encoder.encode(snippets),
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func decode(_ data: Data) throws -> SettingsArchive {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ArchiveError.unreadable
        }
        guard plist["format"] as? String == format, let defaults = plist["defaults"] as? [String: Any] else {
            throw ArchiveError.notKongSeek
        }
        var snippets: [TextSnippet] = []
        if let data = plist["snippets"] as? Data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snippets = (try? decoder.decode([TextSnippet].self, from: data)) ?? []
        }
        return SettingsArchive(stored: defaults.filter { transferableKeys.contains($0.key) }, snippets: snippets,
                               created: plist["created"] as? Date ?? Date(), appVersion: plist["appVersion"] as? String ?? "?")
    }
}

/// Version numbers ("0.9.0") compared part by part, and the sections of
/// CHANGELOG.md newer than a given version, for the update notes.
public enum ReleaseNotes {
    /// True when `a` is a later version than `b` ("0.10.0" > "0.9.1").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public struct Section: Equatable {
        public var version: String
        public var body: String
    }

    /// "## 0.9.0 — 2026-10-27" sections whose version is newer than `installed`, newest first.
    public static func sections(in changelog: String, newerThan installed: String) -> [Section] {
        var result: [Section] = []
        var current: (version: String, lines: [String])?
        func finish() {
            if let current, isNewer(current.version, than: installed) {
                result.append(Section(version: current.version, body: current.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in changelog.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                finish()
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let version = String(title.prefix { $0.isNumber || $0 == "." })
                current = version.isEmpty ? nil : (version, [])
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        finish()
        return result
    }

    /// The version in an Info.plist's CFBundleShortVersionString.
    public static func version(inInfoPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }
}
