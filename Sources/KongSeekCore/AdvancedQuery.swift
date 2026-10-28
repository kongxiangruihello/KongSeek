import Foundation

/// Everything-style operators added in 0.10 (on top of 3.2's syntax):
///
///     path:讲义        the text appears anywhere in the full path (-path: excludes)
///     in:~/Documents   anywhere below a folder; in:论语 below any folder named 论语 (-in: excludes)
///     parent:~/Desktop directly inside a folder; parent:论语 directly inside a folder named 论语
///     size:>10mb  size:<=500kb  size:1mb..20mb  size:empty  size:large
///     dm:today  dm:thisweek  dm:7d  dm:2024  dm:2024-10  dm:>=2024-10-01  dm:2024-01..2024-03
///     dc:7d            created (a downloaded file: downloaded) in that range, same values as dm: (0.17)
///     regex:^第.+讲   the name (or, when the pattern has "/", the path) matches (-regex: excludes)
///     file:  folder:   only files / only folders
///     dupe:            only files whose name occurs more than once among the results
///     打开过:7d  opened:7d  opened from KongSeek in that range (same values as dm:);
///                      打开过: alone = ever (0.35, after Everything's daterun:)
///     near:30  相距:30  full text: the words within 30 characters of each other (0.36)
///     同页:  samepage:  full text: the words on one page (0.36)
///
/// Operators combine with AND. Values with spaces go in quotes: in:"~/My Folder".
public struct AdvancedFilters: Sendable {
    public var pathTerms: [String] = []
    public var excludedPathTerms: [String] = []
    public var scopes: [ScopeFilter] = []
    public var regexes: [CompiledRegex] = []
    public var excludedRegexes: [CompiledRegex] = []
    public var kind: KindOnly = .any
    public var dupe = false
    public var attributes = AttributeFilters()
    /// 打开过: (0.35): only items opened from KongSeek, when given since `openedFrom`
    /// and before `openedBefore`. Applied by the app, which keeps the open history.
    public var opened = false
    public var openedFrom: Date?
    public var openedBefore: Date?
    /// near: / 同页: (0.36): how close the words of a full-text search must stand.
    public var near: Int?
    public var samePage = false

    /// Whether full-text results must be checked for how close the words stand.
    public var needsProximity: Bool { near != nil || samePage }
    /// Shown under the results ("在 ~/Documents 中", "大小 ≥ 10 MB").
    public var descriptions: [String] = []
    /// Problems with operator values; any makes the query invalid.
    public var errors: [String] = []

    public init() {}

    public var isEmpty: Bool {
        pathTerms.isEmpty && excludedPathTerms.isEmpty && scopes.isEmpty && regexes.isEmpty && excludedRegexes.isEmpty
            && kind == .any && !dupe && !attributes.isActive && !opened && !needsProximity
    }

    /// Whether an item last opened at `date` passes 打开过:.
    public func acceptsOpened(at date: Date?) -> Bool {
        guard opened else { return true }
        guard let date else { return false }
        if let openedFrom, date < openedFrom { return false }
        if let openedBefore, date >= openedBefore { return false }
        return true
    }

    /// Operator names the lexer recognizes (besides ext:, which 3.2 already had).
    static let operatorNames = ["path", "in", "infolder", "parent", "size", "dm", "datemodified", "dc", "datecreated", "regex", "dupe", "file", "folder", "opened", "打开过", "near", "相距", "samepage", "同页"]

