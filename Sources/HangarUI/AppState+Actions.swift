import ControlServer
import Exec
import Foundation
import Workspace

/// How long a stopped action gets after ⌃C before its terminal is closed (hang-up) anyway.
let actionStopGrace: TimeInterval = 3

/// A launch of an action leaf (#131): only a run that was asked for (its command is the prompt), a retry of a launch that
/// never ran, or a remote reattach (its tmux session may still run it); never a restore or a plain ↩ relaunch.
func actionLaunches(_ context: LaunchContext, remote: Bool) -> Bool {
    switch context {
    case .created(let prompt): prompt != nil
    case .relaunch(_, let code): code == nil
    case .reattach: true
    case .restored: remote
    }
}

/// An action that ended by ⌃C or a hang-up (130, 129, 143 or no code) was stopped, not failed.
func actionWasStopped(_ code: Int32) -> Bool { code < 0 || code == 129 || code == 130 || code == 143 }

/// Why an action did not start (CLI/MCP get it as text).
enum ActionRunError: Error, Equatable {
    case noAction(String)
    case needsApproval(String)
    case notAvailable
    /// The action's folder is not in this chat's checkout.
    case missingFolder(String)
}

/// Project actions (#131): the list of a chat, runs, restarts and stops.
extension AppState {
    /// The chat's folder when it is a project's chat (not a chat without a project, not a host's terminal).
    func actionsFolder(of task: HangarTask) -> String? {
        guard !isOutsideProjects(task), project(task.projectId) != nil else { return nil }
        return path(of: .task(task.id))
    }

    /// Settings first, then `.hangar/actions.json` as last read for the chat's folder.
    func actions(of task: HangarTask) -> [ResolvedAction] {
        guard let folder = actionsFolder(of: task), let project = project(task.projectId) else { return [] }
        return mergedActions(settings: project.actions ?? [], repo: repoActions[folder]?.actions ?? [], hidden: project.hiddenActions ?? [])
    }

    /// Reads the chat's `.hangar/actions.json` again (over ssh for a remote project). A missing file is no actions; a host
    /// that cannot be reached keeps what was read before.
    @discardableResult
    func loadRepoActions(_ task: HangarTask) async -> RepoActions {
        guard let folder = actionsFolder(of: task), let project = project(task.projectId) else { return RepoActions() }
        return await loadRepoActions(folder: folder, project: project)
    }

    func loadRepoActions(folder: String, project: Project) async -> RepoActions {
        guard let result = try? await runner(for: project).run(["cat", repoActionsFile], folder) else {
            return repoActions[folder] ?? RepoActions()
        }
        let read = parseRepoActions(result.status == 0 ? Data(result.stdout.utf8) : nil)
        if repoActions[folder] != read { repoActions[folder] = read }
        return read
    }

    /// Suggestions for «Добавить действие» (Project Settings): two runs in `folder` (over ssh for a remote project) —
    /// the root's files, then the workspace packages' package.json. Only when the picker opens; nothing on failure.
    func discoverActions(folder: String, project: Project) async -> [ActionSuggestionGroup] {
        let runner = runner(for: project)
        let names = actionDiscoveryRootFiles + actionDiscoveryLockfiles.map { "lock:" + $0 }
        guard let first = try? await runner.run(["sh", "-c", actionDiscoveryRootScript, "sh"] + names, folder), first.status == 0 else { return [] }
        let root = parseDiscoveryDump(first.stdout)
        let globs = workspaceGlobs(packageJSON: root["package.json"], pnpmWorkspace: root["pnpm-workspace.yaml"])
        var packages: [String: String] = [:]
        if !globs.isEmpty, let second = try? await runner.run(["sh", "-c", actionDiscoveryPackagesScript, "sh"] + globs, folder), second.status == 0 {
            packages = parseDiscoveryDump(second.stdout)
        }
        return actionSuggestions(root: root, packages: packages)
    }

    /// The action's folder exists in this chat's checkout (`test -d` over ssh for a remote project); nil — it does,
    /// else the missing path. A host that cannot be asked lets the launch report it.
    func missingActionFolder(_ action: ProjectAction, task: HangarTask) async -> String? {
        guard action.folder != nil, let base = actionsFolder(of: task), let project = project(task.projectId) else { return nil }
        let path = action.cwd(in: base)
        if project.host == nil { return folderExists(path) ? nil : path }
        guard let r = try? await runner(for: project).run(["test", "-d", path], base) else { return nil }
        return r.status == 0 ? nil : path
    }

    /// Action leaves of the task now holding a running (or starting) process.
    func runningActions(of task: HangarTask) -> [(name: String, tab: UUID, leaf: UUID)] {
        task.tabs.flatMap { tab in
            tab.root.leaves.compactMap { leaf in
                guard let name = leaf.action, isActionRunning(leaf.id) else { return nil }
                return (name, tab.id, leaf.id)
            }
        }
    }

    func isActionRunning(_ leafId: UUID) -> Bool {
        guard stoppingActions[leafId] == nil, let state = terminals?.state(leafId) else { return false }
        return state == .running || state == .starting
    }

    /// The action ⌘R and the toolbar's run button start: the last one run in this project, else the first.
    func primaryAction(of task: HangarTask) -> ResolvedAction? {
        let all = actions(of: task)
        let last = project(task.projectId)?.lastAction
        return all.first { $0.name == last } ?? all.first
    }

