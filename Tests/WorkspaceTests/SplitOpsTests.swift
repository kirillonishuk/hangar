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

    @Test func prunedChoosersHandlesSeveralChoosersInOneTab() {
        var (s, t, tab, leaf) = state()
        let c1 = s.split(taskId: t, tabId: tab, leafId: leaf, axis: .horizontal, kind: nil)
        let c2 = s.split(taskId: t, tabId: tab, leafId: c1, axis: .vertical, kind: nil)
        let p = s.prunedChoosers()
        #expect(p.tasks[0].tabs[0].root == .leaf(Leaf(id: leaf, kind: .claude, cwd: "/repo")))
        #expect(p.tasks[0].tabs[0].focusedLeafId == leaf)
        #expect(s.tasks[0].tabs[0].root.leaf(id: c2) != nil)
    }

    // MARK: merge / move / detach

    /// Two tabs A (claude) and B (shell) in one task.
    private func two() -> (s: WorkspaceState, t: UUID, a: UUID, b: UUID, al: UUID, bl: UUID) {
        var (s, t, a, al) = state()
        let b = s.addTab(taskId: t, kind: .shell)
        return (s, t, a, b, al, s.tasks[0].tabs[1].root.leaves[0].id)
    }

    @Test func mergeFromEachEdgeKeepsLeafIds() throws {
        for edge in [SplitEdge.left, .right, .top, .bottom] {
            var (s, t, a, b, al, bl) = two()
            let ok = s.mergeTab(taskId: t, source: b, into: a, at: al, edge: edge)
            #expect(ok)
            let tab = s.tasks[0].tabs[0]
            #expect(s.tasks[0].tabs.count == 1 && tab.id == a)
            #expect(Set(tab.root.leaves.map(\.id)) == [al, bl])
            let first = tab.root.leaves.map(\.id).first
            #expect(first == (edge.isFirst ? bl : al))
            guard case .split(let axis, let ratio, _, _) = tab.root else { Issue.record("not split"); return }
            #expect(axis == edge.axis && ratio == 0.5)
            #expect(tab.focusedLeafId == bl && s.tasks[0].activeTabId == a)
        }
    }

    @Test func mergeIntoItselfIsRejected() {
        var (s, t, a, b, al, _) = two()
        let before = s
        let ok1 = s.mergeTab(taskId: t, source: a, into: a, at: al, edge: .right)
        #expect(!ok1 && !s.canMergeTab(taskId: t, source: a, into: a))
        #expect(s == before)
        var other = s
        let p = other.addProject(name: "o", path: "/o")
        let t2 = other.addTask(projectId: p, name: "t2")
        let x = other.addTab(taskId: t2, kind: .shell)
        let ok2 = other.mergeTab(taskId: t, source: x, into: a, at: al, edge: .right)
        #expect(!ok2 && !other.canMergeTab(taskId: t, source: b, into: x))
    }

    @Test func mergeIntoPreviewTabPinsIt() throws {
        var (s, t, _, b, _, _) = two()
        let p0 = s.openFileTab(taskId: t, path: "/repo/a.ts", line: nil, column: nil, preview: true)
        let p = try #require(p0)
        #expect(s.tasks[0].tabs.first { $0.id == p.tab }?.preview == true)
        let ok = s.mergeTab(taskId: t, source: b, into: p.tab, at: p.leaf, edge: .right)
        #expect(ok)
        #expect(s.tasks[0].tabs.first { $0.id == p.tab }?.preview == false)
        let q0 = s.openFileTab(taskId: t, path: "/repo/b.ts", line: nil, column: nil, preview: true)
        let q = try #require(q0)
        #expect(q.tab != p.tab)
        #expect(s.tasks[0].tabs.first { $0.id == p.tab }?.root.leaf(id: p.leaf) != nil)
    }

    @Test func mergeCarriesTabNameToLeaf() {
        var (s, t, a, b, al, bl) = two()
        s.tasks[0].tabs[1].customTitle = "srv"
        _ = s.mergeTab(taskId: t, source: b, into: a, at: al, edge: .right)
        #expect(s.tasks[0].tabs[0].root.leaf(id: bl)?.customTitle == "srv")
        // A leaf's own name wins.
        var (s2, t2, a2, b2, al2, bl2) = two()
        s2.renameLeaf(leafId: bl2, title: "own")
        s2.tasks[0].tabs[1].customTitle = "srv"
        _ = s2.mergeTab(taskId: t2, source: b2, into: a2, at: al2, edge: .right)
        #expect(s2.tasks[0].tabs[0].root.leaf(id: bl2)?.customTitle == "own")
    }

    @Test func mergeRespectsEditorCap() {
        var (s, t, a, leaf) = state()
        let c1 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        let c2 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        _ = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/x.ts")
        _ = s.chooseKind(leafId: c2, kind: .editor, file: "/repo/y.ts")
        let f = s.openFileTab(taskId: t, path: "/repo/z.ts", line: nil, column: nil, preview: false)!
        let before = s
        #expect(!s.canMergeTab(taskId: t, source: f.tab, into: a))
        let ok = s.mergeTab(taskId: t, source: f.tab, into: a, at: leaf, edge: .right)
        #expect(!ok && s == before)
    }

    @Test func moveLeafWithinTab() {
        var (s, t, a, al) = state()
        let b = s.split(taskId: t, tabId: a, leafId: al, axis: .horizontal, kind: .shell)
        let c = s.split(taskId: t, tabId: a, leafId: b, axis: .horizontal, kind: .codex)
        let ok = s.moveLeaf(taskId: t, leafId: c, to: a, at: al, edge: .top)
        #expect(ok && s.tasks[0].tabs.count == 1)
        #expect(Set(s.tasks[0].tabs[0].root.leaves.map(\.id)) == [al, b, c])
        #expect(s.tasks[0].tabs[0].root.leaves.map(\.id).first == c)
        #expect(s.tasks[0].tabs[0].focusedLeafId == c)
    }

    @Test func moveLeafToOtherTabRemovesEmptySource() {
        var (s, t, a, b, al, bl) = two()
        let b2 = s.split(taskId: t, tabId: b, leafId: bl, axis: .horizontal, kind: .codex)
        #expect(s.canMoveLeaf(taskId: t, leafId: bl, to: a, anchor: al))
        let m1 = s.moveLeaf(taskId: t, leafId: bl, to: a, at: al, edge: .right)
        #expect(m1)
        #expect(s.tasks[0].tabs.count == 2)
        #expect(s.tasks[0].tabs[1].focusedLeafId == b2)
        let m2 = s.moveLeaf(taskId: t, leafId: b2, to: a, at: bl, edge: .bottom)
        #expect(m2)
        #expect(s.tasks[0].tabs.map(\.id) == [a])
        #expect(s.tasks[0].activeTabId == a)
        #expect(Set(s.tasks[0].tabs[0].root.leaves.map(\.id)) == [al, bl, b2])
        #expect(s.tasks[0].tabs[0].focusedLeafId == b2)
    }

    @Test func moveLeafOntoItselfIsRejected() {
        var (s, t, a, al) = state()
        let b = s.split(taskId: t, tabId: a, leafId: al, axis: .horizontal, kind: .shell)
        let before = s
        #expect(!s.canMoveLeaf(taskId: t, leafId: b, to: a, anchor: b))
        let ok = s.moveLeaf(taskId: t, leafId: b, to: a, at: b, edge: .left)
        #expect(!ok && s == before)
    }

    @Test func moveLeafRespectsEditorCap() {
        var (s, t, a, al) = state()
        let c1 = s.split(taskId: t, tabId: a, leafId: al, axis: .horizontal, kind: nil)
        let c2 = s.split(taskId: t, tabId: a, leafId: al, axis: .horizontal, kind: nil)
        _ = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/x.ts")
        _ = s.chooseKind(leafId: c2, kind: .editor, file: "/repo/y.ts")
        let f = s.openFileTab(taskId: t, path: "/repo/z.ts", line: nil, column: nil, preview: false)!
        #expect(!s.canMoveLeaf(taskId: t, leafId: f.leaf, to: a, anchor: al))
        // Within the full tab itself the count does not change.
        #expect(s.canMoveLeaf(taskId: t, leafId: c1, to: a, anchor: al))
    }

    @Test func detachLeafCreatesNamedTab() {
        var (s, t, a, al) = state()
        let b = s.split(taskId: t, tabId: a, leafId: al, axis: .horizontal, kind: .shell)
        s.renameLeaf(leafId: b, title: "logs")
        let extra = s.addTab(taskId: t, kind: .codex)
        let n = s.detachLeaf(taskId: t, leafId: b, toIndex: nil)
        #expect(n != nil)
        #expect(s.tasks[0].tabs.map(\.id) == [a, n!, extra])
        #expect(s.tasks[0].tabs[1].customTitle == "logs" && s.tasks[0].activeTabId == n)
        #expect(s.tasks[0].tabs[1].root.leaves.map(\.id) == [b] && s.tasks[0].tabs[0].root.leaves.map(\.id) == [al])
        #expect(s.tasks[0].tabs[0].focusedLeafId == al)
        // From a lone-leaf tab: nothing.
        let again = s.detachLeaf(taskId: t, leafId: b, toIndex: nil)
        #expect(again == nil)

        var (s2, t2, a2, al2) = state()
        let b2 = s2.split(taskId: t2, tabId: a2, leafId: al2, axis: .horizontal, kind: .shell)
        let n2 = s2.detachLeaf(taskId: t2, leafId: b2, toIndex: 0)
        #expect(s2.tasks[0].tabs.first?.id == n2)
    }
}
