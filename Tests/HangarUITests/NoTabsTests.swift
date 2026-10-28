import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Closing a session's last tab leaves it empty (decision #99): nothing is launched, the area offers new tabs.
@MainActor @Suite struct NoTabsTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-notabs-\(UUID())")

    private func makeApp() throws -> (AppState, task: UUID, tab: UUID) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        let t = s.addTask(projectId: p, name: "a")
        let tab = s.addTab(taskId: t, kind: .claude)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.select(taskId: t)
        return (app, t, tab)
    }

    @Test func closingTheLastTabLeavesAnEmptySession() throws {
        let (app, task, tab) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        Action.closeTab.perform(.tab(task: task, tab: tab), ActionContext(app: app))
        let t = try #require(app.state.tasks.first { $0.id == task })
        #expect(t.tabs.isEmpty && t.activeTabId == nil && !t.archived)
        #expect(app.selectedTask?.id == task)
        #expect(app.showsNoTabs)
        // A relaunch restores it empty too.
        app.saveNow()
        guard case .loaded(let restored) = StateStore(directory: dir.appendingPathComponent("state")).load() else {
            Issue.record("state not saved"); return
        }
        #expect(restored.tasks.first { $0.id == task }?.tabs.isEmpty == true)
    }

    @Test func emptyStateOffersAgentsAndTerminal() throws {
        let (app, task, tab) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!app.showsNoTabs)
        #expect(noTabsChoices(hostShell: false) == [.claude, .codex, .shell])
        #expect(noTabsChoices(hostShell: true) == [.shell])  // a host's terminal holds only ssh shells
        app.perform { $0.closeTab(taskId: task, tabId: tab) }
        app.addTab(.codex)  // the «Codex» button
        let t = try #require(app.state.tasks.first { $0.id == task })
        #expect(t.tabs.map { $0.root.leaves.map(\.kind) } == [[.codex]])
        #expect(!app.showsNoTabs)
    }
}
