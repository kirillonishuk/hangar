import AgentStatus
import Exec
import Foundation
import Git
import Workspace

/// A worktree chat whose copy was moved (`git worktree move`) or deleted: its old folder may sit inside the main
/// checkout, where git answers as the main checkout. Branch, files and changes come only from a checked copy.
extension AppState {
    /// The folder git runs in for this chat: nil while a local copy is unchecked or when it is not in place.
    /// shortcut: a remote copy is used unchecked until its first check answers (no ssh round trip before each load); check first if moved remote copies show up.
    func gitFolder(of id: UUID) -> String? {
        guard let task = state.tasks.first(where: { $0.id == id }), let path = path(of: .task(id)) else { return nil }
        guard case .worktree = task.mode else { return path }
        switch worktreePlaces[id] {
        case .inPlace: return path
        case .moved, .missing: return nil
        case nil:
            checkWorktrees(projectId: task.projectId)
            return project(task.projectId)?.host == nil ? nil : path
        }
    }

    /// The selected chat's copy is not where the chat thinks: what the notice shows.
    var selectedWorktreeProblem: (task: HangarTask, place: WorktreePlace)? {
        guard let task = selectedTask, case .worktree = task.mode, let place = worktreePlaces[task.id], place != .inPlace else { return nil }
        return (task, place)
    }

    /// Checks again (selection, agent done, window focus); the last answer stays shown until the new one.
    func recheckWorktree(of id: UUID) {
        guard let task = state.tasks.first(where: { $0.id == id }), case .worktree = task.mode else { return }
        checkWorktrees(projectId: task.projectId)
    }

    /// One `git worktree list` for all worktree chats of the project (a path that doesn't match is resolved on its
    /// machine once, so a symlinked stored path is not taken for a moved copy). A failed check (host offline, folder
    /// gone) keeps the last answer, and an unchecked chat falls back to its stored folder as before. Asked again while
    /// it runs, it runs once more after.
    func checkWorktrees(projectId: UUID) {
        guard worktreeChecks[projectId] == nil else { worktreeRechecks.insert(projectId); return }
        guard let project = project(projectId), isAvailable(project) else { return }
        let git = git(for: project)
        let local = project.host == nil
        let chats = state.tasks.compactMap { t -> (id: UUID, path: String, branch: String)? in
            guard t.projectId == projectId, !t.archived, case .worktree(let path, let branch, _) = t.mode else { return nil }
            return (t.id, path, branch)
        }
        worktreeChecks[projectId] = Task { [weak self] in
            let list = try? await git.worktrees()
            var places: [UUID: WorktreePlace] = [:]
            if let list {
                for chat in chats {
                    // Local: realpath(3) gives the on-disk case too (a stored path typed in another case is the same folder);
                    // `pwd -P` keeps the typed case, so it is only for a server's paths.
                    places[chat.id] = local
                        ? worktreePlace(path: chat.path, branch: chat.branch, in: list) { realPath($0) == realPath($1) }
                        : await worktreePlace(path: chat.path, branch: chat.branch, in: list) { await git.resolvedPath($0) }
                }
            }
            guard let self else { return }
            self.worktreeChecks[projectId] = nil
            self.apply(places, checked: chats, failed: list == nil)
            if self.worktreeRechecks.remove(projectId) != nil { self.checkWorktrees(projectId: projectId) }
        }
    }

    private func apply(_ places: [UUID: WorktreePlace], checked chats: [(id: UUID, path: String, branch: String)], failed: Bool) {
        var changed: [UUID] = []
        for chat in chats {
            // Relinked or archived meanwhile: this answer is about the old folder.
            guard let task = state.tasks.first(where: { $0.id == chat.id }), !task.archived,
                  case .worktree(chat.path, _, _) = task.mode else { continue }
            let place: WorktreePlace
            if let known = places[chat.id] {
                place = known
            } else {
                guard failed, worktreePlaces[chat.id] == nil else { continue }
                place = .inPlace
            }
            if worktreePlaces[chat.id] != place {
                worktreePlaces[chat.id] = place
                changed.append(chat.id)
            }
        }
        guard !changed.isEmpty else { return }
        for id in changed {
            // The main checkout's HEAD may have been loaded through the old folder: not this chat's branch.
            if worktreePlaces[id] != .inPlace { branchModel.forget(id) }
            refreshHead(taskId: id)
        }
        didChange?()
    }

