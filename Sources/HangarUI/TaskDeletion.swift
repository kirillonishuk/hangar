import Foundation
import Git
import Workspace

/// «Удалить навсегда» for an archived task. Without `alsoWorktree` nothing on disk is touched (decisions #39/#42).
/// With it: missing folder → prune; dirty or holding ignored files → ask before forcing; remove the worktree, drop the task, then `branch -d`
/// (an unmerged branch is kept and reported).
@MainActor func deleteTaskPermanently(_ id: UUID, alsoWorktree: Bool, ctx: ActionContext, git: Git) async {
    let app = ctx.app
    guard let task = app.state.tasks.first(where: { $0.id == id }) else { return }
    guard alsoWorktree, case .worktree(let path, let branch, _) = task.mode else {
        app.perform { $0.deleteTask(id: id) }
        return
    }
    if !folderExists(path) {
        _ = try? await git.pruneWorktrees()
        await finishDeletion(id, branch: branch, ctx: ctx, git: git)
        return
    }
    let dirty = (try? await git.isDirty(path: path)) ?? false
    let ignored = (try? await git.ignoredFiles(path: path)) ?? []
    if dirty || !ignored.isEmpty {
        // Cancel leaves everything as it was; the forced removal continues from the confirm callback.
        let shown = ignored.prefix(5).joined(separator: ", ") + (ignored.count > 5 ? ", …" : "")
        let info = ignored.isEmpty ? L10n.worktreeDirtyInfo : L10n.worktreeIgnoredInfo(shown)
        ctx.confirm(dirty ? L10n.worktreeDirty : L10n.worktreeIgnored, info, L10n.deleteAnyway) {
            Task { await removeWorktreeAndTask(id, path: path, branch: branch, force: true, ctx: ctx, git: git) }
        }
        return
    }
    await removeWorktreeAndTask(id, path: path, branch: branch, force: false, ctx: ctx, git: git)
}

@MainActor private func removeWorktreeAndTask(_ id: UUID, path: String, branch: String, force: Bool, ctx: ActionContext, git: Git) async {
    do {
        try await git.removeWorktree(path: path, force: force)
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
