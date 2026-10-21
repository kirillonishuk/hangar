import AppKit
import Git

/// The temporary read-only diff tab of a task (decision #44): one per task, replaced by the next Changes click.
struct DiffTab: Equatable {
    var path: String
    /// Shown instead of the task's active tab.
    var active: Bool
    /// Index into `diffRows` of the clicked line (↩ opens there).
    var selectedRow: Int?
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
        diffTabs[id] = DiffTab(path: path, active: true, selectedRow: nil)
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

    func selectDiffRow(_ row: Int?) {
        guard let id = selectedTask?.id, diffTabs[id] != nil else { return }
        diffTabs[id]?.selectedRow = row
    }

    /// Rows of the shown diff (cached per load). A path not (yet) loaded by the inspector is still loading.
    var activeDiffContent: DiffContent {
        guard let tab = activeDiff else { return diffCache.content(.none, origPath: nil) }
        let state = inspector.diffPath == tab.path ? inspector.diff : .loading
        return diffCache.content(state, origPath: inspector.changes?.files.first { $0.path == tab.path }?.origPath)
    }

    /// ↩ / double-click: the task's Helix at `openTarget`; nothing when there is no line to open.
    func openActiveDiffInEditor() {
        guard let tab = activeDiff, let root = inspector.root,
              let line = openTarget(rows: activeDiffContent.rows, selected: tab.selectedRow) else { return }
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
