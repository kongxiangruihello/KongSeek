import AppKit
import KongSeekCore

/// 卡顿记录 (0.44): a watch on the main thread. Four times a second a background queue asks
/// the main thread to answer; when the answer takes half a second or more, the window of
/// time is recorded with what KongSeek was doing, for 状态与诊断 › 性能.
final class HangMonitor {
    static let shared = HangMonitor()

    /// Hitches shorter than this are not recorded.
    static let threshold: Double = 500

    private let queue = DispatchQueue(label: "KongSeek.hang-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    // On `queue`.
    private var askedAt: CFAbsoluteTime?
    private var discardNext = false
    private var log = HitchLog()
    private let lock = NSLock()
    private var snapshot = HitchLog()

    // On main.
    private static var activity = ""
    private static var activityTime: CFAbsoluteTime = 0
    private var eventMonitor: Any?

    private var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongSeek/hitches.json")
    }

    /// What KongSeek is doing now ("搜索：论语", "预览：论语译注.pdf"), named in a hitch
    /// that follows. Main thread.
    static func note(_ what: String) {
        activity = String(what.prefix(60))
        activityTime = CFAbsoluteTimeGetCurrent()
    }

    func start() {
        guard timer == nil else { return }
        let url = logURL
        queue.async { [weak self] in
            guard let self else { return }
            self.log = HitchLog.load(from: url)
            self.publish()
        }
        // The window last typed or clicked in, when nothing more precise was noted.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { event in
            if CFAbsoluteTimeGetCurrent() - HangMonitor.activityTime > 2 {
                let title = event.window?.title ?? ""
                HangMonitor.note((event.type == .keyDown ? "按键" : "点按") + (title.isEmpty ? "" : "（\(title)）"))
            }
            return event
        }
        // A question asked just before the Mac slept is answered after it wakes: not a hitch.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.discardNext = true }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// The hitches recorded, for the health report.
    var hitches: HitchLog {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    private func tick() {
        guard askedAt == nil else { return }
        let asked = CFAbsoluteTimeGetCurrent()
        askedAt = asked
        DispatchQueue.main.async { [weak self] in
            let answered = CFAbsoluteTimeGetCurrent()
            let recent = answered - HangMonitor.activityTime < 15 ? HangMonitor.activity : ""
            self?.queue.async { self?.answered(asked: asked, answered: answered, activity: recent) }
        }
    }

    private func answered(asked: CFAbsoluteTime, answered: CFAbsoluteTime, activity: String) {
        askedAt = nil
        let milliseconds = (answered - asked) * 1000
        if discardNext {
            discardNext = false
            return
        }
        guard milliseconds >= Self.threshold, milliseconds < 30 * 60 * 1000 else { return }
        log.add(date: Date(timeIntervalSinceReferenceDate: asked), milliseconds: milliseconds, activity: activity)
        publish()
        try? log.save(to: logURL)
    }

    private func publish() {
        lock.lock()
        snapshot = log
        lock.unlock()
    }
}
