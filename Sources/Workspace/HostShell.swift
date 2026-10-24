import Foundation

/// A plain ssh login to a host with no project (#NN-ssh-shell): its one task, «<host> · терминал», holds ssh shell tabs.
/// Kept out of `projects`, so project lists, the remote machinery (master, check, tmux) and CLI listings never see it.
public struct HostShell: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var host: String

    public init(id: UUID = UUID(), host: String) {
        self.id = id
        self.host = host
    }
}

extension WorkspaceState {
    /// The host's terminal that owns the task; nil for project tasks.
    public func hostShell(ofTask taskId: UUID) -> HostShell? {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return nil }
        return hostShells.first { $0.id == task.projectId }
    }

    public func hostShellTask(host: String) -> HangarTask? {
        guard let shell = hostShells.first(where: { $0.host == host }) else { return nil }
        return tasks.first { $0.projectId == shell.id && !$0.archived }
    }

    /// A new shell tab in the host's terminal task (made on first use), selected. `host` is validated by the caller.
    @discardableResult
    public mutating func openHostShell(host: String) -> (task: UUID, tab: UUID) {
        let task: UUID
        if let existing = hostShellTask(host: host) {
            task = existing.id
        } else {
            let shell = hostShells.first { $0.host == host } ?? HostShell(host: host)
            if !hostShells.contains(shell) { hostShells.append(shell) }
            task = addTask(projectId: shell.id, name: host)
        }
        let tab = addTab(taskId: task, kind: .shell)
        select(taskId: task)
        return (task, tab)
    }

    /// Forgets the host's terminal and its task (their surfaces close with them).
    public mutating func closeHostShell(host: String) {
        guard let shell = hostShells.first(where: { $0.host == host }) else { return }
        if let selected = selectedTaskId, tasks.contains(where: { $0.id == selected && $0.projectId == shell.id }) { selectedTaskId = nil }
        tasks.removeAll { $0.projectId == shell.id }
        hostShells.removeAll { $0.id == shell.id }
    }

    func isHostShellTask(_ task: HangarTask) -> Bool { hostShells.contains { $0.id == task.projectId } }
}
