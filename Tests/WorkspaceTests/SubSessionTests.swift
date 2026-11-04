import Foundation
import Testing
@testable import Workspace

/// Sub-sessions in the model (#128, #130): where they live, the sidebar order, persistence.
@Suite struct SubSessionTests {
    private func sub(_ s: inout WorkspaceState, parent: UUID, name: String, kind: LeafKind,
                     mode: TaskMode? = nil) throws -> (task: UUID, tab: UUID) {
        let r = s.addSubSession(parent: parent, name: name, kind: kind, mode: mode)
        return try #require(r)
    }

    @Test func projectSubSessionKeepsTheSelection() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let parent = s.addTask(projectId: p, name: "Main")
        s.select(taskId: parent)
        let child = try sub(&s, parent: parent, name: "Release", kind: .codex,
                                               mode: .worktree(path: "/tmp/app-r", branch: "r", base: "main"))
        let task = try #require(s.tasks.first { $0.id == child.task })
        #expect(task.projectId == p && task.parentTaskId == parent && task.branch == "r")
        #expect(task.tabs.first?.root.leaves.first?.kind == .codex && task.activeTabId == child.tab)
        #expect(s.selectedTaskId == parent)
        #expect(s.subSessions(of: parent).map(\.id) == [child.task])
        #expect(s.hasLiveParent(task))
        #expect(s.addSubSession(parent: UUID(), name: "x", kind: .claude) == nil)
    }

    /// By default a sub-chat works in its parent's own folder (#130): the same worktree, or the main folder.
    @Test func defaultPlacementIsTheParentsFolder() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let wt = TaskMode.worktree(path: "/tmp/app.worktrees/feat", branch: "feat", base: "main")
        let parent = s.addTask(projectId: p, name: "Feat", mode: wt)
        let child = try sub(&s, parent: parent, name: "Check", kind: .claude)
        let task = try #require(s.tasks.first { $0.id == child.task })
        #expect(task.mode == wt && task.branch == "feat")
        #expect(task.tabs.first?.root.leaves.first?.cwd == "/tmp/app.worktrees/feat")
        let main = s.addTask(projectId: p, name: "Main")
        let mainChild = try sub(&s, parent: main, name: "Look", kind: .claude)
        let mainTask = try #require(s.tasks.first { $0.id == mainChild.task })
        #expect(mainTask.mode == .mainFolder && mainTask.tabs.first?.root.leaves.first?.cwd == "/tmp/app")
        // Sharing: the parent and its sub-chat, not the main-folder chats; archived ones only when asked.
        let parentTask = try #require(s.tasks.first { $0.id == parent })
        #expect(s.worktreeSharers(of: parentTask, openOnly: true).map(\.id) == [child.task])
        #expect(s.worktreeSharers(of: task, openOnly: true).map(\.id) == [parent])
        #expect(s.worktreeSharers(of: mainTask, openOnly: false).isEmpty)
        s.archiveTask(id: child.task)
        #expect(s.worktreeSharers(of: parentTask, openOnly: true).isEmpty)
        #expect(s.worktreeSharers(of: parentTask, openOnly: false).map(\.id) == [child.task])
    }

    @Test func freeChatSubSessionIsAFreeChat() throws {
        var s = WorkspaceState()
        s.chatsFolder = "/state/Chats"
        let parent = s.addFreeChat(name: "Чат 1", kind: .claude, autoNamed: true).task
        let child = try sub(&s, parent: parent, name: "Sub", kind: .claude)
        let task = try #require(s.tasks.first { $0.id == child.task })
        #expect(s.isFreeChatTask(task) && task.parentTaskId == parent && !task.autoNamed)
        #expect(task.tabs.first?.root.leaves.first?.cwd == "/state/Chats")
        #expect(s.selectedTaskId == parent)
    }

    @Test func sidebarRowsNestChildren() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let a = s.addTask(projectId: p, name: "A")
        let b = s.addTask(projectId: p, name: "B")
        let a1 = try sub(&s, parent: a, name: "A1", kind: .claude).task
        let a1x = try sub(&s, parent: a1, name: "A1x", kind: .claude).task
        let a2 = try sub(&s, parent: a, name: "A2", kind: .claude).task
        let rows = s.withSubSessions(s.tasks(in: p))
        #expect(rows.map(\.task.id) == [a, a1, a1x, a2, b])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0])
        s.setSubsCollapsed(taskId: a, true)
        #expect(s.withSubSessions(s.tasks(in: p)).map(\.task.id) == [a, b])
        #expect(s.withSubSessions(s.tasks(in: p), expandedOnly: false).count == 5)
        // A pinned child is shown in Pinned only; an archived parent's children stand at the top level.
        s.setSubsCollapsed(taskId: a, false)
        s.setPinned(taskId: a2, true)
        #expect(s.withSubSessions(s.tasks(in: p).filter { !$0.pinned }).map(\.task.id) == [a, a1, a1x, b])
        s.archiveTask(id: a)
        let orphans = s.withSubSessions(s.tasks(in: p).filter { !$0.pinned })
        #expect(orphans.map(\.task.id) == [b, a1, a1x])
        #expect(orphans.map(\.depth) == [0, 0, 1])
    }

    @Test func persists() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let parent = s.addTask(projectId: p, name: "A")
        let child = try sub(&s, parent: parent, name: "S", kind: .claude).task
        s.setSubsCollapsed(taskId: parent, true)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back.tasks.first { $0.id == child }?.parentTaskId == parent)
        #expect(back.tasks.first { $0.id == parent }?.subsCollapsed == true)
        // A file from before sub-sessions reads as top-level, unfolded chats.
        let encoded = try JSONEncoder().encode(HangarTask(projectId: p, name: "x", order: 0))
        var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(dict["parentTaskId"] == nil)
        dict["subsCollapsed"] = nil
        let task = try JSONDecoder().decode(HangarTask.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(task.parentTaskId == nil && !task.subsCollapsed)
    }

    /// Sharing is by place, not by spelling (#131): trailing slashes, `.`/`..` and case don't hide a sharer; another
    /// project on the same machine counts (also one whose main folder is this worktree); another machine doesn't.
    @Test func sharersAreFoundByPlace() {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let again = s.addProject(name: "app2", path: "/tmp/App/")
        let asProject = s.addProject(name: "wt", path: "/tmp/app.worktrees/feat/")
        let remote = s.addRemoteProject(name: "srv", host: "dev", path: "/tmp/app")
        let a = s.addTask(projectId: p, name: "A", mode: .worktree(path: "/tmp/app.worktrees/feat", branch: "feat", base: "main"))
        let slash = s.addTask(projectId: p, name: "B", mode: .worktree(path: "/tmp/app.worktrees/feat/", branch: "feat", base: "main"))
        let dots = s.addTask(projectId: again, name: "C", mode: .worktree(path: "/tmp/App.worktrees/x/../FEAT/.", branch: "feat", base: "main"))
        let main = s.addTask(projectId: asProject, name: "D")
        _ = s.addTask(projectId: remote, name: "E", mode: .worktree(path: "/tmp/app.worktrees/feat", branch: "feat", base: "main"))
        _ = s.addTask(projectId: p, name: "F", mode: .worktree(path: "/tmp/app.worktrees/feature", branch: "feature", base: "main"))
        _ = s.addTask(projectId: p, name: "G")
        let task = s.tasks.first { $0.id == a }!
        #expect(Set(s.worktreeSharers(of: task, openOnly: true).map(\.id)) == [slash, dots, main])
        #expect(worktreeKey("//tmp/./a//b/") == "/tmp/a/b")
    }

    /// The branch is kept while another session of the project has a worktree on it (an archived one restores onto it).
    @Test func branchKeepers() {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let a = s.addTask(projectId: p, name: "A", mode: .worktree(path: "/tmp/w/a", branch: "feat", base: "main"))
        let b = s.addTask(projectId: p, name: "B", mode: .worktree(path: "/tmp/w/b", branch: "feat", base: "main"))
        _ = s.addTask(projectId: p, name: "C", mode: .worktree(path: "/tmp/w/c", branch: "other", base: "main"))
        s.archiveTask(id: b)
        #expect(s.branchKeepers(of: s.tasks.first { $0.id == a }!).map(\.id) == [b])
    }
}
