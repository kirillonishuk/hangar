import Exec
import Foundation
import Git
import Workspace

/// Archive removes a worktree task's folder and keeps its branch; restore checks the branch out again (decision #57).
enum ArchiveOutcome: Equatable {
    case archived(worktreeRemoved: Bool)
    /// Archived, but moving the folder away failed: the folder is still there (restore just unarchives).
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
    /// Restored; a non-empty folder without `.git` that sat at the path was kept under this name (never deleted).
    case restoredKeeping(String)
}

extension AppState {
    /// The task's tabs stop first (archived: surfaces close, remote tmux sessions are killed and awaited), so nothing
    /// writes into the folder while it is checked. At risk without `force`, or a failed check (host down, git error):
    /// unarchived again, its tabs relaunch lazily as after a restart.
    func archiveRemovingWorktree(_ id: UUID, force: Bool) async -> ArchiveOutcome {
        guard let task = state.tasks.first(where: { $0.id == id && !$0.archived }) else { return .failed("session not found") }
        guard case .worktree(let path, _, _) = task.mode, let project = project(task.projectId) else {
            archive(taskId: id)
            return .archived(worktreeRemoved: false)
        }
        // Offline: the check can't run; stopping first would only queue kills for tabs that stay.
        if let host = project.host, remote.hosts[host]?.state != .connected { return .failed(RemoteHostError.notConnected(host).description) }
        let wasSelected = state.selectedTaskId == id
        archive(taskId: id)
        for kill in lastKills { await kill.value }
        let git = git(for: project), check: WorktreeCheck
        do {
            check = try await checkWorktree(path, git: git, runner: runner(for: project))
        } catch {
            unarchiveKept(id, wasSelected: wasSelected)
            return .failed(error.localizedDescription)
        }
        if case let .atRisk(dirty, ignored) = check, !force {
            unarchiveKept(id, wasSelected: wasSelected)
            return .atRisk(dirty: dirty, ignored: ignored)
        }
        guard state.tasks.contains(where: { $0.id == id && $0.archived }) else { return .failed("session not found") }
        // «Сессии» shows the closed session's +N −M; afterwards only the branch is left.
        if check != .missing, case .worktree(_, _, let base) = task.mode,
           let stat = try? await Git(repo: path, runner: runner(for: project)).diffStat(base: base) {
            perform { $0.setArchivedChanges(id: id, LineChanges(added: stat.added, deleted: stat.deleted)) }
        }
        do {
            if check == .missing { try await git.pruneWorktrees() } else { try await removeWorktreeFolder(path, git: git, runner: runner(for: project)) }
        } catch {
            return .worktreeKept(error.localizedDescription)
        }
        return .archived(worktreeRemoved: true)
    }

    /// The archive didn't go ahead: the task is back (still archived only if something else unarchived it meanwhile).
    private func unarchiveKept(_ id: UUID, wasSelected: Bool) {
        guard state.tasks.contains(where: { $0.id == id && $0.archived }) else { return }
        let leaves = Set(state.tasks.filter { $0.id == id }.flatMap { $0.tabs.flatMap(\.root.leaves).map(\.id) + [$0.drawer.leaf?.id].compactMap { $0 } })
        // A kill that failed waits for the reconnect; these tabs are live again.
        for host in pendingKills.keys { pendingKills[host]?.subtract(leaves) }
        restore(taskId: id)
        if wasSelected { select(taskId: id) }
    }

    /// A worktree folder that is gone (removed by archive) is added back from its branch first (`reviveWorktree`); tabs reopen on unarchive.
    /// `withoutWorktree`: the branch is gone and the user agreed to restore the task in the project folder.
    func restoreFromArchive(_ id: UUID, withoutWorktree: Bool = false) async -> RestoreOutcome {
        guard let task = state.tasks.first(where: { $0.id == id && $0.archived }) else { return .restored }
        if withoutWorktree {
            perform { $0.detachWorktree(taskId: id) }
            guard state.tasks.contains(where: { $0.id == id && $0.archived }) else { return .restored }
            restore(taskId: id, fresh: true)
            return .restored
        } else if case .worktree(let path, let branch, _) = task.mode, let project = project(task.projectId) {
            let git = git(for: project), runner = runner(for: project)
            do {
                let outcome = try await reviveWorktree(path, branch: branch, git: git, runner: runner)
                switch outcome {
                case .restored, .restoredKeeping: break
                case .branchMissing, .failed: return outcome
                }
                guard state.tasks.contains(where: { $0.id == id && $0.archived }) else { return outcome }
                restore(taskId: id)
                return outcome
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
    case .restoredKeeping(let orphan):
        if reselect { ctx.app.select(taskId: id) }
        ctx.showError(L10n.orphanKept, orphan)
    case .branchMissing(let branch):
        ctx.confirm(L10n.branchGone(branch), L10n.branchGoneInfo, L10n.restoreWithoutWorktree) {
            Task { await restoreArchivedTask(id, ctx: ctx, reselect: reselect, withoutWorktree: true) }
        }
    case .failed(let details): ctx.showError(L10n.restoreFailed, details)
    }
}
