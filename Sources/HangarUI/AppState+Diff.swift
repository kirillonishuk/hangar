import AppKit
import Git

/// The temporary read-only diff tab of a task (decision #44): one per task, replaced by the next Changes click.
struct DiffTab: Equatable {
    var path: String
    /// Shown instead of the task's active tab.
    var active: Bool
    /// `DiffContent.Item.id` of the clicked row (↩ opens there): follows the line across reloads.
    var selectedRowId: String?
}

extension AppState {
    /// The selected task's diff tab while it is the shown one.
    var activeDiff: DiffTab? {
        guard let id = selectedTask?.id, let tab = diffTabs[id], tab.active else { return nil }
        return tab
    }

    /// A Changes click: replaces (or creates) the selected task's diff tab and shows it.
    func openDiff(path: String) {
        guard let id = selectedTask?.id else { return }
        diffTabs[id] = DiffTab(path: path, active: true, selectedRowId: nil)
        inspector.loadDiff(path: path)
        didChange?()
    }

    /// A click on the diff tab.
    func activateDiff() {
        guard let id = selectedTask?.id, let tab = diffTabs[id], !tab.active else { return }
        diffTabs[id]?.active = true
        if inspector.diffPath != tab.path { inspector.loadDiff(path: tab.path) }
        didChange?()
    }

    func closeDiff() {
        guard let id = selectedTask?.id, diffTabs[id] != nil else { return }
        diffTabs[id] = nil
        inspector.loadDiff(path: nil)
        didChange?()
    }

    /// ↑/↓: the previous/next file of Changes, stopping at the ends.
    func diffNeighbour(_ offset: Int) {
        guard let tab = activeDiff, let files = inspector.changes?.files,
              let i = files.firstIndex(where: { $0.path == tab.path }) else { return }
        let next = min(max(i + offset, 0), files.count - 1)
        if next != i { openDiff(path: files[next].path) }
    }

    /// A click on row `index` of the shown diff (nil: none).
    func selectDiffRow(_ index: Int?) {
        guard let id = selectedTask?.id, diffTabs[id] != nil else { return }
        let items = activeDiffContent.items
        diffTabs[id]?.selectedRowId = index.flatMap { items.indices.contains($0) ? items[$0].id : nil }
    }

    /// Row index of the selected line in the current load.
    var activeDiffSelection: Int? {
        activeDiff?.selectedRowId.flatMap { activeDiffContent.indexById[$0] }
    }

    /// Rows of the shown diff (cached per load). A path not (yet) loaded by the inspector is still loading.
    var activeDiffContent: DiffContent {
        guard let tab = activeDiff else { return diffCache.content(.none, origPath: nil) }
        return content(of: tab)
    }

    private func content(of tab: DiffTab) -> DiffContent {
        let state = inspector.diffPath == tab.path ? inspector.diff : .loading
        return diffCache.content(state, origPath: inspector.changes?.files.first { $0.path == tab.path }?.origPath)
    }

    /// A new load of the open diff (set as `inspector.onDiffApplied`): a selected line that is gone (⌥B, edits) is unselected.
    func pruneDiffSelection() {
        guard let id = selectedTask?.id, let tab = diffTabs[id], let row = tab.selectedRowId,
              inspector.diffPath == tab.path, content(of: tab).indexById[row] == nil else { return }
        diffTabs[id]?.selectedRowId = nil
    }

    /// ↩ / double-click: the task's Helix at `openTarget`; nothing when there is no line to open.
    func openActiveDiffInEditor() {
        guard let tab = activeDiff, let root = inspector.root,
              let line = openTarget(rows: activeDiffContent.rows, selected: activeDiffSelection) else { return }
        openInEditor(path: root + "/" + tab.path, line: line)
    }

    /// A regular tab is shown (⌘1…9, tab click, new tab, editor): the diff tab stays, inactive.
    /// The caller's `perform` re-syncs the views.
    func deactivateDiff() {
        guard let id = selectedTask?.id, diffTabs[id]?.active == true else { return }
        diffTabs[id]?.active = false
    }
}

enum DiffKey: Equatable { case up, down, enter, toggleMode, close }

/// Keys of the shown diff tab, by keyCode (any layout); only while it is shown and no text field edits.
func diffKeyRoute(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, diffActive: Bool, editingText: Bool) -> DiffKey? {
    guard diffActive, !editingText else { return nil }
    let mods = modifiers.intersection([.command, .shift, .option, .control])
    switch (keyCode, mods) {
    case (126, []): return .up
    case (125, []): return .down
    case (36, []): return .enter
    case (11, .option): return .toggleMode
    case (13, .command): return .close
    default: return nil
    }
}