    /// Applies one operator token. Returns a value to treat as an ordinary word
    /// (file:合同 = files whose name matches 合同), if any.
    mutating func apply(operator name: String, value rawValue: String, excluded: Bool, now: Date, calendar: Calendar) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        func needValue() -> Bool {
            if value.isEmpty { errors.append("\(name): 后面需要写内容"); return false }
            return true
        }
        func noExclusion() -> Bool {
            if excluded { errors.append("-\(name): 不支持排除"); return false }
            return true
        }
        switch name {
        case "path":
            guard needValue() else { return nil }
            let folded = SearchText.fold(value)
            if excluded {
                excludedPathTerms.append(folded)
                descriptions.append("路径不含：\(value)")
            } else {
                pathTerms.append(folded)
                descriptions.append("路径含：\(value)")
            }
        case "in", "infolder", "parent":
            guard needValue() else { return nil }
            let recursive = name != "parent"
            let scope = ScopeFilter(value, recursive: recursive, excluded: excluded)
            scopes.append(scope)
            let shown = scope.displayName
            descriptions.append(excluded ? "不在“\(shown)”中" : (recursive ? "在“\(shown)”中" : "直接在“\(shown)”中"))
        case "size":
            guard needValue(), noExclusion() else { return nil }
            guard let range = Self.sizeRange(value) else {
                errors.append("无法识别 size:\(value)（例：size:>10mb、size:1mb..20mb、size:empty）")
                return nil
            }
            if let minimum = range.minimum { attributes.minimumSize = max(attributes.minimumSize ?? minimum, minimum) }
            if let maximum = range.maximum { attributes.maximumSize = min(attributes.maximumSize ?? maximum, maximum) }
            descriptions.append("大小：\(value)")
        case "dm", "datemodified":
            guard needValue(), noExclusion() else { return nil }
            guard let range = Self.dateRange(value, now: now, calendar: calendar) else {
                errors.append("无法识别 dm:\(value)（例：dm:today、dm:7d、dm:2024-10、dm:>=2024-01-01）")
                return nil
            }
            if let start = range.start { attributes.modifiedFrom = max(attributes.modifiedFrom ?? start, start) }
            if let end = range.end { attributes.modifiedBefore = min(attributes.modifiedBefore ?? end, end) }
            descriptions.append("修改时间：\(value)")
        case "dc", "datecreated":
            guard needValue(), noExclusion() else { return nil }
            guard let range = Self.dateRange(value, now: now, calendar: calendar) else {
                errors.append("无法识别 dc:\(value)（例：dc:today、dc:7d、dc:2024-10、dc:>=2024-01-01）")
                return nil
            }
            if let start = range.start { attributes.createdFrom = max(attributes.createdFrom ?? start, start) }
            if let end = range.end { attributes.createdBefore = min(attributes.createdBefore ?? end, end) }
            descriptions.append("创建（下载）时间：\(value)")
        case "regex":
            guard needValue() else { return nil }
            guard let regex = CompiledRegex(value) else {
                errors.append("正则表达式有误：\(value)")
                return nil
            }
            if excluded { excludedRegexes.append(regex) } else { regexes.append(regex) }
            descriptions.append((excluded ? "不匹配正则：" : "正则：") + value)
        case "file", "folder":
            guard noExclusion() else { return nil }
            let wanted: KindOnly = name == "file" ? .files : .folders
            if kind != .any && kind != wanted {
                errors.append("file: 与 folder: 不能同时使用")
                return nil
            }
            if kind == .any { descriptions.append(name == "file" ? "只看文件" : "只看文件夹") }
            kind = wanted
            return value.isEmpty ? nil : value
        case "opened", "打开过":
            guard noExclusion() else { return nil }
            opened = true
            if value.isEmpty {
                descriptions.append("打开过的")
                return nil
            }
            guard let range = Self.dateRange(value, now: now, calendar: calendar) else {
                errors.append("无法识别 打开过:\(value)（例：打开过:7d、打开过:thisweek、打开过:2024-10）")
                return nil
            }
            if let start = range.start { openedFrom = max(openedFrom ?? start, start) }
            if let end = range.end { openedBefore = min(openedBefore ?? end, end) }
            descriptions.append("打开过：\(value)")
        case "near", "相距":
            guard needValue(), noExclusion() else { return nil }
            let digits = value.filter(\.isNumber)
            guard let number = Int(digits), (1...2_000).contains(number), digits.count == value.filter({ !"字个chars".contains($0) }).count else {
                errors.append("无法识别 \(name):\(value)（例：near:30，即相距 30 字以内）")
                return nil
            }
            near = min(near ?? number, number)
            descriptions.append("相距 \(number) 字以内（全文搜索）")
        case "samepage", "同页":
            guard noExclusion() else { return nil }
            if !samePage { descriptions.append("在同一页（全文搜索）") }
            samePage = true
            return value.isEmpty ? nil : value
        case "dupe":
            guard noExclusion() else { return nil }
            if !dupe { descriptions.append("同名文件") }
            dupe = true
            return value.isEmpty ? nil : value
        default:
            break
        }
        return nil
    }

    // MARK: Paths outside the index

    /// The path-based operators (path:, in:, parent:, regex:, file:/folder:) for a
    /// result that did not come from the index (full text, archives).
    public func acceptsPath(_ path: String, isFolder: Bool) -> Bool {
        if kind == .files && isFolder { return false }
        if kind == .folders && !isFolder { return false }
        if !pathTerms.isEmpty || !excludedPathTerms.isEmpty {
            let folded = SearchText.fold(path)
            if !pathTerms.allSatisfy({ folded.contains($0) }) { return false }
            if excludedPathTerms.contains(where: { folded.contains($0) }) { return false }
        }
        for scope in scopes where scope.contains(path) == scope.excluded { return false }
        let name = (path as NSString).lastPathComponent
        for regex in regexes where !regex.matches(name: name, path: path) { return false }
        for regex in excludedRegexes where regex.matches(name: name, path: path) { return false }
        return true
    }

    // MARK: Values

    /// Inclusive byte bounds for a size: value. Sizes use 1000 (as Finder shows them).
    public static func sizeRange(_ text: String) -> (minimum: Int64?, maximum: Int64?)? {
        let value = text.lowercased().replacingOccurrences(of: " ", with: "")
        let named: [String: (Int64?, Int64?)] = [
            "empty": (nil, 0), "空": (nil, 0),
            "tiny": (0, 10_000), "small": (10_001, 100_000), "medium": (100_001, 1_000_000),
            "large": (1_000_001, 16_000_000), "huge": (16_000_001, 128_000_000), "gigantic": (128_000_001, nil),
        ]
        if let range = named[value] { return range }
        if let dots = value.range(of: "..") {
            guard let low = bytes(String(value[..<dots.lowerBound])), let high = bytes(String(value[dots.upperBound...])), low <= high else { return nil }
            return (low, high)
        }
        for (op, kind) in [(">=", 0), ("<=", 1), (">", 2), ("<", 3), ("=", 4)] where value.hasPrefix(op) {
            guard let amount = bytes(String(value.dropFirst(op.count))) else { return nil }
            switch kind {
            case 0: return (amount, nil)
            case 1: return (nil, amount)
            case 2: return (amount + 1, nil)
            case 3: return (nil, max(0, amount - 1))
            default: return (amount, amount)
            }
        }
        guard let amount = bytes(value) else { return nil }
        return (amount, nil)
    }

    static func bytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
        var number = text
        var multiplier = 1.0
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            number = String(text.dropLast(suffix.count))
            multiplier = factor
            break
        }
        guard !number.isEmpty, let amount = Double(number), amount.isFinite, amount >= 0, amount * multiplier < 1e15 else { return nil }
        return Int64((amount * multiplier).rounded())
    }

    /// [start, end) for a dm: value, resolved against `now`.
    public static func dateRange(_ text: String, now: Date, calendar: Calendar) -> (start: Date?, end: Date?)? {
        let value = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let dots = value.range(of: "..") {
            guard let low = interval(String(value[..<dots.lowerBound]), now: now, calendar: calendar),
                  let high = interval(String(value[dots.upperBound...]), now: now, calendar: calendar),
                  low.start < high.end else { return nil }
            return (low.start, high.end)
        }
        for (op, kind) in [(">=", 0), ("<=", 1), (">", 2), ("<", 3)] where value.hasPrefix(op) {
            guard let span = interval(String(value.dropFirst(op.count)), now: now, calendar: calendar) else { return nil }
            switch kind {
            case 0: return (span.start, nil)
            case 1: return (nil, span.end)
            case 2: return (span.end, nil)
            default: return (nil, span.start)
            }
        }
        guard let span = interval(value, now: now, calendar: calendar) else { return nil }
        return (span.start, span.end)
    }

    /// The period a date word names: today, thisweek, 7d (the last 7 days up to
    /// now), 2024, 2024-10, 2024-10-27 (also with / or .).
    static func interval(_ value: String, now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        func period(_ unit: Calendar.Component, offset: Int) -> (Date, Date)? {
            guard let shifted = calendar.date(byAdding: unit, value: offset, to: now),
                  let span = calendar.dateInterval(of: unit, for: shifted) else { return nil }
            return (span.start, span.end)
        }
        let names: [String: (Calendar.Component, Int)] = [
            "today": (.day, 0), "今天": (.day, 0), "yesterday": (.day, -1), "昨天": (.day, -1),
            "thisweek": (.weekOfYear, 0), "本周": (.weekOfYear, 0), "lastweek": (.weekOfYear, -1), "上周": (.weekOfYear, -1),
            "thismonth": (.month, 0), "本月": (.month, 0), "lastmonth": (.month, -1), "上月": (.month, -1),
            "thisyear": (.year, 0), "今年": (.year, 0), "lastyear": (.year, -1), "去年": (.year, -1),
        ]
        if let named = names[value] { return period(named.0, offset: named.1) }
        // 7d, 2w, 3m, 1y: from that long ago until now (and the rest of today).
        if let unitChar = value.last, let count = Int(value.dropLast()), count > 0, count <= 100_000 {
            let units: [Character: Calendar.Component] = ["d": .day, "天": .day, "w": .weekOfYear, "周": .weekOfYear, "m": .month, "y": .year, "年": .year]
            if let unit = units[unitChar], let start = calendar.date(byAdding: unit, value: -count, to: now),
               let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
                return (start, end)
            }
        }
        let parts = value.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), parts[0].count == 4 else { return nil }
        var components = DateComponents(year: year, month: 1, day: 1)
        let unit: Calendar.Component
        switch parts.count {
        case 1: unit = .year
        case 2:
            guard let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            components.month = month
            unit = .month
        default:
            guard let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]), (1...31).contains(day) else { return nil }
            components.month = month
            components.day = day
            unit = .day
        }
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == components.day,
              let span = calendar.dateInterval(of: unit, for: date) else { return nil }
        return (span.start, span.end)
    }
}

