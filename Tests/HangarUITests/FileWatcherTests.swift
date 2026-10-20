import CoreServices
import Foundation
import Testing
@testable import HangarUI

@MainActor @Suite struct FileWatcherTests {
    private let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    private let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
    private let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
    private let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)

    private func parts(_ path: String, _ flags: FSEventStreamEventFlags, gitDir: String? = "/r/main/.git") -> RefreshParts {
        classify([(path: path, flags: flags)], root: "/r/main", gitDir: gitDir)
    }

    @Test func classifyGitInternals() {
        for ignored in [".git/objects/ab/cd", ".git/logs/HEAD", ".git/index.lock", ".git/FETCH_HEAD", ".git/refs/heads/main.lock",
                        ".git/config", ".git/hooks/pre-commit"] {
            #expect(parts("/r/main/" + ignored, modified | created).isEmpty, "\(ignored)")
        }
        for status in [".git/index", ".git/HEAD", ".git/refs/heads/main", ".git/packed-refs", ".git/MERGE_HEAD"] {
            #expect(parts("/r/main/" + status, modified | created) == .status, "\(status)")
        }
        // A worktree's git-dir lives outside the root.
        let wt = "/r/main/.git/worktrees/wt"
        #expect(classify([(path: wt + "/index", flags: modified)], root: "/r/wt", gitDir: wt) == .status)
        #expect(classify([(path: wt + "/logs/HEAD", flags: modified)], root: "/r/wt", gitDir: wt).isEmpty)
    }

    @Test func classifyWorktreeFiles() {
        #expect(parts("/r/main/src/a.swift", modified) == .status)
        #expect(parts("/r/main/src/a.swift", created) == .all)
        #expect(parts("/r/main/src/a.swift", removed) == .all)
        #expect(parts("/r/main/src/a.swift", renamed) == .all)
        #expect(parts("/r/main/src/a.swift", modified | created) == .all)
        #expect(parts("/r/main/src", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) == .all)
        #expect(parts("/r/main", FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) == .all)
        // `.git` as a file (linked worktree) is an ordinary entry of the root.
        #expect(classify([(path: "/r/wt/.git", flags: created)], root: "/r/wt", gitDir: "/r/main/.git/worktrees/wt") == .all)
        // Not a repository: everything is ordinary.
        #expect(parts("/r/main/a.txt", modified, gitDir: nil) == .status)
        // Several events: the union.
        let mixed = classify([(path: "/r/main/.git/objects/x", flags: created), (path: "/r/main/a", flags: modified),
                              (path: "/r/main/b", flags: created)], root: "/r/main", gitDir: "/r/main/.git")
        #expect(mixed == .all)
        // A sibling that merely shares the prefix is not inside the git-dir.
        #expect(classify([(path: "/r/main/.github/x", flags: modified)], root: "/r/main", gitDir: "/r/main/.git") == .status)
    }

    @Test func watchPathsForWorktree() {
        #expect(watchPaths(root: "/r/wt", gitDir: "/r/main/.git/worktrees/wt") == ["/r/wt", "/r/main/.git/worktrees/wt"])
        #expect(watchPaths(root: "/r/wt", gitDir: "/r/wt/.git") == ["/r/wt"])
        #expect(watchPaths(root: "/r/wt", gitDir: nil) == ["/r/wt"])
        #expect(watchPaths(root: "/r/wt", gitDir: "/r/wt2/.git") == ["/r/wt", "/r/wt2/.git"])
    }

    @Test func shouldWatchMatrix() {
        for i in 0..<8 {
            let a = i & 1 != 0, b = i & 2 != 0, c = i & 4 != 0
            #expect(shouldWatch(inspectorVisible: a, windowVisible: b, hasTask: c) == (a && b && c))
        }
    }

    private final class Counter: @unchecked Sendable { var n = 0; var last: RefreshParts = [] }

    @Test func watcherDeliversOnce() async throws {
        let base = NSTemporaryDirectory() + "hangar-fsw-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // FSEvents reports real paths (/var → /private/var).
        let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let counter = Counter()
        let watcher = FileWatcher(paths: [root], onChange: { counter.n += 1; counter.last.formUnion($0) },
                                  classify: { classify($0, root: root, gitDir: nil) })
        try await Task.sleep(for: .milliseconds(500))
        for i in 0..<20 { try "x".write(toFile: "\(root)/f\(i).txt", atomically: false, encoding: .utf8) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect((1...3).contains(counter.n), "calls: \(counter.n)")
        #expect(counter.last == .all)

        watcher.stop()
        let before = counter.n
        for i in 0..<20 { try "y".write(toFile: "\(root)/g\(i).txt", atomically: false, encoding: .utf8) }
        try await Task.sleep(for: .milliseconds(1000))
        #expect(counter.n == before)
    }

    @Test func emptyClassificationIsSilent() async throws {
        let base = NSTemporaryDirectory() + "hangar-fsw-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let counter = Counter()
        let watcher = FileWatcher(paths: [root], onChange: { _ in counter.n += 1 }, classify: { _ in [] })
        try await Task.sleep(for: .milliseconds(500))
        try "x".write(toFile: root + "/a.txt", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(counter.n == 0)
        watcher.stop()
    }
}
