import Foundation
import Testing
@testable import Workspace

@Suite struct ModelTests {
    private func makeState() -> (WorkspaceState, UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        return (s, p)
    }

    @Test func addTaskAppendsInOrder() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        #expect(s.tasks.map(\.order) == [0, 1])
        #expect(s.tasks(in: p).map(\.id) == [a, b])
    }

    @Test func taskNamesAreNotIdentifiers() {
        var (s, p) = makeState()
        let ids = ["fix auth", "исправить/логин", "fix auth"].map { s.addTask(projectId: p, name: $0) }
        #expect(Set(ids).count == 3)
        #expect(s.tasks.count == 3)
    }

    @Test func newTaskCwdIsProjectPath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .claude)
        guard case .leaf(let leaf) = s.tasks[0].tabs[0].root else { Issue.record("not a leaf"); return }
        #expect(leaf.cwd == "/repo/app")
        #expect(leaf.kind == .claude)
        #expect(s.tasks[0].tabs[0].title == "claude")
        #expect(s.tasks[0].activeTabId == s.tasks[0].tabs[0].id)
    }

    @Test func worktreeCwdIsWorktreePath() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        s.tasks[0].mode = .worktree(path: "/wt/t", branch: "t", base: "main")
        s.addTab(taskId: t, kind: .shell)
        #expect(s.tasks[0].tabs[0].root.leaves[0].cwd == "/wt/t")
    }

    @Test func closeLastLeafClosesTab() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        let first = s.tasks[0].tabs[0].root.leaves[0].id
        let second = s.split(taskId: t, tabId: tab, leafId: first, axis: .horizontal, kind: .shell)
        #expect(s.tasks[0].tabs[0].root.leaves.count == 2)
        #expect(s.tasks[0].tabs[0].focusedLeafId == second)
        guard case .split(.horizontal, 0.5, _, _) = s.tasks[0].tabs[0].root else { Issue.record("not a split"); return }

        s.closeLeaf(taskId: t, tabId: tab, leafId: second)
        guard case .leaf(let rest) = s.tasks[0].tabs[0].root else { Issue.record("not a leaf"); return }
        #expect(rest.id == first)
        #expect(s.tasks[0].tabs[0].focusedLeafId == first)

        s.closeLeaf(taskId: t, tabId: tab, leafId: first)
        #expect(s.tasks[0].tabs.isEmpty)
        #expect(s.tasks[0].activeTabId == nil)
    }

    @Test func closeLastLeafActivatesNeighborTab() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .shell)
        let leaf = s.tasks[0].tabs[1].root.leaves[0].id
        s.closeLeaf(taskId: t, tabId: b, leafId: leaf)
        #expect(s.tasks[0].activeTabId == a)
    }

    @Test func closeActiveTabSelectsNeighbor() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .codex)
        let c = s.addTab(taskId: t, kind: .shell)
        s.tasks[0].activeTabId = b
        s.closeTab(taskId: t, tabId: b)
        #expect(s.tasks[0].activeTabId == c)
        s.closeTab(taskId: t, tabId: c)
        #expect(s.tasks[0].activeTabId == a)
    }

    @Test func closeInactiveTabKeepsActive() {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .codex)
        s.closeTab(taskId: t, tabId: a)
        #expect(s.tasks[0].activeTabId == b)
    }

    @Test func moveTaskRenumbers() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        let c = s.addTask(projectId: p, name: "c")
        s.moveTask(id: c, to: 0)
        #expect(s.tasks(in: p).map(\.id) == [c, a, b])
        #expect(s.tasks(in: p).map(\.order) == [0, 1, 2])
    }

    @Test func moveTaskIgnoresArchivedSiblings() {
        var (s, p) = makeState()
        let x = s.addTask(projectId: p, name: "X")
        s.addTask(projectId: p, name: "A")
        s.addTask(projectId: p, name: "B")
        s.addTask(projectId: p, name: "C")
        s.archiveTask(id: x)
        let a = s.tasks(in: p)[0].id
        s.moveTask(id: a, to: 1)
        #expect(s.tasks(in: p).map(\.name) == ["B", "A", "C"])
        #expect(s.tasks.first { $0.id == x }?.order == 0)
        #expect(s.tasks.map(\.order).sorted() == [0, 1, 2, 3])
    }

    @Test func moveTaskToEnd() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "A")
        s.addTask(projectId: p, name: "B")
        s.addTask(projectId: p, name: "C")
        s.moveTask(id: a, to: 2)
        #expect(s.tasks(in: p).map(\.name) == ["B", "C", "A"])
        s.moveTask(id: a, to: 0)
        s.moveTask(id: a, to: 99)
        #expect(s.tasks(in: p).map(\.name) == ["B", "C", "A"])
    }

    @Test func archivedTasksHidden() {
        var (s, p) = makeState()
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        s.select(taskId: a)
        s.archiveTask(id: a)
        #expect(s.tasks(in: p).map(\.id) == [b])
        #expect(s.selectedTaskId == nil)
        #expect(s.tasks.count == 2)
    }

    @Test func roundTripCodable() throws {
        var (s, p) = makeState()
        let t = s.addTask(projectId: p, name: "t")
        let tab = s.addTab(taskId: t, kind: .claude)
        let l1 = s.tasks[0].tabs[0].root.leaves[0].id
        let l2 = s.split(taskId: t, tabId: tab, leafId: l1, axis: .horizontal, kind: .codex)
        let l3 = s.split(taskId: t, tabId: tab, leafId: l2, axis: .vertical, kind: .editor)
        s.split(taskId: t, tabId: tab, leafId: l3, axis: .vertical, kind: .shell)
        s.tasks[0].mode = .worktree(path: "/wt", branch: "b", base: "main")
        s.projects[0].lastBaseBranch = "main"
        s.select(taskId: t)
        s.inspectorVisible = true
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == s)
        #expect(Set(s.tasks[0].tabs[0].root.leaves.map(\.kind)) == [.claude, .codex, .editor, .shell])
    }
}
