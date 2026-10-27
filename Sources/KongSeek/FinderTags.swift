import Foundation

/// Finder tags on files: the 已读 mark (0.16) and tags moved out of file names.
enum FinderTags {
    static let read = "已读"
    /// Reading states, one at a time (0.18).
    static let readingStates = ["待读", "在读", "精读", "已读"]

    /// The file's reading state, if it has one of `readingStates`.
    static func readingState(of path: String) -> String? {
        let current = tags(of: path)
        return readingStates.first { current.contains($0) }
    }

    /// Sets one reading state (nil clears it), keeping the file's other tags.
    @discardableResult
    static func setReadingState(_ state: String?, on path: String) -> Bool {
        var current = tags(of: path).filter { !readingStates.contains($0) }
        if let state { current.append(state) }
        do {
            try (URL(fileURLWithPath: path) as NSURL).setResourceValue(current, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }

    static func tags(of path: String) -> [String] {
        var url = URL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    static func has(_ tag: String, _ path: String) -> Bool {
        tags(of: path).contains(tag)
    }

    /// Adds (or with `adding: false` removes) a tag, keeping the file's other tags.
    @discardableResult
    static func set(_ tag: String, on path: String, adding: Bool) -> Bool {
        let url = URL(fileURLWithPath: path)
        var current = tags(of: path)
        if adding {
            guard !current.contains(tag) else { return true }
            current.append(tag)
        } else {
            guard current.contains(tag) else { return true }
            current.removeAll { $0 == tag }
        }
        // URLResourceValues.tagNames is read-only in Swift; NSURL can set it.
        do {
            try (url as NSURL).setResourceValue(current, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }
}
