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

    /// Where ssh sockets live (#47): beside the state, or `/tmp/hangar-<uid>` when that path is too long.
    var sshPaths: SSHPaths { SSHPaths(stateDir: (socketPath as NSString).deletingLastPathComponent) }

    /// The leaf whose folder the inspector shows: the focused leaf of the selected host terminal's active tab.
    var hostShellFocusedLeaf: UUID? {
        guard let task = selectedTask, isHostShellTask(task.id) else { return nil }
        let tab = task.tabs.first { $0.id == task.activeTabId } ?? task.tabs.first
        return tab?.focusedLeafId
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
