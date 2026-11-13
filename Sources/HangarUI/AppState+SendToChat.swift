import Foundation
import Workspace

/// «Вставить путь в чат» / «Вставить ссылку на строки» (HD-163): the text goes into the chat's agent as `tabs send`
/// puts it — typed, no Enter — and that agent is shown, so the question follows.
extension AppState {
    /// The selected chat's running agent that gets the text, if any.
    var chatAgent: Leaf? {
        selectedTask.flatMap { task in chatAgentLeaf(task) { terminals?.state($0) == .running } }
    }

    /// `path` is absolute; the agent gets it from the chat's folder (its cwd).
    func sendPathToChat(_ path: String) {
        guard let task = selectedTask, let leaf = chatAgent else { return }
        send(toChat: leaf, freeChatMention(pathInChat(path, taskId: task.id), agent: leaf.kind) + " ")
    }

    func sendLinesToChat(_ path: String, from: Int, to: Int) {
        guard let task = selectedTask, let leaf = chatAgent else { return }
        send(toChat: leaf, chatLineRef(pathInChat(path, taskId: task.id), from: from, to: to) + " ")
    }

    private func send(toChat leaf: Leaf, _ text: String) {
        terminals?.send(leaf.id, text, [])
        reveal(leafId: leaf.id)
    }
}

/// The agent a path goes to: the active tab's focused pane if it is a running agent, else the first running agent of
/// the active tab, then of the other tabs in their order.
func chatAgentLeaf(_ task: HangarTask, running: (UUID) -> Bool) -> Leaf? {
    let active = task.tabs.first { $0.id == task.activeTabId }
    let focused = active.flatMap { $0.root.leaf(id: $0.focusedLeafId) }.map { [$0] } ?? []
    let rest = (active.map { [$0] } ?? []) + task.tabs.filter { $0.id != task.activeTabId }
    return (focused + rest.flatMap(\.root.leaves)).first { ($0.kind == .claude || $0.kind == .codex) && running($0.id) }
}

/// `src/a.ts:12-30` (one line: `src/a.ts:12`).
func chatLineRef(_ path: String, from: Int, to: Int) -> String {
    from == to ? "\(path):\(from)" : "\(path):\(min(from, to))-\(max(from, to))"
}
