import Foundation

/// Builds Spotlight query strings for full-text search from the same search-box
/// syntax as name search. Spotlight's own content index does the matching.
public enum SpotlightQuery {
    /// Query matching files whose text (or display name) contains every word and
    /// phrase, with ext:, type, date, size and tag filters. Nil without words.
    /// Excluded words (-草稿) are not expressible here; filter names afterwards.
    public static func content(for query: SearchQuery) -> String? {
        guard query.valid else { return nil }
        let terms = query.words + query.phrases
        guard !terms.isEmpty else { return nil }
        var parts: [String] = []
        // Chinese words are looked for in simplified and traditional form (繁简通搜).
        for word in query.words {
            // Word-prefix match in the text, as Finder's "contents" search does.
            let alternatives = SearchText.scriptVariants(word).map(escape).map {
                "kMDItemTextContent == \"\($0)*\"cdw || kMDItemDisplayName == \"*\($0)*\"cd"
            }
            parts.append("(" + alternatives.joined(separator: " || ") + ")")
        }
        for phrase in query.phrases {
            let alternatives = SearchText.scriptVariants(phrase).map(escape).map {
                "kMDItemTextContent == \"*\($0)*\"cd || kMDItemDisplayName == \"*\($0)*\"cd"
            }
            parts.append("(" + alternatives.joined(separator: " || ") + ")")
        }
        parts += filters(for: query)
        return parts.joined(separator: " && ")
    }

    /// The ext:, type, date, size and tag parts.
    static func filters(for query: SearchQuery) -> [String] {
        var parts: [String] = []
        if !query.extensions.isEmpty {
            parts.append("(" + query.extensions.sorted().map { "kMDItemFSName == \"*.\(escape($0))\"c" }.joined(separator: " || ") + ")")
        }
        for ext in query.excludedExtensions.sorted() {
            parts.append("kMDItemFSName != \"*.\(escape(ext))\"c")
        }
        switch query.filter {
        case .all:
            break
        case .folders:
            parts.append("kMDItemContentType == \"public.folder\"")
        default:
            let types = query.filter.contentTypeIdentifiers.map { "kMDItemContentTypeTree == \"\($0)\"" }
            parts.append(types.count == 1 ? types[0] : "(" + types.joined(separator: " || ") + ")")
        }
        let natural = query.natural
        if let days = natural.days {
            // 3.2 counts today as the first day: "最近7天" is today and the 6 days before.
            parts.append("kMDItemFSContentChangeDate >= $time.today(-\(max(0, days - 1)))")
        }
        if natural.yesterday {
            parts.append("kMDItemFSContentChangeDate >= $time.today(-1) && kMDItemFSContentChangeDate < $time.today")
        }
        if let minimum = natural.minimum {
            parts.append("kMDItemFSSize > \(minimum)")
        }
        if let maximum = natural.maximum {
            parts.append("kMDItemFSSize < \(maximum)")
        }
        if let tag = natural.tag {
            parts.append("kMDItemUserTags == \"\(escape(tag))\"cd")
        }
        // 0.10 operators: size:, dm:, file:, folder:.
        let attributes = query.advanced.attributes
        if let minimum = attributes.minimumSize { parts.append("kMDItemFSSize >= \(minimum)") }
        if let maximum = attributes.maximumSize { parts.append("kMDItemFSSize <= \(maximum)") }
        let iso = ISO8601DateFormatter()
        if let from = attributes.modifiedFrom { parts.append("kMDItemFSContentChangeDate >= $time.iso(\(iso.string(from: from)))") }
        if let before = attributes.modifiedBefore { parts.append("kMDItemFSContentChangeDate < $time.iso(\(iso.string(from: before)))") }
        if let from = attributes.createdFrom { parts.append("kMDItemFSCreationDate >= $time.iso(\(iso.string(from: from)))") }
        if let before = attributes.createdBefore { parts.append("kMDItemFSCreationDate < $time.iso(\(iso.string(from: before)))") }
        if query.advanced.kind == .folders || (attributes.hasSize && query.advanced.kind == .any) {
            parts.append(query.advanced.kind == .folders ? "kMDItemContentType == \"public.folder\"" : "kMDItemContentType != \"public.folder\"")
        } else if query.advanced.kind == .files {
            parts.append("kMDItemContentType != \"public.folder\"")
        }
        return parts
    }

    /// Escapes a value for a Spotlight query string literal.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }
}

extension ExclusionRules {
    /// Whether these rules leave `path` out of an index of `roots`: outside every
    /// root, or inside an excluded folder, excluded name or hidden item below
    /// the innermost root holding it. Used to filter Spotlight results.
    public func excludes(path rawPath: String, roots: [String]) -> Bool {
        let path = rawPath
        guard let root = roots.filter({ Paths.isWithin(path, $0) }).max(by: { $0.count < $1.count }) else { return true }
        if path == root { return false }
        let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
        for component in relative.split(separator: "/") {
            if !includeHidden && component.hasPrefix(".") { return true }
            if excludedNames.contains(String(component)) { return true }
        }
        let excluded = excludedPaths.map(Paths.canonical)
        return excluded.contains { $0 != root && Paths.isWithin($0, root) && Paths.isWithin(path, $0) }
    }
}
