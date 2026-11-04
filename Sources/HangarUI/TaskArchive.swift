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
    /// Restored (or a session opened in its folder) before the folder went: nothing removed, nothing to report.
    case undone
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
    /// Its open sub-sessions follow a parent into the archive, each by the same rules (#128); one at risk stays open.
    /// A worktree another open session still works in (a sub-chat shares its parent's, #131) is left alone: only the last
    /// session to leave it checks and removes it; sub-sessions archived along with it count as leaving.
    func archiveRemovingWorktree(_ id: UUID, force: Bool) async -> ArchiveOutcome {
        guard let task = state.tasks.first(where: { $0.id == id && !$0.archived }) else { return .failed("session not found") }
        let descendants = state.withSubSessions([task], expandedOnly: false).dropFirst().map(\.task.id)
        let outcome = await archiveOne(id, force: force, leaving: Set(descendants))
        switch outcome {
        case .archived, .worktreeKept:
            // Parents first; one that left with its parent's worktree is already archived, one whose parent stayed (at risk) stays too.
            for child in descendants {
                guard let t = state.tasks.first(where: { $0.id == child && !$0.archived }),
                      state.tasks.first(where: { $0.id == t.parentTaskId })?.archived != false else { continue }
                _ = await archiveOne(child, force: force, leaving: Set(descendants))
            }
        case .atRisk, .failed, .undone: break
        }
        return outcome
    }

    /// `leaving`: sessions about to be archived with this one; those sharing its worktree go with it (stopped before the
    /// check, back again if it does not go ahead).
    private func archiveOne(_ id: UUID, force: Bool, leaving: Set<UUID>) async -> ArchiveOutcome {
        // A removal of this folder still moving it aside (archived, restored, archived again): after it.
        if let t = state.tasks.first(where: { $0.id == id }), case .worktree(let path, _, _) = t.mode, let p = project(t.projectId) {
            await worktreeRemovals.untilMoved(removalKey(host: p.host, path: path))
        }
        guard let task = state.tasks.first(where: { $0.id == id && !$0.archived }) else { return .failed("session not found") }
        guard case .worktree(let path, _, _) = task.mode, let project = project(task.projectId) else {
            archive(taskId: id)
            return .archived(worktreeRemoved: false)
        }
        let sharers = state.worktreeSharers(of: task, openOnly: true).map(\.id)
        // Someone stays in the folder: it is theirs now; no check, nothing removed, the status line override stays.
        if sharers.contains(where: { !leaving.contains($0) }) {
            archive(taskId: id)
            return .archived(worktreeRemoved: false)
        }
        // Offline: the check can't run; stopping first would only queue kills for tabs that stay.
        if let host = project.host, remote.hosts[host]?.state != .connected { return .failed(RemoteHostError.notConnected(host).description) }
        let group = [id] + sharers
        let selected = group.first { state.selectedTaskId == $0 }
        let runner = runner(for: project)
        let item = worktreeRemovals.begin(name: task.name, path: path, local: runner.isLocal)
        var kills: [Task<Void, Never>] = []
        for t in group {
            archive(taskId: t)
            kills += lastKills
        }
        for kill in kills { await kill.value }
        // Closed terminals' shells and agents leave the folder before it is checked (only waited for, never killed).
        if runner.isLocal { await waitForProcessesToLeave(path) }
        // Hangar's status line override is its own file in the worktree: out first, or it would count as at risk.
        await revertProjectStatuslines(host: project.host, dirs: [StatuslineDir(path: path, name: task.name)])
        let git = git(for: project), check: WorktreeCheck
        do {
            check = try await checkWorktree(path, git: git, runner: runner)
        } catch {
            worktreeRemovals.finish(item)
            unarchiveKept(group, selected: selected)
            return .failed(error.localizedDescription)
        }
        if case let .atRisk(dirty, ignored) = check, !force {
            worktreeRemovals.finish(item)
            unarchiveKept(group, selected: selected)
            return .atRisk(dirty: dirty, ignored: ignored)
        }
        guard state.tasks.contains(where: { $0.id == id && $0.archived }) else {
            worktreeRemovals.finish(item)
            return .undone
        }
        // «Сессии» shows the closed session's +N −M; afterwards only the branch is left.
        if check != .missing, case .worktree(_, _, let base) = task.mode,
           let stat = try? await Git(repo: path, runner: runner).diffStat(base: base) {
            perform { s in for t in group { s.setArchivedChanges(id: t, LineChanges(added: stat.added, deleted: stat.deleted)) } }
        }
        // Restored while measuring («Сессии» already lists it as closed), or a session opened in this folder meanwhile:
        // the folder belongs to an open session again.
        guard group.allSatisfy({ t in state.tasks.contains { $0.id == t && $0.archived } }),
              state.worktreeSharers(of: task, openOnly: true).isEmpty else {
            worktreeRemovals.finish(item)
            return .undone
        }
        if check == .missing {
            worktreeRemovals.finish(item)
            do { try await git.pruneWorktrees(unlocking: path) } catch { return .worktreeKept(error.localizedDescription) }
            return .archived(worktreeRemoved: true)
        }
        let failure = await removeWorktree(path, name: task.name, host: project.host, git: git, runner: runner, item: item) { [weak self] in
            Task { await self?.retryArchiveRemoval(id, force: force, item: item) }
        }
        return failure.map { .worktreeKept($0) } ?? .archived(worktreeRemoved: true)
    }

    /// «Повторить» on a failed rename aside: only while the folder is still nobody's (the session archived, no open one
    /// in it); without `force` it is checked again, and new changes keep it (the item says so).
    private func retryArchiveRemoval(_ id: UUID, force: Bool, item: UUID) async {
        guard let task = state.tasks.first(where: { $0.id == id && $0.archived }), case .worktree(let path, _, _) = task.mode,
              let project = project(task.projectId), state.worktreeSharers(of: task, openOnly: true).isEmpty else {
            worktreeRemovals.finish(item)
            return
        }
        let git = git(for: project), runner = runner(for: project)
        let retry: @MainActor () -> Void = { [weak self] in Task { await self?.retryArchiveRemoval(id, force: force, item: item) } }
        if !force {
            do {
                if case .atRisk = try await checkWorktree(path, git: git, runner: runner) {
                    worktreeRemovals.fail(item, L10n.removeCopyChanged, retry: retry)
                    return
                }
            } catch {
                worktreeRemovals.fail(item, error.localizedDescription, retry: retry)
                return
            }
        }
        guard state.tasks.contains(where: { $0.id == id && $0.archived }), state.worktreeSharers(of: task, openOnly: true).isEmpty else {
            worktreeRemovals.finish(item)
            return
        }
        await removeWorktree(path, name: task.name, host: project.host, git: git, runner: runner, item: item, retry: retry)
    }

    /// The archive didn't go ahead: the tasks are back (one that something else unarchived meanwhile is left as it is).
    /// `selected`: the one of them that was selected.
    private func unarchiveKept(_ ids: [UUID], selected: UUID?) {
        for id in ids where state.tasks.contains(where: { $0.id == id && $0.archived }) {
            let leaves = Set(state.tasks.filter { $0.id == id }.flatMap { $0.tabs.flatMap(\.root.leaves).map(\.id) + [$0.drawer.leaf?.id].compactMap { $0 } })
            // A kill that failed waits for the reconnect; these tabs are live again.
            for host in pendingKills.keys { pendingKills[host]?.subtract(leaves) }
            restore(taskId: id)
            if selected == id { select(taskId: id) }
        }
        if let first = ids.first { syncStatuslines(task: first) }
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
            // Mid rename aside: the folder is either there or gone, never half (revive then adds it back from the branch).
            await worktreeRemovals.untilMoved(removalKey(host: project.host, path: path))
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
    // The removal's own row shows the failure with «Повторить» (#132).
    case .worktreeKept: ctx.didArchive(id)
    case let .atRisk(dirty, ignored):
        ctx.confirm(worktreeRiskTitle(dirty: dirty), worktreeRiskInfo(ignored: ignored), L10n.archiveAnyway) {
            Task { await archiveTask(id, ctx: ctx, force: true) }
        }
    case .failed(let details): ctx.showError(L10n.archiveFailed, details)
    case .undone: break
    }
}

/// Menu «Восстановить» and the undo toast. `reselect`: the toast's task was the selected one.
@MainActor func restoreArchivedTask(_ id: UUID, ctx: ActionContext, reselect: Bool = false, withoutWorktree: Bool = false) async {
    let outcome = await ctx.app.restoreFromArchive(id, withoutWorktree: withoutWorktree)
    if case .restored = outcome { ctx.app.syncStatuslines(task: id) }
    if case .restoredKeeping = outcome { ctx.app.syncStatuslines(task: id) }
    switch outcome {
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
