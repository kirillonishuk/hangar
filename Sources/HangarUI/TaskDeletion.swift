import Exec
import Foundation
import Git
import Workspace

/// «Удалить навсегда» for an archived task. Without `alsoWorktree` nothing on disk is touched (decisions HD-039/HD-042).
/// With it: missing folder → prune; dirty or holding ignored files → ask before forcing; remove the worktree, drop the task, then `branch -d`
/// (an unmerged branch is kept and reported). `runner`: the project's machine — a remote worktree is checked on its server.
/// A check that fails (host down, git error) stops here: guessing "clean" or "missing" could lose files or orphan the worktree.
@MainActor func deleteTaskPermanently(_ id: UUID, alsoWorktree: Bool, ctx: ActionContext, git: Git, runner: Runner = .local) async {
    let app = ctx.app
    guard let task = app.state.tasks.first(where: { $0.id == id }) else { return }
    // A folder and branch another session (open or archived) still uses stay: only the task goes (HD-131).
    guard alsoWorktree, case .worktree(let path, let branch, _) = task.mode, app.state.worktreeSharers(of: task, openOnly: false).isEmpty else {
        app.perform { $0.deleteTask(id: id) }
        return
    }
    let host = app.project(task.projectId)?.host
    // An archive of this folder still moving it aside: after it (then it is simply missing).
    await app.worktreeRemovals.untilMoved(removalKey(host: host, path: path))
    await app.revertProjectStatuslines(host: host, dirs: [StatuslineDir(path: path, name: task.name)])
    let check: WorktreeCheck
    do {
        check = try await checkWorktree(path, git: git, runner: runner)
    } catch {
        ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription)
        return
    }
    switch check {
    case .missing:
        _ = try? await git.pruneWorktrees(unlocking: path)
        await finishDeletion(task, branch: branch, ctx: ctx, git: git)
    case let .atRisk(dirty, ignored, _):
        // Cancel leaves everything as it was; the forced removal continues from the confirm callback — only while the
        // session is still archived (CLI/MCP may restore it meanwhile) and the folder holds no more than was shown (HD-154).
        ctx.confirm(worktreeRiskTitle(dirty: dirty), worktreeRiskInfo(ignored: ignored), L10n.deleteAnyway) {
            Task {
                guard app.state.tasks.contains(where: { $0.id == id && $0.archived }) else { return }
                let now: WorktreeCheck
                do { now = try await checkWorktree(path, git: git, runner: runner) } catch {
                    ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription)
                    return
                }
                guard now.isCovered(by: check), app.state.tasks.contains(where: { $0.id == id && $0.archived }) else {
                    // Something new appeared while the question was open: asked again about what is there now.
                    await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: git, runner: runner)
                    return
                }
                await removeWorktreeAndTask(task, path: path, branch: branch, ctx: ctx, git: git, runner: runner)
            }
        }
    case .clean:
        await removeWorktreeAndTask(task, path: path, branch: branch, ctx: ctx, git: git, runner: runner)
    }
}

/// The check above asked about losses; a failed rename aside keeps the task, and the removal's row offers «Повторить».
@MainActor private func removeWorktreeAndTask(_ task: HangarTask, path: String, branch: String, ctx: ActionContext, git: Git, runner: Runner,
                                              item: UUID? = nil) async {
    let app = ctx.app
    guard app.state.tasks.contains(where: { $0.id == task.id }), app.state.worktreeSharers(of: task, openOnly: false).isEmpty else {
        if let item { app.worktreeRemovals.finish(item) }
        return
    }
    let id = item ?? app.worktreeRemovals.begin(name: task.name, path: path, local: runner.isLocal)
    let failure = await app.removeWorktree(path, name: task.name, host: app.project(task.projectId)?.host, git: git, runner: runner, item: id) {
        Task { await removeWorktreeAndTask(task, path: path, branch: branch, ctx: ctx, git: git, runner: runner, item: id) }
    }
    guard failure == nil else { return }
    await finishDeletion(task, branch: branch, ctx: ctx, git: git)
}

/// The branch stays while another session of the project keeps it (an archived one restores onto it).
@MainActor private func finishDeletion(_ task: HangarTask, branch: String, ctx: ActionContext, git: Git) async {
    let keepers = ctx.app.state.branchKeepers(of: task)
    ctx.app.perform { $0.deleteTask(id: task.id) }
    guard keepers.isEmpty else { return }
    do {
        try await git.deleteBranch(branch)
    } catch {
        ctx.showError(L10n.branchKept(branch), error.localizedDescription)
    }
}

/// What removing a worktree folder would lose; shared by delete and archive (decision HD-057).
enum WorktreeCheck: Equatable {
    /// `changes`: `Git.dirtyFingerprint` — which uncommitted paths, and their content, the check saw.
    case missing, clean, atRisk(dirty: Bool, ignored: [String], changes: [String: String] = [:])

    /// Nothing here at risk beyond `accepted` (HD-154): becoming dirty, a new or further changed uncommitted path, or a new
    /// ignored path is not covered; the same or less is.
    func isCovered(by accepted: WorktreeCheck?) -> Bool {
        guard case let .atRisk(dirty, ignored, changes) = self else { return true }
        guard case let .atRisk(okDirty, okIgnored, okChanges)? = accepted else { return false }
        return (!dirty || okDirty) && Set(ignored).isSubset(of: okIgnored) && changes.allSatisfy { okChanges[$0.key] == $0.value }
    }
}

/// `runner`: the project's machine. Throws when the check itself fails (host down, git error).
/// Reinstallable folders and setup's identical copies of main-folder files are not at risk (`Git.ignoredAtRisk`).
func checkWorktree(_ path: String, git: Git, runner: Runner) async throws -> WorktreeCheck {
    guard try await isDirectory(path, runner: runner) else { return .missing }
    let changes = try await git.dirtyFingerprint(path: path)
    let dirty = !changes.isEmpty
    var ignored = try await git.ignoredFiles(path: path)
    if !ignored.isEmpty { ignored = try await git.ignoredAtRisk(ignored, worktree: path, top: try await git.toplevel()) }
    return dirty || !ignored.isEmpty ? .atRisk(dirty: dirty, ignored: ignored, changes: changes) : .clean
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
