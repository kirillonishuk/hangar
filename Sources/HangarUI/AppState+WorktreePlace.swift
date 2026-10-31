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

    /// One `git worktree list` for all worktree chats of the project. A failed check (host offline, folder gone) keeps
    /// the last answer, and an unchecked chat falls back to its stored folder as before.
    func checkWorktrees(projectId: UUID) {
        guard worktreeChecks[projectId] == nil, let project = project(projectId), isAvailable(project) else { return }
        let git = git(for: project)
        let local = project.host == nil
        worktreeChecks[projectId] = Task { [weak self] in
            let list = try? await git.worktrees()
            guard let self else { return }
            self.worktreeChecks[projectId] = nil
            var changed: [UUID] = []
            for task in self.state.tasks where task.projectId == projectId && !task.archived {
                guard case .worktree(let path, let branch, _) = task.mode else { continue }
                let place: WorktreePlace
                if let list {
                    place = worktreePlace(path: path, branch: branch, in: list) { local ? realPath($0) == realPath($1) : $0 == $1 }
                } else {
                    guard self.worktreePlaces[task.id] == nil else { continue }
                    place = .inPlace
                }
                if self.worktreePlaces[task.id] != place {
                    self.worktreePlaces[task.id] = place
                    changed.append(task.id)
                }
            }
            guard !changed.isEmpty else { return }
            for id in changed {
                // The main checkout's HEAD may have been loaded through the old folder: not this chat's branch.
                if self.worktreePlaces[id] != .inPlace { self.branchModel.forget(id) }
                self.refreshHead(taskId: id)
            }
            self.didChange?()
        }
    }

    /// Tests: waits until no worktree check runs.
    func worktreeChecksIdle() async {
        while let check = worktreeChecks.values.first { await check.value }
    }

    /// «Обновить путь»: the chat follows its moved copy (decision #122), and its claude conversations are copied to the
    /// new folder's place in claude's projects, so the tabs resume them there. Off the main thread, before any relaunch
    /// asks; a failed copy only means a new conversation with the note (#119), as before.
    /// shortcut: a remote chat's conversations are not copied (they live on the server); copy over ssh if asked.
    func relinkWorktree(_ id: UUID) {
        guard case .moved(let path) = worktreePlaces[id], let task = state.tasks.first(where: { $0.id == id }),
              case .worktree(let old, _, _) = task.mode else { return }
        if project(task.projectId)?.host == nil {
            let leaves = (task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 })
                .filter { $0.kind == .claude && (($0.cwd == old) || $0.cwd.hasPrefix(old + "/")) }
                .compactMap { leaf in validSessionId(leaf.agentSessionId).map { ($0, leaf.cwd, path + leaf.cwd.dropFirst(old.count)) } }
            let configDir = claudeConfigDir
            if !leaves.isEmpty {
                transcriptCopy = Task.detached {
                    for (session, from, to) in leaves {
                        do { try copyClaudeTranscript(id: session, from: from, to: to, configDir: configDir) } catch {
                            uiLog.error("transcript copy \(session, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
        perform { $0.relinkWorktree(taskId: id, to: path) }
        worktreePlaces[id] = .inPlace
        refreshHead(taskId: id)
        didChange?()
    }
}

extension AppState {
    /// Probes the project's repository for the sheets and keeps the answer (not an offline host's: it says nothing).
    func probeRepository(_ project: Project) async -> NewTaskModel.Probe {
        let answer = await NewTaskModel.probe(git(for: project))
        if case .hostOffline = answer.availability {} else { repoProbes[project.id] = answer }
        return answer
    }
}
