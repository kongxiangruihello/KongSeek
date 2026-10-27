import AppKit

/// What can be done with a result: open, open with, reveal, copy, Terminal,
/// move to Trash (undoable). Each method returns a short message for the status line.
final class ResultActions {
    /// Items moved to the Trash by the last trash action, for ⌘Z.
    private var lastTrashed: [(original: URL, trashed: URL)] = []

    var canUndoTrash: Bool { !lastTrashed.isEmpty }

    func open(_ item: ResultItem) {
        Preferences.recordOpen(item.path)
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    func open(_ item: ResultItem, with application: URL) {
        Preferences.recordOpen(item.path)
        NSWorkspace.shared.open([URL(fileURLWithPath: item.path)], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func reveal(_ item: ResultItem) {
        Preferences.recordOpen(item.path)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// Applications that can open the item, the default one first (at most 12).
    func applications(for item: ResultItem) -> [URL] {
        let url = URL(fileURLWithPath: item.path)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: url), let index = apps.firstIndex(of: preferred) {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)
        }
        return Array(apps.prefix(12))
    }

    enum CopyKind {
        case file, path, name
    }

    func copy(_ item: ResultItem, as kind: CopyKind) -> String {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch kind {
        case .file:
            pasteboard.writeObjects([URL(fileURLWithPath: item.path) as NSURL])
            return "已拷贝文件：\(item.name)"
        case .path:
            pasteboard.setString(item.path, forType: .string)
            return "已拷贝路径：\(item.path)"
        case .name:
            pasteboard.setString(item.name, forType: .string)
            return "已拷贝名称：\(item.name)"
        }
    }

    /// Opens Terminal in the folder (or in the folder that contains the file).
    func openInTerminal(_ item: ResultItem) -> String? {
        let folder = item.isFolder ? item.path : (item.path as NSString).deletingLastPathComponent
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return "找不到“终端”" }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    func moveToTrash(_ item: ResultItem) -> String {
        let url = URL(fileURLWithPath: item.path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            return "无法移到废纸篓：\(error.localizedDescription)"
        }
        Preferences.forget(item.path)
        lastTrashed = resulting.map { [(url, $0 as URL)] } ?? []
        return "已移到废纸篓：\(item.name)" + (lastTrashed.isEmpty ? "" : "（⌘Z 放回）")
    }

    func undoTrash() -> String {
        var restored: [String] = []
        for entry in lastTrashed where !FileManager.default.fileExists(atPath: entry.original.path) {
            if (try? FileManager.default.moveItem(at: entry.trashed, to: entry.original)) != nil {
                restored.append(entry.original.lastPathComponent)
            }
        }
        lastTrashed = []
        return restored.isEmpty ? "无法放回（废纸篓中已找不到该项，或原位置已有同名项）" : "已放回：\(restored.joined(separator: "、"))"
    }
}
