import AgentStatus
import ControlServer
import Exec
import Foundation
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
        hosts.onConnected = { [weak self] in self?.onHostConnected?($0) }
        hosts.onUnreachable = { [weak self] host in
            guard let self else { return }
            for id in liveLeafIds where remoteLeafHost(id) == host { signal(.relaunched, leaf: id) }
        }
        return hosts
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
