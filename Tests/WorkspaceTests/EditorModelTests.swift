import Foundation
import Testing
@testable import Workspace

/// The editor tab's restore model: open files, the active one, cursors (Monaco, decision #80).
@Suite struct EditorModelTests {
    private func state() -> (WorkspaceState, task: UUID, leaf: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .editor, openFile: "/repo/a.ts", openLine: 3)
        return (s, t, s.tasks[0].tabs[0].root.leaves[0].id)
    }

    private func leaf(_ s: WorkspaceState) -> Leaf { s.tasks[0].tabs[0].root.leaves[0] }

    @Test func newEditorTabHasItsFile() {
        let (s, _, _) = state()
        #expect(leaf(s).editorFiles == [EditorFile(path: "/repo/a.ts", line: 3, column: 1)])
        #expect(leaf(s).openFile == "/repo/a.ts")
    }

    @Test func openAddsOnceAndActivates() {
        var (s, _, id) = state()
        s.openEditorFile(leafId: id, path: "/repo/b.ts", line: 7, column: 2)
        s.openEditorFile(leafId: id, path: "/repo/a.ts", line: nil, column: nil)
        #expect(leaf(s).editorFiles?.map(\.path) == ["/repo/a.ts", "/repo/b.ts"])
        #expect(leaf(s).openFile == "/repo/a.ts")
        #expect(leaf(s).editorFiles?[0].line == 3)  // reopening without a line keeps the cursor
        s.openEditorFile(leafId: id, path: "/repo/b.ts", line: 9, column: nil)
        #expect(leaf(s).editorFiles?[1] == EditorFile(path: "/repo/b.ts", line: 9, column: 1))
    }

    @Test func closeActivatesNeighbourAndReportsEmpty() {
        var (s, _, id) = state()
        s.openEditorFile(leafId: id, path: "/repo/b.ts", line: nil, column: nil)
        s.openEditorFile(leafId: id, path: "/repo/c.ts", line: nil, column: nil)
        s.activateEditorFile(leafId: id, path: "/repo/b.ts")
        #expect(s.closeEditorFile(leafId: id, path: "/repo/b.ts") == false)
        #expect(leaf(s).openFile == "/repo/c.ts")  // the one to the right, as in VS Code
        #expect(s.closeEditorFile(leafId: id, path: "/repo/c.ts") == false)
        #expect(leaf(s).openFile == "/repo/a.ts")
        #expect(s.closeEditorFile(leafId: id, path: "/repo/a.ts") == true)
        #expect(leaf(s).editorFiles == [])
        #expect(leaf(s).openFile == nil)
    }

    @Test func cursorIsSavedAndClamped() {
        var (s, _, id) = state()
        s.setEditorCursor(leafId: id, path: "/repo/a.ts", line: 12, column: 5)
        #expect(leaf(s).editorFiles?[0] == EditorFile(path: "/repo/a.ts", line: 12, column: 5))
        s.setEditorCursor(leafId: id, path: "/repo/a.ts", line: -4, column: 0)
        #expect(leaf(s).editorFiles?[0] == EditorFile(path: "/repo/a.ts", line: 1, column: 1))
        s.setEditorCursor(leafId: id, path: "/repo/zzz.ts", line: 2, column: 2)  // not open: ignored
        #expect(leaf(s).editorFiles?.count == 1)
    }

    @Test func restoresThroughJSON() throws {
        var (s, _, id) = state()
        s.openEditorFile(leafId: id, path: "/repo/b.ts", line: 4, column: 8)
        s.diffInline = true
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(leaf(back).editorFiles?.map(\.path) == ["/repo/a.ts", "/repo/b.ts"])
        #expect(back.diffInline)
    }

    /// A Helix-era editor leaf (openFile only) opens that one file; a state without `diffInline` is side by side.
    @Test func legacyStatesDecode() throws {
        let json = """
        {"projects":[],"tasks":[],"inspectorVisible":false}
        """
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8)).diffInline == false)
        let old = Leaf(kind: .editor, cwd: "/r", openFile: "/r/x.swift", openLine: 5)
        #expect(old.editorFileList == [EditorFile(path: "/r/x.swift", line: 5, column: 1)])
        #expect(Leaf(kind: .editor, cwd: "/r").editorFileList == [])
    }
}
