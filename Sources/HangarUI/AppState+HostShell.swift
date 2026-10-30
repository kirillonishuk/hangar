import Exec
import Foundation
import Workspace

/// «<host> · терминал» (#64): plain `ssh -t` shells with no project. They are local leaves running ssh:
/// never the host's master, server check, tmux or kill queue (`remoteLeafHost` is nil for them).
extension AppState {
    /// A new ssh shell tab on the host, shown; nil (nothing changes) for a host ssh must not be given.
    @discardableResult func openHostShell(_ raw: String) -> (task: UUID, tab: UUID)? {
        guard let host = validSSHHost(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        deactivateDiff()
        var opened: (task: UUID, tab: UUID)?
        perform { opened = $0.openHostShell(host: host) }
        return opened
    }

    /// A click on a host row without projects: its terminal if it has one, else a new tab.
    func showHostShell(_ host: String) {
        if let task = state.hostShellTask(host: host) { select(taskId: task.id) } else { openHostShell(host) }
    }

    func closeHostShell(_ host: String) { perform { $0.closeHostShell(host: host) } }

    /// Host of the terminal whose task holds the leaf (a tab or its TERMINAL drawer); nil for project leaves.
    func hostShellHost(ofLeaf leafId: UUID) -> String? {
        guard !state.hostShells.isEmpty else { return nil }
        let task = state.tasks.first { t in t.drawer.leaf?.id == leafId || t.tabs.contains { $0.root.leaf(id: leafId) != nil } }
        return task.flatMap { state.hostShell(ofTask: $0.id)?.host }
    }

    func isHostShellTask(_ taskId: UUID) -> Bool { state.hostShell(ofTask: taskId) != nil }

    /// What the inspector says instead of its data: a host's terminal (#64), which has no project folder — the inspector
    /// still holds the previous chat's files then, and must not show them. No chat: the inspector is empty (§3.19).
    var inspectorNotice: String? {
        guard let task = selectedTask else { return nil }
        return isHostShellTask(task.id) ? L10n.inspectorHostShell : nil
    }

    /// The ssh config's hosts again (launch, app activation): no file watcher, the list is cheap to read.
    func reloadConfigHosts() {
        let hosts = configHosts()
        if hosts != configHostList { configHostList = hosts }
    }

    /// The SSH HOSTS section: hosts of remote projects (their own rows), typed-in terminals, then the ssh config's.
    var sidebarHosts: [String] {
        var seen = Set<String>()
        return (sshHosts + state.hostShells.map(\.host) + configHostList).filter { seen.insert($0).inserted }
    }
}
