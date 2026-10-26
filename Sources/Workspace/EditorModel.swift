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
    /// The editor's files; a Helix-era leaf (only `openFile`) has that one.
    public var editorFileList: [EditorFile] {
        if let editorFiles { return editorFiles }
        return openFile.map { [EditorFile(path: $0, line: openLine ?? 1, column: 1)] } ?? []
    }
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

    /// Adds the file (at the end) unless open, makes it active; a given line/column moves its cursor.
    public mutating func openEditorFile(leafId: UUID, path: String, line: Int?, column: Int?) {
        updateEditor(leafId) { leaf in
            var files = leaf.editorFileList
            if let i = files.firstIndex(where: { $0.path == path }) {
                if let line { files[i] = EditorFile(path: path, line: line, column: column ?? 1) }
            } else {
                files.append(EditorFile(path: path, line: line ?? 1, column: column ?? 1))
            }
            leaf.editorFiles = files
            leaf.openFile = path
            leaf.openLine = nil
        }
    }

    public mutating func activateEditorFile(leafId: UUID, path: String) {
        updateEditor(leafId) { leaf in
            if leaf.editorFileList.contains(where: { $0.path == path }) { leaf.openFile = path }
        }
    }

    /// Closes the file; the active one passes to its right neighbour, else the left. True when none is left.
    @discardableResult
    public mutating func closeEditorFile(leafId: UUID, path: String) -> Bool {
        var empty = false
        updateEditor(leafId) { leaf in
            var files = leaf.editorFileList
            guard let i = files.firstIndex(where: { $0.path == path }) else { empty = files.isEmpty; return }
            files.remove(at: i)
            leaf.editorFiles = files
            if leaf.openFile == path { leaf.openFile = files.isEmpty ? nil : files[min(i, files.count - 1)].path }
            empty = files.isEmpty
        }
        return empty
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
