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
            self?.flushKills(host)
            self?.onHostConnected?(host)
            self?.inspectorHostConnected(host)
        }
        hosts.onChange = { [weak self] host in self?.onHostChange?(host) }
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
    /// Hidden (and no diff tab shown, as `InspectorWatch`): nothing runs; showing it loads.
    private func inspectorHostConnected(_ host: String) {
        guard state.inspectorVisible || activeDiff != nil, inspector.offline, let task = selectedTask,
              project(task.projectId)?.host == host else { return }
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

    /// Closed, archived or deleted remote leaves: their tmux sessions go (quitting never comes here). While the host is
    /// not connected they wait in `pendingKills` for `onConnected`. A host in `removing` (its last project went) is
    /// removed after its kills; an offline one at once.
    func killSessions(of leaves: [UUID: String], removing: Set<String> = []) {
        var byHost: [String: [UUID]] = [:]
        for (id, host) in leaves { byHost[host, default: []].append(id) }
        for host in Set(byHost.keys).union(removing) {
            let ids = byHost[host] ?? [], remove = removing.contains(host)
            guard remote.hosts[host]?.state == .connected else {
                if remove {
                    pendingKills[host] = nil
                    remote.remove(host)
                } else {
                    pendingKills[host, default: []].formUnion(ids)
                }
                continue
            }
            let queued = remove ? pendingKills.removeValue(forKey: host) ?? [] : []
            let runner = remote.runner(host)
            Task {
                var failed: [UUID] = []
                // Thrown (the host dropped meanwhile) or 255 (ssh itself failed): tmux never got it, so it waits again.
                for id in ids + queued {
                    let r = try? await runner.run(killSessionArgs(id), "")
                    if r == nil || r?.status == 255 { failed.append(id) }
                }
                if !failed.isEmpty { pendingKills[host, default: []].formUnion(failed) }
                if remove, !state.projects.contains(where: { $0.host == host }) { remote.remove(host) }
            }
        }
    }

    private func flushKills(_ host: String) {
        guard let ids = pendingKills.removeValue(forKey: host) else { return }
        killSessions(of: Dictionary(uniqueKeysWithValues: ids.map { ($0, host) }))
    }

    /// «Переподключиться» (sidebar, task menu, a leaf's bar): a fresh attempt.
    func reconnect(host: String) {
        Task { await remote.connect(host) }
    }

    /// A waiting leaf's bar when nothing is retrying right now (given up, disconnected, retry paused without a timer):
    /// it offers «Переподключиться». nil while the host is connecting.
    func hostReconnectText(_ host: String) -> String? {
        guard let info = remote.hosts[host] else { return nil }
        switch info.state {
        case .unreachable, .disconnected: return L10n.hostGaveUp(host)
        case .reconnecting where info.retryPaused: return L10n.hostPausedBar(host)
        default: return nil
        }
    }

    /// A new leaf view learns its host and how to reconnect it from its bar.
    func wireHost(_ view: LeafView) {
        guard let host = remoteLeafHost(view.leafId) else { return }
        view.host = host
        view.reconnectText = { [weak self] in self?.hostReconnectText(host) }
        view.onReconnect = { [weak self] in self?.reconnect(host: host) }
    }

    /// Hosts of remote projects, in project order (the `SSH HOSTS` section).
    var sshHosts: [String] {
        var seen = Set<String>()
        return state.projects.compactMap(\.host).filter { seen.insert($0).inserted }
    }

    /// Hosts named in the user's ssh config; none if it can't be read.
    func configHosts() -> [String] {
        (try? String(contentsOfFile: sshConfigPath, encoding: .utf8)).map(sshConfigHosts) ?? []
    }

    /// A host the remote-project sheet connected and no project uses goes again.
    func releaseUnusedHost(_ host: String) {
        if !state.projects.contains(where: { $0.host == host }) { remote.remove(host) }
    }

    @discardableResult func addRemoteProject(host: String, path: String) -> UUID {
        var id = UUID()
        perform { id = $0.addRemoteProject(name: (path as NSString).lastPathComponent, host: host, path: path) }
        return id
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
