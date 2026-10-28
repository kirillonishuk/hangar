import Foundation
import Testing
@testable import Workspace

/// Pane names, chooser leaves and edge inserts (splits spec).
@Suite struct SplitOpsTests {
    private func state() -> (WorkspaceState, task: UUID, tab: UUID, leaf: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        return (s, t, tab, s.tasks[0].tabs[0].root.leaves[0].id)
    }

    @Test func customTitleRoundTripsAndOldLeafDecodes() throws {
        var leaf = Leaf(kind: .shell, cwd: "/repo")
        leaf.customTitle = "api"
        let back = try JSONDecoder().decode(Leaf.self, from: JSONEncoder().encode(leaf))
        #expect(back == leaf && back.customTitle == "api")
        let old = #"{"id":"\#(UUID().uuidString)","kind":"shell","cwd":"/repo"}"#
        #expect(try JSONDecoder().decode(Leaf.self, from: Data(old.utf8)).customTitle == nil)
    }

    @Test func insertingAtEachEdge() {
        let a = Leaf(kind: .claude, cwd: "/"), b = Leaf(kind: .shell, cwd: "/")
        let cases: [(SplitEdge, Axis, Bool)] = [(.left, .horizontal, true), (.right, .horizontal, false),
                                                (.top, .vertical, true), (.bottom, .vertical, false)]
        for (edge, axis, bFirst) in cases {
            #expect(edge.axis == axis && edge.isFirst == bFirst)
            let r = SplitNode.leaf(a).inserting(.leaf(b), at: a.id, edge: edge)
            let expected: SplitNode = .split(axis: axis, ratio: 0.5, first: .leaf(bFirst ? b : a), second: .leaf(bFirst ? a : b))
            #expect(r == expected)
        }
    }

    @Test func splitWithoutKindMakesChooser() throws {
        var (s, t, tab, leaf) = state()
        let c = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        #expect(s.tasks[0].tabs[0].root.leaf(id: c)?.kind == .choose)
        #expect(s.tasks[0].tabs[0].focusedLeafId == c)
        #expect(s.tasks[0].tabs[0].root.leaves.map(\.id) == [leaf, c])
        let f = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .vertical, kind: nil, first: true)
        #expect(s.tasks[0].tabs[0].root.leaves.map(\.id).first == f)

        var h = WorkspaceState()
        let host = h.openHostShell(host: "box")
        let hl = h.hostShellTask(host: "box")!.tabs[0].root.leaves[0].id
        let n = h.split(taskId: host.task, tabId: host.tab, leafId: hl, axis: .horizontal, kind: nil)
        #expect(h.hostShellTask(host: "box")!.tabs[0].root.leaf(id: n)?.kind == .shell)
    }

    @Test func chooseKindTurnsChooserIntoAgent() {
        var (s, t, tab, leaf) = state()
        let c = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        let ok1 = s.chooseKind(leafId: c, kind: .codex)
        #expect(ok1)
        #expect(s.tasks[0].tabs[0].root.leaf(id: c)?.kind == .codex)
        let before = s
        let ok2 = s.chooseKind(leafId: c, kind: .shell)
        #expect(!ok2)
        let ok3 = s.chooseKind(leafId: leaf, kind: .shell)
        #expect(!ok3)
        #expect(s == before)
    }

    @Test func chooseEditorRefusesDuplicateFileAndCap() throws {
        var (s, t, tab, leaf) = state()
        _ = s.openFileTab(taskId: t, path: "/repo/a.ts", line: nil, column: nil, preview: false)
        let c1 = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        let ok4 = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/a.ts")
        #expect(!ok4)
        let ok5 = s.chooseKind(leafId: c1, kind: .editor)
        #expect(!ok5)
        #expect(s.tasks[0].tabs[0].root.leaf(id: c1)?.kind == .choose)
        let ok6 = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/b.ts")
        #expect(ok6)
        let e = try #require(s.tasks[0].tabs[0].root.leaf(id: c1))
        #expect(e.openFile == "/repo/b.ts" && e.editorFiles == [EditorFile(path: "/repo/b.ts", line: 1, column: 1)])
        let c2 = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        let ok7 = s.chooseKind(leafId: c2, kind: .editor, file: "/repo/c.ts")
        #expect(ok7)
        #expect(s.tasks[0].tabs[0].editorCount == Tab.maxEditorPanes)
        let c3 = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        let ok8 = s.chooseKind(leafId: c3, kind: .editor, file: "/repo/d.ts")
        #expect(!ok8)
    }

    @Test func renameLeafTrimsAndClears() {
        var (s, _, _, leaf) = state()
        s.renameLeaf(leafId: leaf, title: "  api ")
        #expect(s.tasks[0].tabs[0].root.leaf(id: leaf)?.customTitle == "api")
        s.renameLeaf(leafId: leaf, title: "  ")
        #expect(s.tasks[0].tabs[0].root.leaf(id: leaf)?.customTitle == nil)
        s.renameLeaf(leafId: leaf, title: "x")
        s.renameLeaf(leafId: leaf, title: nil)
        #expect(s.tasks[0].tabs[0].root.leaf(id: leaf)?.customTitle == nil)
    }

    @Test func prunedChoosersDropsChooserOnlyTab() {
        var (s, t, tab, leaf) = state()
        let second = s.addTab(taskId: t, kind: .shell)
        let sl = s.tasks[0].tabs[1].root.leaves[0].id
        _ = s.split(taskId: t, tabId: second, leafId: sl, axis: .horizontal, kind: nil)
        // Turn the first tab into a lone chooser.
        let c = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        s.closeLeaf(taskId: t, tabId: tab, leafId: leaf)
        #expect(s.tasks[0].tabs[0].root == .leaf(Leaf(id: c, kind: .choose, cwd: "/repo")))
        s.tasks[0].activeTabId = tab
        let p = s.prunedChoosers()
        #expect(p.tasks[0].tabs.map(\.id) == [second])
        #expect(p.tasks[0].activeTabId == second)
        #expect(p.tasks[0].tabs[0].root == .leaf(Leaf(id: sl, kind: .shell, cwd: "/repo")))
        #expect(p.tasks[0].tabs[0].focusedLeafId == sl)
    }
}
