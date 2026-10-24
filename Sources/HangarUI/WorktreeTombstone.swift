import Exec
import Foundation
import Git
import Workspace

/// Crash-safe worktree removal (decision #59): a quit mid-way leaves only `<path>.hangar-removing`.
let tombstoneSuffix = ".hangar-removing"

/// One atomic rename to a sibling tombstone, `worktree prune`, then the tombstone is deleted in the background.
/// Refused unless `path` is a linked worktree of `git`'s repo other than its main folder: a wrong task path never
/// moves the main checkout or another repo. `runner`: the project's machine (argv, quoted per word over ssh).
/// The returned task is the background delete.
@discardableResult
func removeWorktreeFolder(_ path: String, git: Git, runner: Runner) async throws -> Task<Void, Never> {
    guard try await isLinkedWorktree(path, mainFolder: git.repo, runner: runner) else {
        throw TombstoneError(message: "\(path) is not a linked worktree, left in place")
    }
    return try await tombstoneFolder(path, git: git, runner: runner)
}

/// The rename without the linked-worktree check: only for a half-deleted folder that has no `.git` at all.
@discardableResult
func tombstoneFolder(_ path: String, git: Git, runner: Runner) async throws -> Task<Void, Never> {
    let tomb = path + tombstoneSuffix
    // A stale tombstone would make `mv` move the folder into it.
    _ = try await runner.run(["rm", "-rf", "--", tomb], "/")
    let mv = try await runner.run(["mv", "--", path, tomb], "/")
    guard mv.status == 0 else { throw TombstoneError(message: mv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    // The folder is gone already; a failed prune is redone by the next restore or `worktree add`.
    _ = try? await git.pruneWorktrees()
    return Task.detached { _ = try? await runner.run(["rm", "-rf", "--", tomb], "/") }
}

/// A usable worktree: its `.git` is there (a half-deleted folder inside another repo still answers rev-parse) and git agrees.
/// 255 means ssh itself failed.
func isWorktree(_ path: String, runner: Runner) async throws -> Bool {
    let script = #"test -e "$1/.git" && git -C "$1" rev-parse --is-inside-work-tree"#
    let r = try await runner.run(["sh", "-c", script, "sh", path], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
}

/// `--git-dir` differs from `--git-common-dir` only in a linked worktree (both resolved, `pwd -P`), and the folder is
/// not `mainFolder`. 255 means ssh itself failed.
func isLinkedWorktree(_ path: String, mainFolder: String, runner: Runner) async throws -> Bool {
    let script = #"""
    cd "$1" 2>/dev/null || exit 1
    dir=$(git rev-parse --git-dir) && common=$(git rev-parse --git-common-dir) || exit 1
    dir=$(cd "$dir" && pwd -P) && common=$(cd "$common" && pwd -P) || exit 1
    [ "$dir" != "$common" ] || exit 1
    [ "$(pwd -P)" != "$(cd "$2" 2>/dev/null && pwd -P)" ] || exit 1
    """#
    let r = try await runner.run(["sh", "-c", script, "sh", path, mainFolder], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0
}

/// Restore's folder step (decision #57): a valid worktree stays; a folder without `.git` (half-deleted tombstone)
/// goes; one with `.git` gets `git worktree repair` and is otherwise left untouched (`.failed`). Never deletes user files.
func reviveWorktree(_ path: String, branch: String, git: Git, runner: Runner) async throws -> RestoreOutcome {
    if try await isWorktree(path, runner: runner) { return .restored }
    guard try await git.hasBranch(branch) else { return .branchMissing(branch) }
    if try await isDirectory(path, runner: runner) {
        if try await hasGitEntry(path, runner: runner) {
            _ = try? await git.repairWorktree(path: path)
            return try await isWorktree(path, runner: runner) ? .restored : .failed("\(path) is not a valid worktree, left in place")
        }
        // Half-removed by a quit mid `worktree remove` (an older build): nothing of git's left, it goes as archive meant.
        try await tombstoneFolder(path, git: git, runner: runner)
    }
    // A folder deleted by hand leaves a registration that blocks `worktree add`.
    try await git.pruneWorktrees()
    try await git.addWorktree(path: path, existingBranch: branch)
    return .restored
}

/// `test -e <path>/.git` (file or folder); 255 means ssh itself failed.
private func hasGitEntry(_ path: String, runner: Runner) async throws -> Bool {
    let r = try await runner.run(["test", "-e", path + "/.git"], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0
}

private struct TombstoneError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppState {
    /// Startup (local, `host` nil) and host connect: tombstones a quit left behind go, only in the worktree roots of
    /// known projects (the configured root and the folders of their worktree tasks).
    public func sweepTombstones(host: String?) async {
        for project in state.projects where project.host == host {
            let worktrees = state.tasks.compactMap { task -> String? in
                guard task.projectId == project.id, case .worktree(let path, _, _) = task.mode else { return nil }
                return path
            }
            // shortcut: a project with no worktree task left is skipped (no ssh call on every connect); a tombstone of
            // a deleted task waits for the next worktree task there.
            guard !worktrees.isEmpty else { continue }
            let dirs = Set(worktrees.map(parent) + [parent(worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: "x"))])
            let script = #"for d; do for t in "$d"/*.hangar-removing; do [ -d "$t" ] && rm -rf -- "$t"; done; done; exit 0"#
            _ = try? await runner(for: project).run(["sh", "-c", script, "sh"] + dirs.sorted(), "/")
        }
    }

    private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
}
