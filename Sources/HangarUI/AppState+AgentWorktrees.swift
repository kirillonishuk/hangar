import AgentStatus
import Exec
import Foundation
import Git
import Workspace

/// Worktrees agents make and enter on their own (decision HD-134). Hangar adapts to them and only offers actions: nothing
/// on disk changes unless the user clicks «Удалить копию…» or «Скрыть от git локально…».
extension AppState {
    /// How this project's paths compare with git's list: real paths on this Mac, as written on a server.
    func pathNormalizer(_ project: Project) -> @Sendable (String) -> String {
        if project.host == nil { return { realPath($0) } }
        return { $0 }
    }

    /// A hook of the tab's own agent said where it works. A new place asks git once (the worktree list), never polls.
    /// shortcut: cwds of closed tabs stay in memory until quit (a few strings); prune if it ever matters.
    func noteAgentCwd(leaf leafId: UUID, _ cwd: String) {
        guard agentCwds[leafId] != cwd, let taskId = location(ofLeaf: leafId)?.task, !isFreeChatTask(taskId),
              let task = state.tasks.first(where: { $0.id == taskId }) else { return }
        agentCwds[leafId] = cwd
        if agentElsewhere[taskId] == nil, cwd == path(of: .task(taskId)) { return }  // at home: nothing to ask
        checkWorktrees(projectId: task.projectId)
    }

    /// A project's worktree list arrived (`checkWorktrees`): recorded branches follow git, agents' places are updated.
    func took(_ list: [WorktreeEntry]?, projectId: UUID) {
        guard let list else {
            if worktreeLists[projectId] == nil { worktreeLists[projectId] = [] }  // not a repository: not asked again on appear
            return
        }
        guard let project = project(projectId) else { return }
        if worktreeLists[projectId] != list {
            worktreeLists[projectId] = list
            checkIgnored(projectId: projectId, list: list)
        }
        let normalize = pathNormalizer(project)
        // An agent's `branch -m` / `checkout -b`: the chat's branch is the one git has there now (archive, restore, lookups).
        for task in state.tasks where task.projectId == projectId && !task.archived {
            guard case .worktree(let path, let branch, _) = task.mode, worktreePlaces[task.id] == .inPlace,
                  let now = registeredBranch(at: path, in: list, normalize: normalize), now != branch else { continue }
            perform { $0.setWorktreeBranch(taskId: task.id, now) }
        }
        updateAgentPlaces(projectId: projectId, list: list, normalize: normalize)
    }

    private func updateAgentPlaces(projectId: UUID, list: [WorktreeEntry], normalize: (String) -> String) {
        var changed = false
        for task in state.tasks where task.projectId == projectId {
            var found: WorktreeEntry?
            if !task.archived, let folder = path(of: .task(task.id)) {
                let agents = task.tabs.flatMap(\.root.leaves).filter { $0.kind == .claude || $0.kind == .codex }
                found = agents.compactMap { self.agentCwds[$0.id] }
                    .compactMap { otherWorktree(cwd: $0, chatFolder: folder, in: list, normalize: normalize) }.first
            }
            if agentElsewhere[task.id] != found {
                agentElsewhere[task.id] = found
                changed = true
            }
        }
        if changed { didChange?() }
    }

    /// The selected chat's agent works in another copy and the bar was not hidden for that copy.
    var selectedAgentElsewhere: (task: HangarTask, entry: WorktreeEntry)? {
        guard let task = selectedTask, let entry = agentElsewhere[task.id],
              !hiddenAgentPlaces.contains(agentPlaceKey(task.id, entry.path)) else { return nil }
        return (task, entry)
    }

    func agentPlaceKey(_ task: UUID, _ path: String) -> String { task.uuidString + "|" + path }

    /// «Скрыть»: this chat, this copy; until quit.
    /// shortcut: in memory only — after a restart the agent starts in the chat's own folder anyway; persist if it nags.
    func hideAgentPlace(_ task: UUID) {
        guard let entry = agentElsewhere[task] else { return }
        hiddenAgentPlaces.insert(agentPlaceKey(task, entry.path))
        didChange?()
    }

    /// «Сделать чатом этой копии»: the chat becomes the worktree chat of that copy — toolbar, Changes, Files, new tabs
    /// and resume follow; its claude conversations are copied over at their next launch, as on «Обновить путь» (HD-122).
    /// Running terminals and every file stay as they are.
    func adoptAgentWorktree(_ id: UUID) {
        guard let entry = agentElsewhere[id], let branch = entry.branch,
              let task = state.tasks.first(where: { $0.id == id }), let project = project(task.projectId) else { return }
        let base: String
        if case .worktree(_, _, let b) = task.mode { base = b } else {
            base = project.lastBaseBranch ?? worktreeLists[project.id]?.first?.branch ?? branch
        }
        perform { $0.adoptWorktree(taskId: id, path: entry.path, branch: branch, base: base) }
        worktreePlaces[id] = .inPlace
        agentElsewhere[id] = nil
        branchModel.forget(id)
        refreshHead(taskId: id)
        didChange?()
    }

    /// Linked worktrees of the project no chat (open or archived) uses: an agent's `.claude/worktrees/*`, or by hand.
    func spareWorktrees(of projectId: UUID) -> [WorktreeEntry] {
        guard let list = worktreeLists[projectId], list.count > 1, let project = project(projectId) else { return [] }
        let used = state.tasks.compactMap { t -> String? in
            guard t.projectId == projectId, case .worktree(let path, _, _) = t.mode else { return nil }
            return path
        }
        return unusedWorktrees(list, used: used, normalize: pathNormalizer(project))
    }

