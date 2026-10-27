import AppKit

/// Opens a presentation in Microsoft PowerPoint at a given slide (0.18), with
/// AppleScript run by osascript so KongSeek does not wait for PowerPoint.
enum PowerPoint {
    static let bundleIdentifier = "com.microsoft.Powerpoint"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Opens `path` and shows slide `number`. Calls back on main with nil when it
    /// worked, or a message saying what happened instead.
    static func open(_ path: String, slide number: Int, completion: @escaping (String?) -> Void) {
        guard isInstalled else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            completion("未找到 Microsoft PowerPoint，已用默认应用打开，请手动翻到第 \(number) 张。")
            return
        }
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "\(bundleIdentifier)"
            activate
            open (POSIX file "\(quoted)")
            repeat 80 times
                if (count of document windows) > 0 then exit repeat
                delay 0.25
            end repeat
            go to slide (view of document window 1) number \(number)
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let output = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message: String?
            if finished.terminationStatus == 0 {
                message = nil
            } else if output.contains("-1743") || output.contains("Not authorized") || output.contains("不允许") {
                message = "已打开，但 KongSeek 还没有控制 PowerPoint 的权限：请在 系统设置 › 隐私与安全性 › 自动化 中，允许 KongSeek 控制 Microsoft PowerPoint，然后再试。"
            } else {
                message = "已用 PowerPoint 打开，但未能翻到第 \(number) 张，请手动翻到该页。"
            }
            DispatchQueue.main.async { completion(message) }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            completion("已打开，但未能翻到第 \(number) 张，请手动翻到该页。")
        }
    }
}
