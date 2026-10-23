import Foundation
import Testing
@testable import Workspace

@Suite struct TabOrderTests {
    private func makeTask() -> (WorkspaceState, task: UUID, tabs: [UUID]) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        let t = s.addTask(projectId: p, name: "t")
        let tabs = [LeafKind.claude, .shell, .codex].map { s.addTab(taskId: t, kind: $0) }
        return (s, t, tabs)
    }

    @Test func moveTabReorders() {
        var (s, t, ids) = makeTask()
        s.moveTab(taskId: t, tabId: ids[2], to: 0)
        #expect(s.tasks[0].tabs.map(\.id) == [ids[2], ids[0], ids[1]])
        s.moveTab(taskId: t, tabId: ids[2], to: 99)  // clamped to the end
        #expect(s.tasks[0].tabs.map(\.id) == [ids[0], ids[1], ids[2]])
        s.moveTab(taskId: t, tabId: ids[0], to: -3)  // clamped to the start: no change
        #expect(s.tasks[0].tabs.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test func moveTabKeepsActiveTab() {
        var (s, t, ids) = makeTask()
        let active = s.tasks[0].activeTabId
        s.moveTab(taskId: t, tabId: ids[0], to: 2)
        #expect(s.tasks[0].activeTabId == active)
    }

    @Test func moveUnknownTabIsNoOp() {
        var (s, t, ids) = makeTask()
        s.moveTab(taskId: t, tabId: UUID(), to: 0)
        s.moveTab(taskId: UUID(), tabId: ids[1], to: 0)
        #expect(s.tasks[0].tabs.map(\.id) == ids)
    }

    @Test func orderSurvivesRestore() throws {
        var (s, t, ids) = makeTask()
        s.moveTab(taskId: t, tabId: ids[1], to: 0)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back.tasks[0].tabs.map(\.id) == [ids[1], ids[0], ids[2]])
    }
}
