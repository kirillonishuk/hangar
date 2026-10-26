import Foundation

/// One open file of an editor tab and its cursor (1-based), restored on launch (#80).
public struct EditorFile: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var column: Int

    public init(path: String, line: Int, column: Int) {
        self.path = path
        self.line = max(1, line)
        self.column = max(1, column)
    }
}

extension Leaf {
    public var editorFileList: [EditorFile] { editorFiles ?? [] }
}

extension WorkspaceState {
    private mutating func updateEditor(_ leafId: UUID, _ change: (inout Leaf) -> Void) {
        for i in tasks.indices {
            for t in tasks[i].tabs.indices where tasks[i].tabs[t].root.leaf(id: leafId)?.kind == .editor {
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { leaf in
                    var leaf = leaf
                    if leaf.id == leafId { change(&leaf) }
                    return leaf
                }
                return
            }
        }
    }

    /// Only for an open file.
    public mutating func setEditorCursor(leafId: UUID, path: String, line: Int, column: Int) {
        updateEditor(leafId) { leaf in
            var files = leaf.editorFileList
            guard let i = files.firstIndex(where: { $0.path == path }) else { return }
            files[i] = EditorFile(path: path, line: line, column: column)
            leaf.editorFiles = files
        }
    }
}

// MARK: One tab per file (#83)

extension WorkspaceState {
    /// The task's tab showing `path` (its editor leaf).
    public func fileTab(taskId: UUID, path: String) -> (tab: UUID, leaf: UUID)? {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return nil }
        for tab in task.tabs {
            if let leaf = tab.root.leaves.first(where: { $0.kind == .editor && $0.openFile == path }) { return (tab.id, leaf.id) }
        }
        return nil
    }

    /// Opens `path` in the task: its own tab if open (a line moves the cursor; a non-preview open pins it), else the
    /// task's preview tab with this file (`preview`), else a new tab right after the active one. The tab becomes active.
    @discardableResult
    public mutating func openFileTab(taskId: UUID, path: String, line: Int?, column: Int?, preview: Bool) -> (tab: UUID, leaf: UUID)? {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
        if let found = fileTab(taskId: taskId, path: path) {
            if let line { setEditorCursor(leafId: found.leaf, path: path, line: line, column: column ?? 1) }
            if !preview { pinTab(taskId: taskId, tabId: found.tab) }
            if let t = tasks[i].tabs.firstIndex(where: { $0.id == found.tab }) { tasks[i].tabs[t].focusedLeafId = found.leaf }
            tasks[i].activeTabId = found.tab
            return found
        }
        let leaf = Leaf(kind: .editor, cwd: cwd(for: tasks[i]), openFile: path, openLine: line)
        var editor = leaf
        editor.editorFiles = [EditorFile(path: path, line: line ?? 1, column: column ?? 1)]
        if preview, let t = tasks[i].tabs.firstIndex(where: { $0.preview }) {
            // A new leaf: the replaced file's buffer and view go with the old one.
            tasks[i].tabs[t].root = .leaf(editor)
            tasks[i].tabs[t].focusedLeafId = editor.id
            tasks[i].activeTabId = tasks[i].tabs[t].id
            return (tasks[i].tabs[t].id, editor.id)
        }
        var tab = Tab(title: LeafKind.editor.rawValue, root: .leaf(editor), focusedLeafId: editor.id)
        tab.preview = preview
        let after = tasks[i].tabs.firstIndex { $0.id == tasks[i].activeTabId }.map { $0 + 1 } ?? tasks[i].tabs.count
        tasks[i].tabs.insert(tab, at: after)
        tasks[i].activeTabId = tab.id
        return (tab.id, editor.id)
    }

    /// A preview tab becomes a normal one (edited, double-clicked, opened for real).
    public mutating func pinTab(taskId: UUID, tabId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), let t = tasks[i].tabs.firstIndex(where: { $0.id == tabId }),
              tasks[i].tabs[t].preview else { return }
        tasks[i].tabs[t].preview = false
    }

    /// state.json of the multi-file editor tab (#80): every file but the active one moves to its own tab right after it.
    mutating func splitEditorTabs() {
        for i in tasks.indices {
            var t = 0
            while t < tasks[i].tabs.count {
                let tab = tasks[i].tabs[t]
                guard let leaf = tab.root.leaves.first(where: { $0.kind == .editor && $0.editorFileList.count > 1 }) else { t += 1; continue }
                let files = leaf.editorFileList
                let active = files.first { $0.path == leaf.openFile } ?? files[0]
                tasks[i].tabs[t].root = tab.root.mapLeaves { l in
                    guard l.id == leaf.id else { return l }
                    var kept = l
                    kept.editorFiles = [active]
                    kept.openFile = active.path
                    return kept
                }
                let others: [Tab] = files.filter { $0 != active }.map { file in
                    var l = Leaf(kind: .editor, cwd: leaf.cwd, openFile: file.path)
                    l.editorFiles = [file]
                    return Tab(title: LeafKind.editor.rawValue, root: .leaf(l), focusedLeafId: l.id)
                }
                tasks[i].tabs.insert(contentsOf: others, at: t + 1)
                t += 1 + others.count
            }
        }
    }
}