public enum KindOnly: Sendable, Equatable {
    case any, files, folders
}

/// in: / parent: — a folder given by path (~/Documents, /Volumes/盘) or by name (论语).
public struct ScopeFilter: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Canonical absolute path.
        case path(String)
        /// Folded folder name.
        case folderName(String)
    }

    public let target: Target
    /// in: (anywhere below) rather than parent: (directly inside).
    public let recursive: Bool
    public let excluded: Bool
    let typed: String

    public init(_ value: String, recursive: Bool, excluded: Bool) {
        typed = value
        if value.hasPrefix("/") || value.hasPrefix("~") {
            target = .path(Paths.canonical((value as NSString).expandingTildeInPath))
        } else {
            target = .folderName(SearchText.fold(value))
        }
        self.recursive = recursive
        self.excluded = excluded
    }

    var displayName: String { typed }

    /// Whether `path` is inside the scope (the folder itself is not).
    public func contains(_ path: String) -> Bool {
        let parent = Paths.parent(path)
        switch target {
        case .path(let folder):
            return recursive ? path != folder && Paths.isWithin(path, folder) : parent == folder
        case .folderName(let name):
            if !recursive { return SearchText.fold((parent as NSString).lastPathComponent) == name }
            return parent.split(separator: "/").contains { SearchText.fold(String($0)) == name }
        }
    }
}

