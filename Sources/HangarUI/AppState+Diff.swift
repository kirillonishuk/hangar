import AppKit
import Git

/// The temporary read-only diff tab of a task (decision #44): one per task, replaced by the next Changes click.
struct DiffTab: Equatable {
    var path: String
    /// Shown instead of the task's active tab.
    var active: Bool
    /// `DiffContent.Item.id` of the clicked row (↩ opens there): follows the line across reloads.
    var selectedRowId: String?
    /// A file of this commit (the Git tab), not the session's changes; `path` is then top-relative.
    var commit: String? = nil
    /// The commit file's name before a rename.
    var origPath: String? = nil
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
        leavingDiff { [self] in
            diffTabs[id] = DiffTab(path: path, active: true, selectedRowId: nil)
            inspector.loadDiff(path: path)
            didChange?()
        }
    }

    /// An edited diff buffer is saved, dropped or kept (Cancel) before the diff shows another file or closes.
    private func leavingDiff(_ then: @escaping () -> Void) {
        if let confirmLeaveDiff { confirmLeaveDiff(then) } else { then() }
    }

    /// A file click in the Git tab's commit details: the same diff tab, read-only, that commit against its first parent.
    func openCommitDiff(hash: String, file: ChangedFile) {
        guard let id = selectedTask?.id else { return }
        leavingDiff { [self] in
            if diffTabs[id]?.commit == nil { inspector.loadDiff(path: nil) }  // the Changes diff is no longer shown
            diffTabs[id] = DiffTab(path: file.path, active: true, selectedRowId: nil, commit: hash, origPath: file.origPath)
            gitPanel.loadDiff(hash: hash, path: file.path, origPath: file.origPath)
            didChange?()
        }
    }

    /// A click on the diff tab.
    func activateDiff() {
        guard let id = selectedTask?.id, let tab = diffTabs[id], !tab.active else { return }
        diffTabs[id]?.active = true
        if let hash = tab.commit {
            if gitPanel.diffState(hash: hash, path: tab.path) == nil { gitPanel.loadDiff(hash: hash, path: tab.path, origPath: tab.origPath) }
        } else if inspector.diffPath != tab.path {
            inspector.loadDiff(path: tab.path)
        }
        didChange?()
    }

    func closeDiff() {
        guard let id = selectedTask?.id, diffTabs[id] != nil else { return }
        leavingDiff { [self] in
            diffTabs[id] = nil
            inspector.loadDiff(path: nil)
            didChange?()
        }
    }

    /// ↑/↓: the previous/next file of Changes (or of the commit), stopping at the ends.
    func diffNeighbour(_ offset: Int) {
        guard let tab = activeDiff else { return }
        if let hash = tab.commit {
            guard let details = gitPanel.details, details.commit.hash == hash else { return }
            // The order the details list them in.
            let files = commitFileGroups(details.files).flatMap(\.files)
            guard let i = files.firstIndex(where: { $0.path == tab.path }) else { return }
            let next = min(max(i + offset, 0), files.count - 1)
            if next != i { openCommitDiff(hash: hash, file: files[next]) }
            return
        }
        guard let files = inspector.changes?.files,
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
        if let hash = tab.commit {
            return diffCache.content(gitPanel.diffState(hash: hash, path: tab.path) ?? .loading, origPath: tab.origPath, path: tab.path)
        }
        let state = inspector.diffPath == tab.path ? inspector.diff : .loading
        return diffCache.content(state, origPath: inspector.changes?.files.first { $0.path == tab.path }?.origPath, path: tab.path)
    }

    /// A new load of the open diff (set as `inspector.onDiffApplied`): a selected line that is gone (⌥B, edits) is unselected.
    func pruneDiffSelection() {
        guard let id = selectedTask?.id, let tab = diffTabs[id], let row = tab.selectedRowId,
              inspector.diffPath == tab.path, content(of: tab).indexById[row] == nil else { return }
        diffTabs[id]?.selectedRowId = nil
    }

    /// ↩ / double-click: the task's Helix at `openTarget`; nothing when there is no line to open.
    func openActiveDiffInEditor() {
        // A commit's file is history: the working copy's lines may be elsewhere by now.
        guard let tab = activeDiff, tab.commit == nil, let root = inspector.root,
              let line = openTarget(rows: activeDiffContent.rows, selected: activeDiffSelection) else { return }
        openInEditor(path: root + "/" + tab.path, line: line)
    }

    /// ↩ / ⌘↩ in Monaco's diff: the working file at that place (a commit's file is history: nothing).
    func openActiveDiffInEditor(line: Int, column: Int) {
        guard let tab = activeDiff, tab.commit == nil, let root = inspector.root else { return }
        openInEditor(path: root + "/" + tab.path, line: line, column: column)
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
/// ↑/↓/↩ belong to Monaco while its diff editor has focus (`webFocused`; there ⌥⌘↑/↓ step through files).
func diffKeyRoute(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, diffActive: Bool, editingText: Bool, webFocused: Bool = false) -> DiffKey? {
    guard diffActive, !editingText else { return nil }
    let mods = modifiers.intersection([.command, .shift, .option, .control])
    switch (keyCode, mods) {
    case (126, []) where !webFocused: return .up
    case (125, []) where !webFocused: return .down
    case (36, []) where !webFocused: return .enter
    case (11, .option): return .toggleMode
    case (13, .command): return .close
    default: return nil
    }
}
