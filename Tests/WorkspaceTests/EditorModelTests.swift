import Foundation
import Testing
@testable import Workspace

/// A file tab's restore model: its file and cursor (Monaco, decisions #80, #83).
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
        s.setEditorCursor(leafId: id, path: "/repo/a.ts", line: 4, column: 8)
        s.diffInline = true
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(leaf(back).editorFiles == [EditorFile(path: "/repo/a.ts", line: 4, column: 8)])
        #expect(back.diffInline)
    }

    /// A state without `diffInline` is side by side.
    @Test func legacyStatesDecode() throws {
        let json = """
        {"projects":[],"tasks":[],"inspectorVisible":false}
        """
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8)).diffInline == false)
        #expect(Leaf(kind: .editor, cwd: "/r").editorFileList == [])
    }

    /// state.json from the Helix era: an editor leaf with only `openFile` + `openLine` loads as a Monaco editor tab on
    /// that file and line (no line → line 1, no file → an empty editor); saved again, the Helix field is gone.
    @Test func helixEditorLeavesMigrate() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .editor, openFile: "/repo/x.swift")
        s.addTab(taskId: t, kind: .editor, openFile: "/repo/y.swift")
        s.addTab(taskId: t, kind: .editor)
        s.addTab(taskId: t, kind: .shell)
        // Rewrite the editor leaves the way Helix-era Hangar saved them: openFile + openLine, no editorFiles.
        var lines = [5, nil, nil]
        func helixEra(_ any: Any) -> Any {
            if var d = any as? [String: Any] {
                if d["kind"] as? String == "editor" {
                    d["editorFiles"] = nil
                    if let line = lines.removeFirst() { d["openLine"] = line }
                    return d
                }
                return d.mapValues(helixEra)
            }
            if let a = any as? [Any] { return a.map(helixEra) }
            return any
        }
        let saved = try JSONSerialization.data(withJSONObject: helixEra(JSONSerialization.jsonObject(with: JSONEncoder().encode(s))))
        #expect(!String(decoding: saved, as: UTF8.self).contains("editorFiles"))
        let back = try JSONDecoder().decode(WorkspaceState.self, from: saved)
        let leaves = back.tasks[0].tabs.map { $0.root.leaves[0] }
        #expect(leaves.map(\.kind) == [.editor, .editor, .editor, .shell])
        #expect(leaves[0].editorFiles == [EditorFile(path: "/repo/x.swift", line: 5, column: 1)])
        #expect(leaves[0].openFile == "/repo/x.swift")
        #expect(leaves[1].editorFiles == [EditorFile(path: "/repo/y.swift", line: 1, column: 1)])
        #expect(leaves[2].editorFiles == nil && leaves[2].openFile == nil)
        #expect(leaves[3].editorFiles == nil)
        let again = String(decoding: try JSONEncoder().encode(back), as: UTF8.self)
        #expect(!again.contains("openLine"))
    }
}
