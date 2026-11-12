import Foundation

/// Why a file revert was refused before anything changed (decision HD-156).
public enum RevertError: Error, Equatable, Sendable {
    /// The project is on a server: no snapshot for undo and no Trash there.
    case remote
    /// A directory (submodule, nested checkout) is at the path, not a file.
    case notAFile(String)
    /// Nothing to revert: the path is neither in HEAD, the index nor on disk.
    case nothingToRevert
}

/// A reverted file's state before the revert (decision HD-156): each path's item copied into `dir` (a symlink stays a
/// link, the mode is kept), or noted as absent. `undo()` puts every path back as it was on disk.
public struct RevertBackup: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Absolute path of the reverted file.
        public var path: String
        /// File name of the copy inside `dir`; nil — the path did not exist (a deleted file brought back).
        public var saved: String?
    }

    public var dir: String
    public var entries: [Entry]

    /// The working tree only: what was staged comes back unstaged (the bytes are what matters).
    public func undo() throws {
        let fm = FileManager.default
        for e in entries {
            if itemExists(e.path) { try fm.removeItem(atPath: e.path) }
            guard let saved = e.saved else { continue }
            try fm.createDirectory(atPath: (e.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: dir + "/" + saved, toPath: e.path)
        }
    }

    /// Snapshots older than `age` under `root` go (one listing; called before each new snapshot).
    public static func prune(_ root: String, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return }
        for name in names {
            let path = root + "/" + name
            let made = (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? now
            if now.timeIntervalSince(made) > age { try? fm.removeItem(atPath: path) }
        }
    }
}

/// lstat: a dangling symlink still exists.
func itemExists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

extension Git {
    /// Drops the uncommitted changes of `path` (relative to `repo`; `origPath` — a rename's old name) after copying
    /// what is on disk into a new folder under `backupRoot` (decision HD-156). A path HEAD has: `git restore
    /// --source=HEAD --staged --worktree`; one it doesn't (untracked, staged new): out of the index, the file to `trash`
    /// (never deleted). Local projects only.
    public func revertFile(_ path: String, origPath: String? = nil, backupRoot: String,
                           trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        async throws -> RevertBackup {
        guard runner.isLocal else { throw RevertError.remote }
        let paths = [path] + (origPath.map { [$0] } ?? [])
        // Not followed: a symlink to a folder is a file to git.
        for p in paths where (try? FileManager.default.attributesOfItem(atPath: repo + "/" + p)[.type] as? FileAttributeType) == .typeDirectory {
            throw RevertError.notAFile(p)
        }
        let hasHead = await hasCommits()
        var plan: [(path: String, inHead: Bool, inIndex: Bool)] = []
        for p in paths {
            let inHead = hasHead ? await catFileExists("HEAD:./" + p) : false
            let inIndex = try await !exec(["ls-files", "-z", "--", ":(literal)" + p]).isEmpty
            plan.append((p, inHead, inIndex))
        }
        guard plan.contains(where: { $0.inHead || $0.inIndex || itemExists(repo + "/" + $0.path) }) else {
            throw RevertError.nothingToRevert
        }

        RevertBackup.prune(backupRoot, olderThan: 7 * 24 * 3600)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = backupRoot + "/" + stamp + "-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var backup = RevertBackup(dir: dir, entries: [])
        for (i, step) in plan.enumerated() {
            let full = repo + "/" + step.path
            var saved: String?
            if itemExists(full) {
                saved = "\(i)-" + (step.path as NSString).lastPathComponent
                try FileManager.default.copyItem(atPath: full, toPath: dir + "/" + saved!)
            }
            backup.entries.append(.init(path: full, saved: saved))
        }
        // A note for finding a file by hand later; the undo itself uses the value in memory.
        try JSONEncoder().encode(backup).write(to: URL(fileURLWithPath: dir + "/backup.json"))

        for step in plan {
            if step.inHead {
                try await exec(["restore", "--source=HEAD", "--staged", "--worktree", "--", ":(literal)" + step.path])
                continue
            }
            // `-f`: staged content that differs from the file is dropped too (the file's own bytes are in the backup).
            if step.inIndex { try await exec(["rm", "--cached", "-f", "-q", "--", ":(literal)" + step.path]) }
            let full = repo + "/" + step.path
            if itemExists(full) { try trash(URL(fileURLWithPath: full)) }
        }
        return backup
    }

    private func catFileExists(_ object: String) async -> Bool {
        let r = try? await runner.run(["git", "--no-optional-locks", "cat-file", "-e", object], repo)
        return r?.status == 0
    }
}
