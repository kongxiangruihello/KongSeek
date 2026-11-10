#if canImport(CoreServices)
import CoreServices
import Foundation

/// FSEvents watcher that can resume from a saved event id, so changes made while
/// KongSeek was not running are replayed at the next launch instead of
/// requiring a rescan (3.2 always started from "now"). Folders that cannot matter
/// (~/Library, hidden folders) are filtered out by FSEvents itself (0.46).
public final class FileChangeWatcher {
    public struct Batch: Sendable {
        public var changes: [IndexChange] = []
        /// Highest event id in this batch; store it as `NameIndex.lastEventID` after applying.
        public var lastEventID: UInt64 = 0
        /// Event ids wrapped or a watched root moved/was deleted: rebuild the index.
        public var requiresFullRebuild = false
        /// The replay of past events is finished; later batches are live.
        public var historyDone = false
    }

    private let paths: [String]
    private let exclusions: [String]
    private let since: UInt64?
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: (Batch) -> Void
    private var streams: [FSEventStreamRef] = []
    /// Streams still replaying past events (touched only on `queue`).
    private var historyPending = 0

    /// FSEvents filters at most this many folders per stream.
    static let maximumExclusions = 8

    /// - Parameters:
    ///   - exclusions: folders whose events FSEvents should not deliver at all (0.46), such
    ///     as ~/Library; each goes to the stream of the innermost watched folder holding it.
    ///   - since: resume after this event id (`NameIndex.lastEventID`); nil starts from now.
    ///   - handler: called on `queue` with each batch.
    public init(paths: [String], excluding exclusions: [String] = [], since: UInt64? = nil, latency: TimeInterval = 0.3,
                queue: DispatchQueue = .main, handler: @escaping (Batch) -> Void) {
        self.paths = paths
        self.exclusions = exclusions
        self.since = since
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    /// One stream per watched folder (0.46), so each can leave out its own folders: the
    /// home folder's stream skips ~/Library while iCloud Drive, inside it, has a stream of its own.
    @discardableResult
    public func start() -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let watcher = Unmanaged<FileChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch = Batch()
            let rebuildFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            for i in 0..<count {
                let flag = rawFlags[i]
                batch.lastEventID = max(batch.lastEventID, rawIDs[i])
                if flag & historyDone != 0 {
                    // The replay is over once every stream has finished its own.
                    watcher.historyPending -= 1
                    if watcher.historyPending <= 0 { batch.historyDone = true }
                    continue
                }
                if flag & rebuildFlags != 0 { batch.requiresFullRebuild = true }
                batch.changes.append(IndexChange(path: String(cString: cPaths[i]), rescanSubtree: flag & rescanFlags != 0))
            }
            watcher.handler(batch)
        }
        let startID = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        historyPending = since == nil ? 0 : paths.count
        for path in paths {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, startID, latency, createFlags) else {
                stop()
                return false
            }
            let excluded = Self.exclusions(for: path, watching: paths, from: exclusions)
            if !excluded.isEmpty { _ = FSEventStreamSetExclusionPaths(created, excluded as CFArray) }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                stop()
                return false
            }
            streams.append(created)
        }
        return true
    }

    public func stop() {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams = []
    }

    /// The exclusions for the stream of `path`: those inside it and not inside a deeper
    /// watched folder (whose own stream takes them), at most `maximumExclusions`, in the given order.
    static func exclusions(for path: String, watching paths: [String], from all: [String]) -> [String] {
        let deeper = paths.filter { $0 != path && Paths.isWithin($0, path) }
        var picked: [String] = []
        for folder in all where folder != path && Paths.isWithin(folder, path) && !picked.contains(folder) {
            if deeper.contains(where: { Paths.isWithin(folder, $0) }) { continue }
            picked.append(folder)
            if picked.count == maximumExclusions { break }
        }
        return picked
    }

    /// The newest event id on this Mac; record it right before a full build.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identity of the FSEvents database for the volume holding `path`.
    /// If it differs from the one saved with the index, old event ids are meaningless.
    public static func eventDatabaseUUID(forPath path: String) -> String? {
        var info = stat()
        // Recent SDKs return a managed CFUUID (older ones an Unmanaged value).
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        guard let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return text as String
    }
}
#endif
