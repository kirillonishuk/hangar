import AgentStatus
import Foundation
import Workspace

/// «Готово» seen or not (#135): a finished turn stays new until its leaf is on screen while the window is shown.
extension AppState {
    /// Leaves on screen now: the selected chat's active tab (unless the diff tab or History covers it) and its open
    /// TERMINAL drawer; none while the window is hidden or the app inactive.
    var onScreenLeaves: Set<UUID> {
        guard screenShown?() == true, !sessionsViewVisible, let task = selectedTask else { return [] }
        var ids = Set<UUID>()
        if diffTabs[task.id]?.active != true, let tab = task.tabs.first(where: { $0.id == task.activeTabId }) {
            ids.formUnion(tab.root.leaves.map(\.id))
        }
        if task.drawer.visible, let leaf = task.drawer.leaf { ids.insert(leaf.id) }
        return ids
    }

    /// Marks the leaves that came on screen since the last call as seen. Only newcomers: «Отметить непрочитанным» on
    /// the chat in view holds until it is left and shown again (or the app comes back to the front).
    func refreshSeen() {
        let shown = onScreenLeaves
        let fresh = shown.subtracting(shownLeaves)
        shownLeaves = shown
        guard fresh.contains(where: { statuses.status($0).unseen }) else { return }
        var board = statuses
        for id in fresh { board.markSeen(id) }
        statuses = board
    }

    /// A done that arrives on a leaf in view is seen at once.
    func seenOnArrival(_ board: inout StatusBoard, leaf: UUID) {
        guard board.status(leaf).unseen, shownLeaves.contains(leaf), screenShown?() == true else { return }
        board.markSeen(leaf)
    }

    /// The leaves whose state makes up the task's dot (tabs and the TERMINAL drawer).
    private func leaves(of task: HangarTask) -> [Leaf] { task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 } }

    /// The dot of a done chat (or tab) whose every finished turn has been seen: hollow, quiet.
    func doneSeen(_ leaves: [Leaf]) -> Bool { !leaves.contains { statuses.status($0.id).unseen } }

    func doneSeen(_ task: HangarTask) -> Bool { doneSeen(leaves(of: task)) }

    /// «Отметить непрочитанным» is offered: the chat shows a seen «готово».
    func canMarkUnread(_ taskId: UUID) -> Bool {
        guard let task = state.tasks.first(where: { $0.id == taskId && !$0.archived }) else { return false }
        return displayState(of: task) == .done && doneSeen(task)
    }

    /// Its done leaves are new again: solid dot, back in «Готово недавно».
    func markUnread(taskId: UUID) {
        guard let task = state.tasks.first(where: { $0.id == taskId }) else { return }
        var board = statuses
        for leaf in leaves(of: task) { board.markUnseen(leaf.id) }
        if board != statuses { statuses = board }
    }
}