    /// The toolbar, ⌘R, menus and the palette: reads the repository file again, asks before a new repository command,
    /// then runs. `leaf`: ↩ on that action tab — it starts again there whatever its restart setting.
    func runAction(_ name: String, taskId: UUID, leaf: UUID? = nil) {
        Task {
            guard let task = state.tasks.first(where: { $0.id == taskId && !$0.archived }) else { return }
            await loadRepoActions(task)
            guard let action = actions(of: task).first(where: { $0.name == name }), let project = project(task.projectId) else { return }
            if let missing = await missingActionFolder(action.action, task: task) {
                actionFailed?(L10n.actionNotStarted(name), L10n.actionFolderMissing(action.action.folder ?? missing))
                return
            }
            guard actionNeedsApproval(action, approved: project.approvedActions) else {
                _ = startAction(action, taskId: taskId, leaf: leaf, activate: true)
                return
            }
            confirmActionRun?(action.name, action.action.command) { [weak self] in
                guard let self else { return }
                perform { $0.approveAction(projectId: project.id, command: action.action.command) }
                _ = startAction(action, taskId: taskId, leaf: leaf, activate: true)
            }
        }
    }

    /// CLI/MCP: the same run without a question; an unapproved repository command is refused. The visible tab stays.
    func runActionFromControl(_ name: String, taskId: UUID) async -> Result<(tab: UUID, restarted: Bool), ActionRunError> {
        guard let task = state.tasks.first(where: { $0.id == taskId && !$0.archived }), actionsFolder(of: task) != nil else {
            return .failure(.notAvailable)
        }
        await loadRepoActions(task)
        guard let action = actions(of: task).first(where: { $0.name == name }) else { return .failure(.noAction(name)) }
        if actionNeedsApproval(action, approved: project(task.projectId)?.approvedActions) { return .failure(.needsApproval(name)) }
        if let missing = await missingActionFolder(action.action, task: task) { return .failure(.missingFolder(missing)) }
        guard let started = startAction(action, taskId: taskId, leaf: nil, activate: false) else { return .failure(.notAvailable) }
        return .success(started)
    }

    /// A new tab, or the action's tab again: ⌃C to a running copy, then (once it ended, or after the grace) a fresh terminal.
    @discardableResult
    func startAction(_ action: ResolvedAction, taskId: UUID, leaf target: UUID?, activate: Bool) -> (tab: UUID, restarted: Bool)? {
        guard let task = state.tasks.first(where: { $0.id == taskId }), let base = actionsFolder(of: task) else { return nil }
        let command = action.action.command
        let cwd = action.action.cwd(in: base)
        let plan: ActionRunPlan = target.flatMap { id in location(ofLeaf: id).map { .restart(tab: $0.tab, leaf: id) } }
            ?? actionRunPlan(action.action, in: task)
        uiLog.info("action run name=\(action.name, privacy: .public) plan=\(String(describing: plan), privacy: .public)")
        switch plan {
        case .newTab:
            var tab: UUID?
            perform { s in
                s.setLastAction(projectId: task.projectId, action.name)
                let previous = s.tasks.first { $0.id == taskId }?.activeTabId
                guard let made = s.addActionTab(taskId: taskId, name: action.name, cwd: cwd) else { return }
                if !activate, let i = s.tasks.firstIndex(where: { $0.id == taskId }) { s.tasks[i].activeTabId = previous }
                pendingPrompts[made.leaf] = command
                tab = made.tab
            }
            guard let tab else { return nil }
            terminals?.start(tab)
            return (tab, false)
        case .restart(let tab, let leaf):
            let running = isActionRunning(leaf)
            let renew: () -> Void = { [weak self] in
                guard let self else { return }
                perform { s in
                    s.setLastAction(projectId: task.projectId, action.name)
                    guard let fresh = s.renewActionLeaf(leaf, cwd: cwd) else { return }
                    pendingPrompts[fresh] = command
                    if activate, let i = s.tasks.firstIndex(where: { $0.id == taskId }) { s.tasks[i].activeTabId = tab }
                }
                terminals?.start(tab)
            }
            if running { stopAction(leaf, then: renew) } else { renew() }
            return (tab, running)
        }
    }

    /// ⌃C (SIGINT to the foreground job); still running after the grace — its terminal is closed (SIGHUP; a remote
    /// tmux session is killed). `then` (a restart) runs once it ended; a plain stop leaves the tab, a hung-up one ready for ↩.
    func stopAction(_ leafId: UUID, then: (() -> Void)? = nil) {
        guard stoppingActions[leafId] == nil else { return }
        stoppingActions[leafId] = then ?? {}
        terminals?.send(leafId, nil, [.ctrlC])
        DispatchQueue.main.asyncAfter(deadline: .now() + actionStopGrace) { [weak self] in
            guard let self, stoppingActions.removeValue(forKey: leafId) != nil else { return }
            if let then { then() } else { perform { _ = $0.renewActionLeaf(leafId) } }
        }
    }

    /// The action's process ended: a stop by Hangar (or ⌃C, a hang-up) is not a failure; a waiting restart goes on.
    func actionExited(_ leafId: UUID, code: Int32) {
        let pending = stoppingActions.removeValue(forKey: leafId)
        signal(.exited(code: pending != nil || actionWasStopped(code) ? 0 : code), leaf: leafId)
        // Not inside the terminal's own exit callback: the restart closes this very view.
        if let pending { DispatchQueue.main.async { pending() } }
    }

    /// ↩ (or a click on the bar) of an action tab: run it again in that tab.
    func rerunAction(leafId: UUID) {
        guard let leaf = leaf(id: leafId), let name = leaf.action, let loc = location(ofLeaf: leafId) else { return }
        runAction(name, taskId: loc.task, leaf: leafId)
    }

    /// ⌘R: the selected chat's last action.
    func runPrimaryAction() {
        guard let task = selectedTask, actionsFolder(of: task) != nil else { return }
        Task {
            await loadRepoActions(task)
            if let action = primaryAction(of: task) { runAction(action.name, taskId: task.id) }
        }
    }
}
