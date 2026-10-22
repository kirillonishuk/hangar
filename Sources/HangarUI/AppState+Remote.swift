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

    func hasWorking(host: String) -> Bool {
        statuses.leaves.contains { $0.value.state == .working && remoteLeafHost($0.key) == host }
    }
}
