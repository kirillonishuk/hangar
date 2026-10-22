import AgentStatus
import ControlServer
import Exec
import Foundation
import Git
import Power
import Workspace

/// ssh hosts: their socket messages pass only for their own leaves; a host given up leaves its leaves idle.
extension AppState {
    func makeRemoteHosts(paths: SSHPaths, sshPath: String,
                         schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = KeepAwake.taskSchedule,
                         isActive: @escaping () -> Bool) -> RemoteHosts {
        let hosts = RemoteHosts(paths: paths, sshPath: sshPath, schedule: schedule, isActive: isActive,
                                hasWorking: { [weak self] in self?.hasWorking(host: $0) ?? false },
                                onMessage: { [weak self] in self?.handleRemote(host: $0, $1) })
        hosts.onConnected = { [weak self] host in
            self?.onHostConnected?(host)
            self?.inspectorHostConnected(host)
        }
        hosts.onUnreachable = { [weak self] host in
            guard let self else { return }
            for id in liveLeafIds where remoteLeafHost(id) == host { signal(.relaunched, leaf: id) }
        }
        return hosts
    }

    /// Where the project's commands run: this Mac, or its host (failing fast while not connected).
    func runner(for project: Project) -> Runner { project.host.map(remote.runner) ?? .local }

    /// git of the project (or of `repo`, one of its worktrees) on the project's machine.
    func git(for project: Project, repo: String? = nil) -> Git { Git(repo: repo ?? project.path, runner: runner(for: project)) }

    /// Remote: the host was not given up on (the server's disk is never stat'ed from here); local: the folder exists.
    func isAvailable(_ project: Project) -> Bool {
        guard let host = project.host else { return folderExists(project.path) }
        if case .unreachable = remote.hosts[host]?.state { return false }
        return true
    }

    /// The task's or project's folder can be used: as `isAvailable`, a local task by its own folder.
    func isAvailable(_ target: ActionTarget) -> Bool {
        guard let path = path(of: target), let project = project(of: target) else { return false }
        return project.host == nil ? folderExists(path) : isAvailable(project)
    }

    func project(of target: ActionTarget) -> Project? {
        switch target {
        case .project(let id): project(id)
        case .task(let id), .tab(let id, _): state.tasks.first { $0.id == id }.flatMap { project($0.projectId) }
        }
    }

    /// The inspector of the visible remote task showed «not connected»: its host is back, load again (no FSEvents there).
    private func inspectorHostConnected(_ host: String) {
        guard inspector.offline, let task = selectedTask, project(task.projectId)?.host == host else { return }
        inspector.refresh(.all)
    }

    /// Trust boundary: any process of that account on the server can write the forwarded socket, so an event
    /// must name a leaf of this host's own projects (`handle` then checks the tab).
    func handleRemote(host: String, _ m: ControlMessage) {
        switch m {
        case let .event(e): if remoteLeafHost(e.leaf) == host { handle(m) }
        case .usage: handle(m)
        case .request: break
        }
    }

    /// Host of the remote project whose unarchived task holds the leaf; nil for local or unknown leaves.
    func remoteLeafHost(_ leafId: UUID) -> String? {
        for task in state.tasks where !task.archived {
            guard task.drawer.leaf?.id == leafId || task.tabs.contains(where: { $0.root.leaf(id: leafId) != nil }) else { continue }
            return project(task.projectId)?.host
        }
        return nil
    }

    /// Live leaves of remote projects → host; empty (and cheap) without remote projects.
    func liveRemoteLeaves() -> [UUID: String] {
        guard state.projects.contains(where: { $0.host != nil }) else { return [:] }
        var result: [UUID: String] = [:]
        for task in state.tasks where !task.archived {
            guard let host = project(task.projectId)?.host else { continue }
            for leaf in task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap({ $0 }) { result[leaf.id] = host }
        }
        return result
    }

    /// Closed, archived or deleted remote leaves: their tmux sessions go (quitting never comes here).
    // shortcut: without a connection the session stays on the server (runner fails fast); kill on reconnect is a followup
    func killSessions(of leaves: [UUID: String]) {
        for (id, host) in leaves {
            let runner = remote.runner(host)
            Task { _ = try? await runner.run(killSessionArgs(id), "") }
        }
    }

    /// Working leaves ⌘Q asks about: a remote one in tmux keeps running on the server after quit.
    var quitWorkingCount: Int {
        statuses.leaves.filter { id, status in
            guard status.state == .working else { return false }
            guard let host = remoteLeafHost(id) else { return true }
            return remote.hosts[host]?.report?.tmux != true
        }.count
    }

    func hasWorking(host: String) -> Bool {
        statuses.leaves.contains { $0.value.state == .working && remoteLeafHost($0.key) == host }
    }
}