    /// Tests: waits until no worktree check runs.
    func worktreeChecksIdle() async {
        while let check = worktreeChecks.values.first { await check.value }
    }

    /// «Обновить путь»: the chat follows its moved copy (decision #122). Its claude tabs remember where their
    /// conversations were recorded; each is copied over when the tab next launches (`syncRelinkedTranscript`).
    func relinkWorktree(_ id: UUID) {
        guard case .moved(let path) = worktreePlaces[id] else { return }
        perform { $0.relinkWorktree(taskId: id, to: path) }
        worktreePlaces[id] = .inPlace
        refreshHead(taskId: id)
        didChange?()
    }
}

extension AppState {
    /// Probes the project's repository for the sheets; a remote project keeps a definite answer for next time.
    func probeRepository(_ project: Project) async -> NewTaskModel.Probe? {
        let answer = await NewTaskModel.probe(git(for: project))
        if project.host != nil, let answer {
            switch answer.availability {
            case .notRepository, .noCommits, .ready: repoProbes[project.id] = answer
            default: break
            }
        }
        return answer
    }
}

/// Resumes its continuation once: with the work's answer or, at the timeout, nil.
@MainActor private final class AnswerOnce<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?
    func finish(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// `work`'s answer if it comes within `timeout`, else nil at the timeout (the work goes on, its answer is dropped).
@MainActor func answer<T: Sendable>(within timeout: Duration, _ work: @escaping @MainActor () async -> T?) async -> T? {
    let once = AnswerOnce<T>()
    return await withCheckedContinuation { c in
        once.continuation = c
        Task { @MainActor in once.finish(await work()) }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            once.finish(nil)
        }
    }
}

extension AppState {
    /// A relinked claude tab launches to resume (#122): its conversation is copied to where claude looks from the new
    /// folder — with every turn said in the old folder up to now — on a background thread. true: the launch waits for
    /// it (`onTranscriptSynced` starts it again). Done once, then the mark goes. A launch that won't resume writes
    /// nothing and drops the mark; a failed copy keeps the mark and this launch goes on without it (a new conversation
    /// with the note, #119).
    /// shortcut: a remote tab's conversation lives on the server and is not copied (the mark just goes); copy over ssh if asked.
    func prepareRelinkedTranscript(_ leaf: Leaf, restoring: Bool) -> Bool {
        guard let from = leaf.relinkedFrom else { return false }
        if transcriptSyncs[leaf.id] != nil { return true }
        if transcriptSyncFailed.remove(leaf.id) != nil { return false }
        guard restoring, leaf.kind == .claude, remoteLeafHost(leaf.id) == nil, let id = validSessionId(leaf.agentSessionId) else {
            clearRelinkedFromQuietly(leaf.id)
            return false
        }
        let (leafId, cwd, configDir) = (leaf.id, leaf.cwd, claudeConfigDir)
        transcriptSyncs[leafId] = Task { [weak self] in
            let result = await Task.detached { Result { try syncClaudeTranscript(id: id, recordedIn: from, cwd: cwd, configDir: configDir) } }.value
            guard let self else { return }
            self.transcriptSyncs[leafId] = nil
            switch result {
            case .success(let r):
                uiLog.info("relinked transcript \(id, privacy: .public): \(String(describing: r), privacy: .public)")
                // Relinked again meanwhile: the next launch copies to the newer place.
                if self.leaf(id: leafId)?.cwd == cwd { self.clearRelinkedFromQuietly(leafId) }
            case .failure(let error):
                uiLog.error("relinked transcript \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Consumed by the leaf's next launch; a closed leaf has none.
                if self.leaf(id: leafId) != nil { self.transcriptSyncFailed.insert(leafId) }
            }
            self.onTranscriptSynced?(leafId)
        }
        return true
    }

    /// Tests: waits until no conversation copy runs.
    func transcriptSyncsIdle() async {
        while let sync = transcriptSyncs.values.first { await sync.value }
    }
}
