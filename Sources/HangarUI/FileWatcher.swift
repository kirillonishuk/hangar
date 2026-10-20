import CoreServices
import Foundation
import os

typealias FSEvent = (path: String, flags: FSEventStreamEventFlags)

/// Which inspector parts a batch of file events invalidates. Inside the git-dir only `index`, `HEAD`, `refs/…`,
/// `packed-refs` and `MERGE_HEAD` matter (→ status); objects, logs, lock files and the rest are git's own noise.
/// Elsewhere created/removed/renamed entries change the tree, a plain write only the status.
func classify(_ events: [FSEvent], root: String, gitDir: String?) -> RefreshParts {
    let tree = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
    let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
    var result: RefreshParts = []
    for (path, flags) in events {
        if flags & rescan != 0 { return .all }
        if let gitDir, path == gitDir || path.hasPrefix(gitDir + "/") {
            let rel = path.dropFirst(gitDir.count).drop { $0 == "/" }
            guard !rel.hasSuffix(".lock") else { continue }
            let first = rel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if ["index", "HEAD", "packed-refs", "MERGE_HEAD", "refs"].contains(first) { result.formUnion(.status) }
            continue
        }
        result.formUnion(flags & tree != 0 ? .all : .status)
    }
    return result
}

/// The root, plus the git-dir when it lives elsewhere (a linked worktree's is under the main repository).
func watchPaths(root: String, gitDir: String?) -> [String] {
    guard let gitDir, gitDir != root, !gitDir.hasPrefix(root + "/") else { return [root] }
    return [root, gitDir]
}

func shouldWatch(inspectorVisible: Bool, windowVisible: Bool, hasTask: Bool) -> Bool {
    inspectorVisible && windowVisible && hasTask
}

/// FSEvents on a few paths: one stream, latency 0.3 s (the coalescing is the system's — no timers here),
/// delivered on the main actor. Stopped (no stream, no callbacks) by `stop()` or deinit.
final class FileWatcher: Sendable {
    private final class Box: @unchecked Sendable {
        let onChange: @MainActor (RefreshParts) -> Void
        let classify: @Sendable ([FSEvent]) -> RefreshParts
        private let lock = NSLock()
        private var _stopped = false
        var stream: FSEventStreamRef?
        var stopped: Bool { lock.withLock { _stopped } }
        /// Marks stopped and hands out the stream once.
        func takeStream() -> FSEventStreamRef? {
            lock.withLock { _stopped = true; defer { stream = nil }; return stream }
        }
        init(onChange: @escaping @MainActor (RefreshParts) -> Void, classify: @escaping @Sendable ([FSEvent]) -> RefreshParts) {
            self.onChange = onChange
            self.classify = classify
        }
    }

    private let box: Box
    private let queue = DispatchQueue(label: "hangar.filewatcher", qos: .utility)

    init(paths: [String], onChange: @escaping @MainActor (RefreshParts) -> Void,
         classify: @escaping @Sendable ([FSEvent]) -> RefreshParts) {
        box = Box(onChange: onChange, classify: classify)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            let events = (0..<min(count, list.count)).map { FSEvent(path: list[$0], flags: eventFlags[$0]) }
            let parts = box.classify(events)
            guard !parts.isEmpty else { return }
            DispatchQueue.main.async {
                guard !box.stopped else { return }
                MainActor.assumeIsolated { box.onChange(parts) }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            uiLog.error("FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        box.stream = s
    }

    func stop() {
        guard let s = box.takeStream() else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        queue.sync {}  // a callback already running finishes before the box can go
    }

    deinit { stop() }
}
