import AgentStatus
import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Sidebar «Требуют внимания» (#NN-attention).
@MainActor @Suite struct AttentionFilterTests {
    @Test func keepsWaitingAndFailedGroupedByProjectAndDropsEmptyProjects() {
        var s = WorkspaceState()
        let app = s.addProject(name: "app", path: "/a")
        let quiet = s.addProject(name: "quiet", path: "/q")
        let web = s.addProject(name: "web", path: "/w")
        let waiting = s.addTask(projectId: app, name: "waiting")
        let working = s.addTask(projectId: app, name: "working")
        let failed = s.addTask(projectId: app, name: "failed")
        _ = s.addTask(projectId: quiet, name: "done")
        let pinned = s.addTask(projectId: web, name: "pinned")
        s.setPinned(taskId: pinned, true)
        let archived = s.addTask(projectId: web, name: "archived")
        s.archiveTask(id: archived)
        s.setProjectCollapsed(id: web, true)
        let states: [UUID: AgentState] = [waiting: .waiting, working: .working, failed: .failed, pinned: .waiting, archived: .waiting]

        let groups = attentionGroups(s) { states[$0.id] ?? .done }
        #expect(groups.map(\.project.id) == [app, web])
        #expect(groups.map { $0.tasks.map(\.id) } == [[waiting, failed], [pinned]])
    }

    @Test func nothingWaitingIsEmpty() {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/a")
        _ = s.addTask(projectId: p, name: "t")
        #expect(attentionGroups(s) { _ in .idle }.isEmpty)
        #expect(attentionGroups(WorkspaceState()) { _ in .waiting }.isEmpty)
    }

    @Test func optionCommandFTogglesByKeyCode() {
        // keyCode 3 is the F key in any layout (А in Russian).
        #expect(shortcut(keyCode: 3, modifiers: [.command, .option]) == .attentionFilter)
        #expect(Shortcut.attentionFilter.label == "⌥⌘F")
        #expect(L10n.help(L10n.attentionOnly, .attentionFilter).hasSuffix("— ⌥⌘F"))
    }
}
