import Foundation
import Testing
@testable import Workspace

/// «<host> · терминал» (#64): a per-host pseudo task of plain ssh shells, outside `projects`.
@Suite struct HostShellTests {
    @Test func openCreatesTaskOnceAndAddsShellTabs() throws {
        var s = WorkspaceState()
        let first = s.openHostShell(host: "box")
        #expect(s.projects.isEmpty)
        #expect(s.hostShells.map(\.host) == ["box"])
        #expect(s.selectedTaskId == first.task)
        let task = try #require(s.hostShellTask(host: "box"))
        #expect(task.id == first.task && task.activeTabId == first.tab)
        #expect(task.tabs.flatMap(\.root.leaves).map(\.kind) == [.shell])
        #expect(s.hostShell(ofTask: first.task)?.host == "box")

        let second = s.openHostShell(host: "box")
        #expect(second.task == first.task && second.tab != first.tab)
        #expect(s.hostShellTask(host: "box")?.tabs.count == 2)
        #expect(s.hostShells.count == 1)
    }

    @Test func onlyShellsInHostTask() throws {
        var s = WorkspaceState()
        let o = s.openHostShell(host: "box")
        let tab = s.addTab(taskId: o.task, kind: .claude)
        let t = try #require(s.tasks.first { $0.id == o.task })
        let leaf = try #require(t.tabs.first { $0.id == tab }?.root.leaves.first)
        #expect(leaf.kind == .shell)
        let split = s.split(taskId: o.task, tabId: tab, leafId: leaf.id, axis: .horizontal, kind: .codex)
        #expect(s.tasks.first { $0.id == o.task }?.tabs.flatMap(\.root.leaves).first { $0.id == split }?.kind == .shell)
    }

    @Test func closingLastTabRemovesHostTask() {
        var s = WorkspaceState()
        let a = s.openHostShell(host: "box")
        let b = s.openHostShell(host: "box")
        s.closeTab(taskId: a.task, tabId: a.tab)
        #expect(s.hostShellTask(host: "box") != nil)
        let leaf = s.tasks.first { $0.id == b.task }!.tabs[0].root.leaves[0].id
        s.closeLeaf(taskId: b.task, tabId: b.tab, leafId: leaf)
        #expect(s.hostShellTask(host: "box") == nil)
        #expect(s.hostShells.isEmpty && s.tasks.isEmpty)
        #expect(s.selectedTaskId == nil)
    }

    @Test func closeHostShellRemovesEverything() {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let keep = s.addTask(projectId: p, name: "t")
        let other = s.openHostShell(host: "other")
        _ = s.openHostShell(host: "box")
        s.closeHostShell(host: "box")
        #expect(s.hostShells.map(\.host) == ["other"])
        #expect(s.tasks.map(\.id).contains(keep))
        #expect(s.hostShellTask(host: "box") == nil)
        #expect(s.selectedTaskId == nil)
        s.select(taskId: other.task)
        s.closeHostShell(host: "box")  // repeating is harmless; another selection stays
        #expect(s.selectedTaskId == other.task)
    }

    @Test func roundTripsAndOldStateDecodes() throws {
        var s = WorkspaceState()
        _ = s.openHostShell(host: "box")
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = #"{"projects":[],"tasks":[],"inspectorVisible":false}"#
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: Data(old.utf8)).hostShells.isEmpty)
    }
}
