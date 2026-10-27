import AppKit
import KongSeekCore

/// KongReview (the user's highlight and review app) takes text through
/// kongreview://add links: its quick-capture window opens filled in, and
/// nothing is saved until the user confirms there. Ported from KongFetch 4.8.
enum KongReviewLink {
    static let bundleIdentifier = "com.kongxiangrui.KongReview"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Opens KongReview's capture window with the text and, when given, the book's
    /// title and author, the place (第 23 页), a note (the full reference) and tags.
    /// KongReview's kongreview://add takes all of these (KongReview SettingsView, 0.22).
    @discardableResult
    static func send(text: String, title: String? = nil, author: String? = nil, location: String? = nil,
                     note: String? = nil, tags: [String] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var parts = ["text=" + encode(String(trimmed.prefix(20_000)))]
        for (key, value) in [("title", title), ("author", author), ("location", location), ("note", note)] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { parts.append(key + "=" + encode(value)) }
        }
        if !tags.isEmpty { parts.append("tags=" + encode(tags.joined(separator: ","))) }
        guard let url = URL(string: "kongreview://add?" + parts.joined(separator: "&")) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }

    static func encode(_ value: String) -> String {
        QuickLink.encode(value)
    }
}
