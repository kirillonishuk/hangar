import Foundation

/// Why a file revert was refused before anything changed (decision HD-156).
public enum RevertError: Error, Equatable, Sendable {
    /// The project is on a server: no snapshot for undo and no Trash there.
    case remote
    /// A directory (submodule, nested checkout) is at the path, not a file.
    case notAFile(String)
    /// Nothing to revert: the path is neither in HEAD, the index nor on disk.
    case nothingToRevert
    /// «Вернуть» refused: something wrote the path after the revert (an agent); nothing put back, the snapshot stays.
    case changedSince(String)
    /// git or the Trash failed after the snapshot was taken: the bytes are in `dir`.
    case afterSnapshot(dir: String, String)
    /// The path was written after its snapshot was taken (an agent): left as it is; what was reverted before it is in `dir`.
    case changedWhileReverting(dir: String, String)
}

/// A path's item as `lstat` sees it, to tell that nothing touched it since (decision HD-156).
public struct RevertStamp: Codable, Equatable, Sendable {
    var size: Int64, mtime: Int, mtimeNsec: Int, inode: UInt64, mode: UInt16

    /// nil — nothing at the path.
    public init?(of path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        size = Int64(st.st_size); mtime = st.st_mtimespec.tv_sec; mtimeNsec = st.st_mtimespec.tv_nsec
        inode = UInt64(st.st_ino); mode = UInt16(st.st_mode)
    }
}

/// A reverted file's state before the revert (decision HD-156): each path's item copied into `dir` (a symlink stays a
/// link, the mode is kept), or noted as absent. `undo()` puts every path back as it was on disk.
public struct RevertBackup: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Absolute path of the reverted file.
        public var path: String
        /// File name of the copy inside `dir`; nil — the path did not exist (a deleted file brought back).
        public var saved: String?
        /// The path right after the revert; nil — nothing there.
        public var after: RevertStamp?
    }

    public var dir: String
    public var entries: [Entry]

    /// The working tree only: what was staged comes back unstaged (the bytes are what matters). Refused when a path
    /// changed after the revert: it is not the copy from HEAD any more, and putting the snapshot back would lose it.
    /// What is replaced goes into `dir` (never deleted), and comes back if the copy fails.
    public func undo() throws {
        let fm = FileManager.default
        if let changed = entries.first(where: { RevertStamp(of: $0.path) != $0.after }) { throw RevertError.changedSince(changed.path) }
        for (i, e) in entries.enumerated() {
            let aside = dir + "/replaced-\(i)-" + (e.path as NSString).lastPathComponent
            let moved = itemExists(e.path)
            if moved { try fm.moveItem(atPath: e.path, toPath: aside) }
            guard let saved = e.saved else { continue }
            do {
                try fm.createDirectory(atPath: (e.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: dir + "/" + saved, toPath: e.path)
            } catch {
                if moved, !itemExists(e.path) { try? fm.moveItem(atPath: aside, toPath: e.path) }
                throw error
            }
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
        // Each path as it was snapshotted: a write after the copy (the agent works on) refuses the revert of that path.
        var snapped: [RevertStamp?] = []
        for (i, step) in plan.enumerated() {
            let full = repo + "/" + step.path
            snapped.append(RevertStamp(of: full))
            var saved: String?
            if itemExists(full) {
                saved = "\(i)-" + (step.path as NSString).lastPathComponent
                try FileManager.default.copyItem(atPath: full, toPath: dir + "/" + saved!)
            }
            backup.entries.append(.init(path: full, saved: saved))
        }
        // A note for finding a file by hand later; the undo itself uses the value in memory.
        try JSONEncoder().encode(backup).write(to: URL(fileURLWithPath: dir + "/backup.json"))

        do {
            for (i, step) in plan.enumerated() {
                let full = repo + "/" + step.path
                func unchanged() throws { if RevertStamp(of: full) != snapped[i] { throw RevertError.changedWhileReverting(dir: dir, step.path) } }
                try unchanged()
                if step.inHead {
                    try await exec(["restore", "--source=HEAD", "--staged", "--worktree", "--", ":(literal)" + step.path])
                    continue
                }
                // `-f`: staged content that differs from the file is dropped too (the file's own bytes are in the backup).
                if step.inIndex { try await exec(["rm", "--cached", "-f", "-q", "--", ":(literal)" + step.path]) }
                try unchanged()
                if itemExists(full) { try trash(URL(fileURLWithPath: full)) }
            }
        } catch let error as RevertError {
            throw error
        } catch {
            throw RevertError.afterSnapshot(dir: dir, error.localizedDescription)
        }
        for i in backup.entries.indices { backup.entries[i].after = RevertStamp(of: backup.entries[i].path) }
        return backup
    }

    private func catFileExists(_ object: String) async -> Bool {
        let r = try? await runner.run(["git", "--no-optional-locks", "cat-file", "-e", object], repo)
        return r?.status == 0
    }
}
