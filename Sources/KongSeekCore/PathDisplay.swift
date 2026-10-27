import Foundation

/// Friendlier folder names for display: iCloud Drive and cloud drives instead of ~/Library paths.
public enum PathDisplay {
    public static func pretty(_ path: String, home: String) -> String {
        let mobile = home + "/Library/Mobile Documents/"
        let iCloudDrive = mobile + "com~apple~CloudDocs"
        if path == iCloudDrive || path.hasPrefix(iCloudDrive + "/") {
            return "iCloud 云盘" + path.dropFirst(iCloudDrive.count)
        }
        if path.hasPrefix(mobile) {
            // e.g. iCloud~com~xmind~brownieapp/Documents/… — an app's own iCloud folder.
            let parts = path.dropFirst(mobile.count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let container = String(parts[0])
            let app = container.split(separator: "~").last.map(String.init) ?? container
            var tail = parts.count > 1 ? String(parts[1]) : ""
            if tail == "Documents" { tail = "" } else if tail.hasPrefix("Documents/") { tail.removeFirst("Documents/".count) }
            return "iCloud 云盘（\(app)）" + (tail.isEmpty ? "" : "/" + tail)
        }
        let cloudStorage = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloudStorage) {
            let parts = path.dropFirst(cloudStorage.count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let provider = parts[0].split(separator: "-").first.map(String.init) ?? String(parts[0])
            return provider + (parts.count > 1 ? "/" + parts[1] : "")
        }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
