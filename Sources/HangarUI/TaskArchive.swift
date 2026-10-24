import Exec
import Foundation
import Git
import Workspace

/// Archive removes a worktree task's folder and keeps its branch; restore checks the branch out again (decision #NN-archive).
enum ArchiveOutcome: Equatable {
    case archived(worktreeRemoved: Bool)
    /// Archived, but `worktree remove` failed: the folder is still there (restore just unarchives).
    case worktreeKept(String)
    /// Nothing changed: removing the folder would lose these; ask, then call again with `force`.
    case atRisk(dirty: Bool, ignored: [String])
    /// Nothing changed (host down, git error, task gone).
    case failed(String)
}

enum RestoreOutcome: Equatable {
    case restored
    /// Nothing changed: the kept branch is gone, the worktree can't be re-created.
    case branchMissing(String)
    case failed(String)
}

extension AppState {
    /// The check runs before anything changes, so an offline host or a failed check archives nothing.
    /// Archiving first stops the task's tabs (and kills remote tmux sessions) before the folder goes.
    func archiveRemovingWorktree(_ id: UUID, force: Bool) async -> ArchiveOutcome {
        guard let task = state.tasks.first(where: { $0.id == id && !$0.archived }) else { return .failed("task not found") }
        guard case .worktree(let path, _, _) = task.mode, let project = project(task.projectId) else {
            archive(taskId: id)
            return .archived(worktreeRemoved: false)
        }
        let git = git(for: project), check: WorktreeCheck
        do {
            check = try await checkWorktree(path, git: git, runner: runner(for: project))
        } catch {
            return .failed(error.localizedDescription)
        }
        if case let .atRisk(dirty, ignored) = check, !force { return .atRisk(dirty: dirty, ignored: ignored) }
        guard state.tasks.contains(where: { $0.id == id && !$0.archived }) else { return .failed("task not found") }
        archive(taskId: id)
        do {
            if check == .missing { try await git.pruneWorktrees() } else { try await git.removeWorktree(path: path, force: check != .clean) }
        } catch {
            return .worktreeKept(error.localizedDescription)
        }
        return .archived(worktreeRemoved: true)
    }

    /// A worktree folder that is gone (removed by archive) is added back from its branch first; tabs reopen on unarchive.
    /// `withoutWorktree`: the branch is gone and the user agreed to restore the task in the project folder.
    func restoreFromArchive(_ id: UUID, withoutWorktree: Bool = false) async -> RestoreOutcome {
        guard let task = state.tasks.first(where: { $0.id == id && $0.archived }) else { return .restored }
        if withoutWorktree {
            perform { $0.detachWorktree(taskId: id) }
        } else if case .worktree(let path, let branch, _) = task.mode, let project = project(task.projectId) {
            let git = git(for: project)
            do {
                if !(try await isDirectory(path, runner: runner(for: project))) {
                    guard try await git.hasBranch(branch) else { return .branchMissing(branch) }
                    // A folder deleted by hand leaves a registration that blocks `worktree add`.
                    try await git.pruneWorktrees()
                    try await git.addWorktree(path: path, existingBranch: branch)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard state.tasks.contains(where: { $0.id == id && $0.archived }) else { return .restored }
        restore(taskId: id)
        return .restored
    }
}

/// Menu, ⌘⇧W: archive; at risk → the delete flow's confirmation, then forced. The undo toast shows once archived.
@MainActor func archiveTask(_ id: UUID, ctx: ActionContext, force: Bool = false) async {
    switch await ctx.app.archiveRemovingWorktree(id, force: force) {
    case .archived: ctx.didArchive(id)
    case .worktreeKept(let details):
        ctx.didArchive(id)
        ctx.showError(L10n.worktreeRemoveFailed, details)
    case let .atRisk(dirty, ignored):
        ctx.confirm(worktreeRiskTitle(dirty: dirty), worktreeRiskInfo(ignored: ignored), L10n.archiveAnyway) {
            Task { await archiveTask(id, ctx: ctx, force: true) }
        }
    case .failed(let details): ctx.showError(L10n.archiveFailed, details)
    }
}

/// Menu «Восстановить» and the undo toast. `reselect`: the toast's task was the selected one.
@MainActor func restoreArchivedTask(_ id: UUID, ctx: ActionContext, reselect: Bool = false, withoutWorktree: Bool = false) async {
    switch await ctx.app.restoreFromArchive(id, withoutWorktree: withoutWorktree) {
    case .restored: if reselect { ctx.app.select(taskId: id) }
    case .branchMissing(let branch):
        ctx.confirm(L10n.branchGone(branch), L10n.branchGoneInfo, L10n.restoreWithoutWorktree) {
            Task { await restoreArchivedTask(id, ctx: ctx, reselect: reselect, withoutWorktree: true) }
        }
    case .failed(let details): ctx.showError(L10n.restoreFailed, details)
    }
}