    /// «Открыть чатом»: a new worktree chat at that copy; no git command, no setup (the copy is ready as it is).
    @discardableResult
    func openSpareWorktree(_ entry: WorktreeEntry, projectId: UUID) -> UUID? {
        guard let branch = entry.branch, let project = project(projectId) else { return nil }
        let base = project.lastBaseBranch ?? worktreeLists[projectId]?.first?.branch ?? branch
        let id = createTask(projectId: projectId, name: branch, firstMessage: "", mode: .worktree(path: entry.path, branch: branch, base: base)).task
        worktreePlaces[id] = .inPlace
        return id
    }

    /// Nested worktrees of the same repository inside `root` (relative): separate checkouts the search skips.
    func nestedCheckouts(in root: String) -> [String] {
        var out: [String] = []
        for list in worktreeLists.values {
            for rel in nestedWorktrees(in: root, list: list, normalize: { realPath($0) }) where !out.contains(rel) { out.append(rel) }
        }
        return out
    }

    /// The main checkout's git (the repository's top level: nested paths and `info/exclude` lines are relative to it).
    private func topGit(_ projectId: UUID) -> Git? {
        guard let project = project(projectId), let top = worktreeLists[projectId]?.first?.path else { return nil }
        return Git(repo: top, runner: runner(for: project))
    }

    /// Worktrees inside the repository that git doesn't ignore (they show in `git add -A`, search, formatters): one
    /// `check-ignore` when the list changed and has nested ones. Reads only.
    func checkIgnored(projectId: UUID, list: [WorktreeEntry]) {
        guard let project = project(projectId), let top = list.first?.path, let git = topGit(projectId) else { return }
        let nested = nestedWorktrees(in: top, list: list, normalize: pathNormalizer(project))
        guard !nested.isEmpty else {
            if unignoredCopies[projectId] != nil { unignoredCopies[projectId] = nil }
            return
        }
        Task { [weak self] in
            let unignored = (try? await git.notIgnored(nested)) ?? []
            guard let self, self.worktreeLists[projectId] == list else { return }
            let value = unignored.isEmpty ? nil : unignored
            if self.unignoredCopies[projectId] != value { self.unignoredCopies[projectId] = value }
        }
    }

    /// «Скрыть от git локально»: appends the lines the user was shown to the repository's `info/exclude` (local, never
    /// committed) — the only write here, and only on that click. nil — done; else why not.
    func hideCopiesFromGit(_ projectId: UUID) async -> String? {
        guard let copies = unignoredCopies[projectId], let git = topGit(projectId), let list = worktreeLists[projectId] else { return nil }
        do {
            try await git.appendToExclude(excludeLines(for: copies))
        } catch {
            return error.localizedDescription
        }
        checkIgnored(projectId: projectId, list: list)
        return nil
    }
}

/// The menu's «Скрыть от git локально…»: asks with the exact lines, then appends them.
@MainActor func hideWorktreesFromGit(_ projectId: UUID, ctx: ActionContext) {
    guard let copies = ctx.app.unignoredCopies[projectId] else { return }
    ctx.confirm(L10n.hideFromGitTitle, L10n.hideFromGitInfo(excludeLines(for: copies).joined(separator: "\n")), L10n.hideFromGitButton) {
        Task {
            if let failure = await ctx.app.hideCopiesFromGit(projectId) { ctx.showError(L10n.hideFromGitFailed, failure) }
        }
    }
}

/// «Удалить копию…»: always asks; then the same checks as archive (uncommitted changes, ignored files) and the same
/// removal (HD-059, HD-132). The branch stays. A locked copy (the agent's `git worktree lock`) is never offered.
@MainActor func removeSpareWorktree(_ entry: WorktreeEntry, projectId: UUID, ctx: ActionContext, asked: Bool = false) async {
    let app = ctx.app
    guard let project = app.project(projectId), !entry.locked else { return }
    guard asked else {
        ctx.confirm(L10n.removeCopyTitle(abbreviatedHomePath(entry.path)), entry.branch.map(L10n.removeCopyInfo) ?? L10n.removeCopyInfoDetached,
                    L10n.removeCopyButton) {
            Task { await removeSpareWorktree(entry, projectId: projectId, ctx: ctx, asked: true) }
        }
        return
    }
    let git = app.git(for: project), runner = app.runner(for: project)
    let check: WorktreeCheck
    do {
        check = try await checkWorktree(entry.path, git: git, runner: runner)
    } catch {
        ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription)
        return
    }
    // The shared removal (HD-132): progress and «Повторить» over the chat area; a failure stays there, not in a dialog.
    func remove() async {
        if check == .missing {
            do { try await git.pruneWorktrees() } catch { ctx.showError(L10n.worktreeRemoveFailed, error.localizedDescription) }
        } else {
            let item = app.worktreeRemovals.begin(name: (entry.path as NSString).lastPathComponent, path: entry.path, local: runner.isLocal)
            @MainActor func attempt() async {
                await app.removeWorktree(entry.path, name: "", host: project.host, git: git, runner: runner, item: item) {
                    Task { await attempt(); app.checkWorktrees(projectId: projectId) }
                }
            }
            await attempt()
        }
        app.checkWorktrees(projectId: projectId)
    }
    if case let .atRisk(dirty, ignored) = check {
        ctx.confirm(worktreeRiskTitle(dirty: dirty), worktreeRiskInfo(ignored: ignored), L10n.deleteAnyway) { Task { await remove() } }
    } else {
        await remove()
    }
}
