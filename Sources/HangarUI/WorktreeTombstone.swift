import Exec
import Foundation
import Git
import Workspace

/// Crash-safe worktree removal (decision #NN-crash-safe-archive): a quit mid-way leaves only `<path>.hangar-removing`.
let tombstoneSuffix = ".hangar-removing"

/// One atomic rename to a sibling tombstone, `worktree prune`, then the tombstone is deleted in the background.
/// `runner`: the project's machine (argv, quoted per word over ssh). The returned task is the background delete.
@discardableResult
func removeWorktreeFolder(_ path: String, git: Git, runner: Runner) async throws -> Task<Void, Never> {
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

private struct TombstoneError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppState {
    /// Startup (local, `host` nil) and host connect: tombstones a quit left behind go, only in the worktree roots of
    /// known projects (the configured root and the folders of their worktree tasks).
    public func sweepTombstones(host: String?) async {
        for project in state.projects where project.host == host {
            var dirs: Set<String> = [parent(worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: "x"))]
            for task in state.tasks where task.projectId == project.id {
                if case .worktree(let path, _, _) = task.mode { dirs.insert(parent(path)) }
            }
            let script = #"for d; do for t in "$d"/*.hangar-removing; do [ -d "$t" ] && rm -rf -- "$t"; done; done; exit 0"#
            _ = try? await runner(for: project).run(["sh", "-c", script, "sh"] + dirs.sorted(), "/")
        }
    }

    private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
}
