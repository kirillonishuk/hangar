import Foundation
import Testing
@testable import HangarUI
@testable import Workspace

/// Drag a tab onto a pane edge (splits spec §2): zones and target resolution, no window.
@MainActor @Suite struct PaneDragTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    /// Session with tabs A (active, claude leaf a) and B (shell).
    private func two() -> (s: WorkspaceState, t: UUID, a: UUID, b: UUID, al: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .shell)
        s.tasks[0].activeTabId = a
        return (s, t, a, b, s.tasks[0].tabs[0].root.leaves[0].id)
    }

    @Test func dropEdgeZones() {
        #expect(dropEdge(in: rect, at: CGPoint(x: 10, y: 100)) == .left)
        #expect(dropEdge(in: rect, at: CGPoint(x: 390, y: 100)) == .right)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 10)) == .top)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 190)) == .bottom)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 100)) == nil)
        #expect(dropEdge(in: rect, at: CGPoint(x: 500, y: 100)) == nil)
        // In a corner both zones apply: the nearer side by its share of the pane wins.
        #expect(dropEdge(in: rect, at: CGPoint(x: 20, y: 5)) == .top)
    }

    @Test func tabDropOnOtherTabsPane() {
        let (s, t, a, b, al) = two()
        let target = resolveDrop(.tab(b), at: CGPoint(x: 390, y: 100), state: s, taskId: t, activeTab: a,
                                 paneFrames: [al: rect], tabBar: nil, tabFrames: [:])
        #expect(target == .edge(tab: a, leaf: al, .right))
        // Outside every pane, or in its middle: nothing.
        #expect(resolveDrop(.tab(b), at: CGPoint(x: 200, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
        #expect(resolveDrop(.tab(b), at: CGPoint(x: 900, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
    }

    @Test func dropOnOwnPanesIsNil() {
        let (s, t, a, _, al) = two()
        for p in [CGPoint(x: 10, y: 100), CGPoint(x: 390, y: 100), CGPoint(x: 200, y: 10), CGPoint(x: 200, y: 190)] {
            #expect(resolveDrop(.tab(a), at: p, state: s, taskId: t, activeTab: a, paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
        }
    }

    /// The diff tab or «Сессии» on screen: `paneFrames` is empty (ruling R3).
    @Test func noPaneTargetsWhileDiffShown() {
        let (s, t, a, b, _) = two()
        for x in stride(from: 0.0, through: 400, by: 50) {
            for y in stride(from: 0.0, through: 200, by: 50) {
                #expect(resolveDrop(.tab(b), at: CGPoint(x: x, y: y), state: s, taskId: t, activeTab: a,
                                    paneFrames: [:], tabBar: nil, tabFrames: [:]) == nil)
            }
        }
    }

    @Test func tabDropRespectsEditorCap() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let leaf = s.tasks[0].tabs[0].root.leaves[0].id
        let c1 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        let c2 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        _ = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/x.ts")
        _ = s.chooseKind(leafId: c2, kind: .editor, file: "/repo/y.ts")
        let f0 = s.openFileTab(taskId: t, path: "/repo/z.ts", line: nil, column: nil, preview: false)
        let f = try #require(f0)
        s.tasks[0].activeTabId = a
        #expect(resolveDrop(.tab(f.tab), at: CGPoint(x: 390, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [leaf: rect], tabBar: nil, tabFrames: [:]) == nil)
    }

    /// Task 7 adds pane-header drags; until then a leaf source has no target.
    @Test func leafSourceHasNoTargetYet() {
        let (s, t, a, _, al) = two()
        #expect(resolveDrop(.leaf(al), at: CGPoint(x: 390, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
    }

    @Test func dropLabels() {
        let saved = L10n.language
        defer { L10n.language = saved }
        L10n.language = .ru
        #expect([SplitEdge.right, .left, .top, .bottom].map(paneDropLabel) == ["Вправо", "Влево", "Вверх", "Вниз"])
        L10n.language = .en
        #expect([SplitEdge.right, .left, .top, .bottom].map(paneDropLabel) == ["Right", "Left", "Up", "Down"])
    }
}
