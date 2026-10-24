import Exec
import Foundation
import Git
import Workspace

/// «Удалить навсегда» for an archived task. Without `alsoWorktree` nothing on disk is touched (decisions #39/#42).
/// With it: missing folder → prune; dirty or holding ignored files → ask before forcing; remove the worktree, drop the task, then `branch -d`
/// (an unmerged branch is kept and reported). `runner`: the project's machine — a remote worktree is checked on its server.
/// A check that fails (host down, git error) stops here: guessing "clean" or "missing" could lose files or orphan the worktree.
@MainActor func deleteTaskPermanently(_ id: UUID, alsoWorktree: Bool, ctx: ActionContext, git: Git, runner: Runner = .local) async {
    let app = ctx.app
    guard let task = app.state.tasks.first(where: { $0.id == id }) else { return }
    guard alsoWorktree, case .worktree(let path, let branch, _) = task.mode else {
        app.perform { $0.deleteTask(id: id) }
        return
    }
    let check: WorktreeCheck
    do {
        check = try await checkWorktree(path, git: git, runner: runner)
    } catch {
        ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription)
        return
    }
    switch check {
    case .missing:
        _ = try? await git.pruneWorktrees()
        await finishDeletion(id, branch: branch, ctx: ctx, git: git)
    case let .atRisk(dirty, ignored):
        // Cancel leaves everything as it was; the forced removal continues from the confirm callback.
        ctx.confirm(worktreeRiskTitle(dirty: dirty), worktreeRiskInfo(ignored: ignored), L10n.deleteAnyway) {
            Task { await removeWorktreeAndTask(id, path: path, branch: branch, ctx: ctx, git: git, runner: runner) }
        }
    case .clean:
        await removeWorktreeAndTask(id, path: path, branch: branch, ctx: ctx, git: git, runner: runner)
    }
}

@MainActor private func removeWorktreeAndTask(_ id: UUID, path: String, branch: String, ctx: ActionContext, git: Git, runner: Runner) async {
    do {
        // The check above asked about losses; the tombstone rename itself never refuses.
        try await removeWorktreeFolder(path, git: git, runner: runner)
    } catch {
        ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription)
        return
    }
    await finishDeletion(id, branch: branch, ctx: ctx, git: git)
}

@MainActor private func finishDeletion(_ id: UUID, branch: String, ctx: ActionContext, git: Git) async {
    ctx.app.perform { $0.deleteTask(id: id) }
    do {
        try await git.deleteBranch(branch)
    } catch {
        ctx.showError(L10n.branchKept(branch), error.localizedDescription)
    }
}

/// What removing a worktree folder would lose; shared by delete and archive (decision #57).
enum WorktreeCheck: Equatable { case missing, clean, atRisk(dirty: Bool, ignored: [String]) }

/// `runner`: the project's machine. Throws when the check itself fails (host down, git error).
/// Reinstallable folders and setup's identical copies of main-folder files are not at risk (`Git.ignoredAtRisk`).
func checkWorktree(_ path: String, git: Git, runner: Runner) async throws -> WorktreeCheck {
    guard try await isDirectory(path, runner: runner) else { return .missing }
    let dirty = try await git.isDirty(path: path)
    var ignored = try await git.ignoredFiles(path: path)
    if !ignored.isEmpty { ignored = try await git.ignoredAtRisk(ignored, worktree: path, top: try await git.toplevel()) }
    return dirty || !ignored.isEmpty ? .atRisk(dirty: dirty, ignored: ignored) : .clean
}

/// `test -d` on the project's machine; 255 means ssh itself failed, not `test`.
func isDirectory(_ path: String, runner: Runner) async throws -> Bool {
    let probe = try await runner.run(["test", "-d", path], "/")
    guard probe.status != 255 else { throw DeletionCheckFailed(message: probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return probe.status == 0
}

@MainActor func worktreeRiskTitle(dirty: Bool) -> String { dirty ? L10n.worktreeDirty : L10n.worktreeIgnored }

/// Up to 5 ignored names (`.env`, local databases), ones missing from the main folder first, so the user sees what goes.
@MainActor func worktreeRiskInfo(ignored: [String]) -> String {
    let shown = ignored.prefix(5).joined(separator: ", ") + (ignored.count > 5 ? ", …" : "")
    return ignored.isEmpty ? L10n.worktreeDirtyInfo : L10n.worktreeIgnoredInfo(shown)
}

private struct DeletionCheckFailed: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
