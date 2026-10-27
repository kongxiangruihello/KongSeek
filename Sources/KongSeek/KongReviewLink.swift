import AppKit

/// KongReview (the user's highlight and review app) takes text through
/// kongreview://add links: its quick-capture window opens filled in, and
/// nothing is saved until the user confirms there. Ported from KongFetch 4.8.
enum KongReviewLink {
    static let bundleIdentifier = "com.kongxiangrui.KongReview"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    @discardableResult
    static func send(text: String, title: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var parts = ["text=" + encode(String(trimmed.prefix(20_000)))]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append("title=" + encode(title))
        }
        guard let url = URL(string: "kongreview://add?" + parts.joined(separator: "&")) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }

    /// Percent-encodes a query value (also "&", "=", "+" and "#").
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
