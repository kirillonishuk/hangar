import Foundation
import Testing
@testable import Workspace

/// One Hangar tab per open file (VS Code-like), with one reusable preview tab (decision #83).
@Suite struct FileTabsTests {
    private func state() -> (WorkspaceState, task: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .claude)
        return (s, t)
    }

    private func req<T>(_ v: T?) throws -> T { try #require(v) }

    private func files(_ s: WorkspaceState) -> [String?] { s.tasks[0].tabs.map { $0.root.leaves.first { $0.kind == .editor }?.openFile } }

    @Test func eachFileIsItsOwnTabAfterTheActiveOne() throws {
        var (s, t) = state()
        let a = try req(s.openFileTab(taskId: t, path: "/repo/a.ts", line: 3, column: nil, preview: false))
        let b = try req(s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: false))
        #expect(files(s) == [nil, "/repo/a.ts", "/repo/b.ts"])
        #expect(s.tasks[0].activeTabId == b.tab)
        // From the first tab, a new file opens right after it (as in VS Code).
        s.tasks[0].activeTabId = s.tasks[0].tabs[0].id
        _ = s.openFileTab(taskId: t, path: "/repo/c.ts", line: nil, column: nil, preview: false)
        #expect(files(s) == [nil, "/repo/c.ts", "/repo/a.ts", "/repo/b.ts"])
        let leaf = s.tasks[0].tabs[2].root.leaves[0]
        #expect(leaf.id == a.leaf && leaf.kind == .editor && leaf.editorFiles == [EditorFile(path: "/repo/a.ts", line: 3, column: 1)])
        #expect(s.tasks[0].tabs[2].preview == false)
    }

    @Test func anOpenFileFocusesItsTabAndMovesTheCursor() throws {
        var (s, t) = state()
        let a = try req(s.openFileTab(taskId: t, path: "/repo/a.ts", line: 3, column: nil, preview: false))
        _ = s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: false)
        let again = try req(s.openFileTab(taskId: t, path: "/repo/a.ts", line: 9, column: 2, preview: true))
        #expect(again.tab == a.tab && again.leaf == a.leaf)
        #expect(s.tasks[0].tabs.count == 3)
        #expect(s.tasks[0].activeTabId == a.tab)
        #expect(s.tasks[0].tabs[1].root.leaves[0].editorFiles == [EditorFile(path: "/repo/a.ts", line: 9, column: 2)])
        #expect(s.tasks[0].tabs[1].preview == false)  // a pinned tab stays pinned
        #expect(s.fileTab(taskId: t, path: "/repo/b.ts")?.tab == s.tasks[0].tabs[2].id)
        #expect(s.fileTab(taskId: t, path: "/repo/zzz.ts") == nil)
    }

    /// One preview tab per task: the next preview replaces its file; editing or a pinned open keeps it.
    @Test func thePreviewTabIsReusedUntilPinned() throws {
        var (s, t) = state()
        let a = try req(s.openFileTab(taskId: t, path: "/repo/a.ts", line: nil, column: nil, preview: true))
        #expect(s.tasks[0].tabs[1].preview)
        let b = try req(s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: true))
        #expect(b.tab == a.tab && b.leaf != a.leaf)  // a new leaf: the old file's buffer goes
        #expect(files(s) == [nil, "/repo/b.ts"])
        // Opening the previewed file for real pins it; the next preview gets a tab of its own.
        _ = s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: false)
        #expect(s.tasks[0].tabs[1].preview == false)
        let c = try req(s.openFileTab(taskId: t, path: "/repo/c.ts", line: nil, column: nil, preview: true))
        #expect(c.tab != b.tab && files(s) == [nil, "/repo/b.ts", "/repo/c.ts"])
        s.pinTab(taskId: t, tabId: c.tab)
        #expect(s.tasks[0].tabs[2].preview == false)
        _ = s.openFileTab(taskId: t, path: "/repo/d.ts", line: nil, column: nil, preview: true)
        #expect(files(s) == [nil, "/repo/b.ts", "/repo/c.ts", "/repo/d.ts"])
    }

    @Test func previewSurvivesJSONAndIsOmittedWhenOff() throws {
        var (s, t) = state()
        _ = s.openFileTab(taskId: t, path: "/repo/a.ts", line: nil, column: nil, preview: true)
        _ = s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: false)
        let data = try JSONEncoder().encode(s)
        #expect(String(decoding: data, as: UTF8.self).components(separatedBy: "\"preview\"").count == 2)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(back == s)
        #expect(back.tasks[0].tabs.map(\.preview) == [false, true, false])
    }

    /// state.json of the multi-file editor tab (#80): each file becomes its own tab with its cursor; the active file
    /// keeps the original tab (and its place, its split), the others follow it in their order.
    @Test func multiFileEditorTabsSplitIntoFileTabs() throws {
        var (s, t) = state()
        let editor = s.addTab(taskId: t, kind: .shell)
        let leafId = s.tasks[0].tabs[1].root.leaves[0].id
        let files3 = [EditorFile(path: "/repo/a.ts", line: 2, column: 3), EditorFile(path: "/repo/b.ts", line: 5, column: 1),
                      EditorFile(path: "/repo/c.ts", line: 7, column: 4)]
        s.tasks[0].tabs[1].root = .split(axis: .horizontal, ratio: 0.5,
            first: .leaf(Leaf(id: leafId, kind: .editor, cwd: "/repo")), second: .leaf(Leaf(kind: .shell, cwd: "/repo")))
        s.tasks[0].tabs[1].root = s.tasks[0].tabs[1].root.mapLeaves { leaf in
            var leaf = leaf
            if leaf.id == leafId { leaf.editorFiles = files3; leaf.openFile = "/repo/b.ts" }
            return leaf
        }
        s.addTab(taskId: t, kind: .codex)
        s.tasks[0].activeTabId = editor
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        let tabs = back.tasks[0].tabs
        #expect(tabs.count == 5)
        #expect(tabs[1].id == editor && tabs[1].root.leaves.count == 2)  // the split stays with the active file
        #expect(tabs[1].root.leaves[0].id == leafId)
        #expect(tabs[1].root.leaves[0].editorFiles == [files3[1]] && tabs[1].root.leaves[0].openFile == "/repo/b.ts")
        #expect(tabs[2].root.leaves.map(\.editorFiles) == [[files3[0]]] && tabs[2].root.leaves[0].openFile == "/repo/a.ts")
        #expect(tabs[3].root.leaves.map(\.editorFiles) == [[files3[2]]] && tabs[3].root.leaves[0].openFile == "/repo/c.ts")
        #expect(tabs[3].focusedLeafId == tabs[3].root.leaves[0].id)
        #expect(tabs[4].root.leaves[0].kind == .codex)
        #expect(back.tasks[0].activeTabId == editor)
        // Already one file per tab: nothing changes.
        let again = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(back))
        #expect(again == back)
    }
}