/// A case-insensitive regular expression, safe to share between threads
/// (NSRegularExpression is immutable).
public final class CompiledRegex: @unchecked Sendable {
    public let source: String
    let regex: NSRegularExpression
    /// Patterns with "/" are matched against the whole path, others against the name.
    public let matchesPath: Bool

    public init?(_ source: String) {
        guard let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) else { return nil }
        self.source = source
        self.regex = regex
        matchesPath = source.contains("/")
    }

    public func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public func matches(name: String, path: @autoclosure () -> String) -> Bool {
        matches(matchesPath ? path() : name)
    }
}

/// size:, dm: and dc: bounds.
public struct AttributeFilters: Sendable, Equatable {
    /// Inclusive byte bounds; a size filter excludes folders.
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    /// Modified at or after `modifiedFrom` and before `modifiedBefore`.
    public var modifiedFrom: Date?
    public var modifiedBefore: Date?
    /// Created at or after `createdFrom` and before `createdBefore` (dc:).
    public var createdFrom: Date?
    public var createdBefore: Date?

    public init() {}

    public var isActive: Bool { hasSize || hasDate || hasCreated }
    var hasSize: Bool { minimumSize != nil || maximumSize != nil }
    var hasDate: Bool { modifiedFrom != nil || modifiedBefore != nil }
    var hasCreated: Bool { createdFrom != nil || createdBefore != nil }

    public func accepts(isDirectory: Bool, size: Int64, modified: Date?, created: Date? = nil) -> Bool {
        if hasSize {
            if isDirectory { return false }
            if let minimumSize, size < minimumSize { return false }
            if let maximumSize, size > maximumSize { return false }
        }
        if hasDate {
            guard let modified else { return false }
            if let modifiedFrom, modified < modifiedFrom { return false }
            if let modifiedBefore, modified >= modifiedBefore { return false }
        }
        if hasCreated {
            guard let created else { return false }
            if let createdFrom, created < createdFrom { return false }
            if let createdBefore, created >= createdBefore { return false }
        }
        return true
    }

    public func accepts(_ metadata: EntryMetadata) -> Bool {
        accepts(isDirectory: metadata.isDirectory, size: metadata.size, modified: metadata.modified, created: metadata.created)
    }
}
