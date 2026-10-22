import CoreServices
import Foundation
import os

typealias FSEvent = (path: String, flags: FSEventStreamEventFlags)

/// Which inspector parts a batch of file events invalidates. Inside the git-dir only `index`, `HEAD`, `refs/…`,
/// `packed-refs` and `MERGE_HEAD` matter (→ status); objects, logs, lock files and the rest are git's own noise.
/// A linked worktree's common git-dir adds its `refs/…` and `packed-refs`. A `.gitignore` or `info/exclude` → everything. Git-ignored paths (`ignored`, absolute)
/// change neither the tree nor the status: builds in `node_modules`/`.build` cost no `git status`.
/// Elsewhere created/removed/renamed entries change the tree, a plain write only the status.
func classify(_ events: [FSEvent], root: String, gitDir: String?, commonDir: String? = nil, ignored: Set<String> = []) -> RefreshParts {
    let tree = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
    let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
    /// Path inside `dir` ("" for `dir` itself), nil when outside; lock files count as nothing.
    func inside(_ path: String, _ dir: String) -> Substring? {
        guard path == dir || path.hasPrefix(dir + "/") else { return nil }
        return path.dropFirst(dir.count).drop { $0 == "/" }
    }
    func first(_ rel: Substring) -> String { rel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "" }
    var result: RefreshParts = []
    for (path, flags) in events {
        if isIgnored(path, root: root, ignored: ignored) { continue }
        // New ignore rules change the listing, the ignored set and the status at once. Before RootChanged: an
        // ancestor's `.gitignore` of a subfolder project is a watched file path, an atomic save replaces it.
        if path.hasSuffix("/.gitignore") { return .all }
        // WatchRoot also reports a watched git path (packed-refs, refs) appearing or being replaced as RootChanged.
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0, path != root { result.formUnion(.status); continue }
        if flags & rescan != 0 { return .all }
        if let gitDir, let rel = inside(path, gitDir) {
            if rel == "info/exclude" { return .all }
            if !rel.hasSuffix(".lock"), ["index", "HEAD", "packed-refs", "MERGE_HEAD", "refs"].contains(first(rel)) { result.formUnion(.status) }
            continue
        }
        if let commonDir, let rel = inside(path, commonDir) {
            if rel == "info/exclude" { return .all }
            if !rel.hasSuffix(".lock"), ["packed-refs", "refs"].contains(first(rel)) { result.formUnion(.status) }
            continue
        }
        result.formUnion(flags & tree != 0 ? .all : .status)
    }
    return result
}

/// `path` or one of its ancestors below `root` is in `ignored`.
func isIgnored(_ path: String, root: String, ignored: Set<String>) -> Bool {
    guard !ignored.isEmpty, path.hasPrefix(root + "/") else { return false }
    var p = Substring(path)
    while p.count > root.count {
        if ignored.contains(String(p)) { return true }
        guard let slash = p.lastIndex(of: "/") else { break }
        p = p[..<slash]
    }
    return false
}

/// The root, plus the git-dir when it lives elsewhere (a linked worktree's is under the main repository),
/// plus the common git-dir's refs and `info/exclude` for a linked worktree (branches and shared rules live there).
/// A subfolder project (`root` under the top level `top`): not the whole repository, but the ancestors' `.gitignore`
/// files, whose rules apply to the subfolder too.
func watchPaths(root: String, gitDir: String?, commonDir: String? = nil, top: String? = nil) -> [String] {
    var paths = [root]
    if let gitDir, gitDir != root, !gitDir.hasPrefix(root + "/") {
        paths.append(gitDir)
        if let commonDir, commonDir != gitDir, commonDir != root, !commonDir.hasPrefix(root + "/") {
            paths += [commonDir + "/refs", commonDir + "/packed-refs", commonDir + "/info/exclude"]
        }
    }
    if let top, root.hasPrefix(top + "/") {
        var dir = top
        paths.append(dir + "/.gitignore")
        for part in root.dropFirst(top.count + 1).split(separator: "/").dropLast() {
            dir += "/" + part
            paths.append(dir + "/.gitignore")
        }
    }
    return paths
}

/// The canonical path FSEvents reports (`/tmp` → `/private/tmp`); unchanged when it can't be resolved.
/// Not `URL.resolvingSymlinksInPath`: it strips `/private` again.
func realPath(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// Absolute real paths of git-ignored entries, from the last tree load; read by the FSEvents queue.
final class IgnoredPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<String> = []
    var paths: Set<String> {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
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
        // WatchRoot: a moved or deleted root arrives as RootChanged (→ everything).
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
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
