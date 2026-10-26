import Foundation
import Workspace

extension AppState {
    /// File access of an editor leaf (or the diff): through the host for a remote project.
    func editorIO(host: String?) -> EditorIO {
        guard let host else { return .local }
        let remote = self.remote
        return .remote(runner: remote.runner(host)) { script, args, input in
            await remote.write(host, script: script, args: args, input: input)
        }
    }

    func editorLeaf(_ id: UUID) -> Leaf? {
        for task in state.tasks where !task.archived {
            for tab in task.tabs { if let leaf = tab.root.leaf(id: id), leaf.kind == .editor { return leaf } }
        }
        return nil
    }

    /// Unsaved editor files of the tab's leaves (all tabs when nil): closing or quitting asks first.
    func unsavedEditorFiles(tab tabId: UUID? = nil) -> [String] {
        let leaves = state.tasks.filter { !$0.archived }.flatMap(\.tabs).filter { tabId == nil || $0.id == tabId }.flatMap(\.root.leaves)
        return leaves.filter { $0.kind == .editor }.flatMap { editorUnsaved?($0.id) ?? [] }
    }
}

/// The task's editor leaf for a file to open in: the active tab's focused editor leaf (else its first one), else the
/// first editor leaf in tab order; nil → a new editor tab.
@MainActor func editorTarget(task: HangarTask) -> (tab: UUID, leaf: UUID)? {
    func editors(_ tab: Tab) -> [Leaf] { tab.root.leaves.filter { $0.kind == .editor } }
    if let tab = task.tabs.first(where: { $0.id == task.activeTabId }) {
        let leaves = editors(tab)
        if let leaf = leaves.first(where: { $0.id == tab.focusedLeafId }) ?? leaves.first { return (tab.id, leaf.id) }
    }
    if let tab = task.tabs.first(where: { !editors($0).isEmpty }) { return (tab.id, editors(tab)[0].id) }
    return nil
}
