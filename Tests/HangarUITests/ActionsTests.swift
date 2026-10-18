import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct ActionsTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-actions-\(UUID())")

    /// Project "app" at a real temp folder with tasks "a" (active) and "b" (archived).
    private func makeApp(externalEditor: String? = nil) throws -> (AppState, project: UUID, active: UUID, archived: UUID) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        let a = s.addTask(projectId: p, name: "a")
        let b = s.addTask(projectId: p, name: "b")
        s.archiveTask(id: b)
        var config = HangarConfig()
        config.externalEditor = externalEditor
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: config, configURL: dir.appendingPathComponent("config.toml"))
        return (app, p, a, b)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    @Test func archivedTaskActions() throws {
        let (app, _, _, archived) = try makeApp(externalEditor: "code")
        defer { cleanup() }
        #expect(Action.list(for: .task(archived), app: app) == [.restore, .deletePermanently])
    }

    @Test func taskProjectAndTabActions() throws {
        let (app, p, a, _) = try makeApp(externalEditor: "zed")
        defer { cleanup() }
        #expect(Action.list(for: .task(a), app: app)
            == [.rename, .togglePin, .revealInFinder, .copyPath, .openInEditor, .archive])
        #expect(Action.list(for: .project(p), app: app)
            == [.newTask, .rename, .projectSettings, .revealInFinder, .copyPath, .openInEditor, .removeProject])
        let tab = UUID()
        #expect(Action.list(for: .tab(task: a, tab: tab), app: app) == [.rename, .splitRight, .splitDown, .closeTab])
        #expect(Action.openInEditor.title(for: .task(a), app: app) == L10n.openIn("Zed"))
    }

    @Test func externalEditorHiddenWhenUnset() throws {
        let (app, p, a, _) = try makeApp(externalEditor: nil)
        defer { cleanup() }
        #expect(!Action.list(for: .task(a), app: app).contains(.openInEditor))
        #expect(!Action.list(for: .project(p), app: app).contains(.openInEditor))
    }

    @Test func pinTitleFollowsState() throws {
        let (app, _, a, _) = try makeApp()
        defer { cleanup() }
        let ctx = ActionContext(app: app)
        #expect(Action.togglePin.title(for: .task(a), app: app) == L10n.pin)
        Action.togglePin.perform(.task(a), ctx)
        #expect(app.pinnedTasks.map(\.id) == [a])
        #expect(Action.togglePin.title(for: .task(a), app: app) == L10n.unpin)
    }

    @Test func copyPathPutsPathOnPasteboard() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        let board = NSPasteboard(name: .init("hangar-test-\(UUID())"))
        defer { board.releaseGlobally() }
        var ctx = ActionContext(app: app)
        ctx.pasteboard = board
        Action.copyPath.perform(.project(p), ctx)
        #expect(board.string(forType: .string) == dir.path)
        app.perform { $0.tasks[0].mode = .worktree(path: "/wt/a", branch: "a", base: "main") }
        Action.copyPath.perform(.task(a), ctx)
        #expect(board.string(forType: .string) == "/wt/a")
    }

    @Test func shortcutsForActions() {
        #expect(shortcut(keyCode: 120, modifiers: []) == .rename)  // F2
        #expect(shortcut(keyCode: 120, modifiers: .function) == .rename)
        #expect(shortcut(keyCode: 13, modifiers: [.command, .shift]) == .archiveTask)
        #expect(shortcut(keyCode: 11, modifiers: .command) == .toggleSidebar)  // B
        #expect(shortcut(keyCode: 45, modifiers: [.command, .shift]) == .addProject)
        #expect(shortcut(keyCode: 126, modifiers: [.command, .option, .numericPad, .function]) == .prevTask)  // ↑
        #expect(shortcut(keyCode: 125, modifiers: [.command, .option]) == .nextTask)  // ↓
        #expect(shortcut(keyCode: 126, modifiers: .command) == nil)  // ⌘↑ stays with the terminal
        #expect(Action.rename.shortcut == .rename)
        #expect(Action.archive.shortcut == .archiveTask)
        #expect(Action.splitRight.shortcut == .splitRight)
        #expect(Action.closeTab.shortcut == .closeTab)
    }

    @Test func deleteAndRemoveAskFirstAndKeepDisk() throws {
        let (app, p, _, archived) = try makeApp()
        defer { cleanup() }
        var pending: [() -> Void] = []
        var ctx = ActionContext(app: app)
        ctx.confirm = { _, _, _, then in pending.append(then) }
        Action.deletePermanently.perform(.task(archived), ctx)
        #expect(app.state.tasks.count == 2)  // nothing until confirmed
        pending.removeFirst()()
        #expect(!app.state.tasks.contains { $0.id == archived })
        Action.removeProject.perform(.project(p), ctx)
        #expect(app.state.projects.count == 1)
        pending.removeFirst()()
        #expect(app.state.projects.isEmpty && app.state.tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func renameStartsInlineEditing() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        let ctx = ActionContext(app: app)
        Action.rename.perform(.task(a), ctx)
        #expect(app.renaming == .task(a))
        app.commitRename(.task(a), "  fixed ")
        #expect(app.renaming == nil)
        #expect(app.state.tasks[0].name == "fixed")
        app.perform { $0.sidebarCollapsed = true }
        #expect(!Action.rename.isEnabled(for: .project(p), app: app))
    }

    @Test func tabLabelPrefersCustomTitle() throws {
        let (app, _, a, _) = try makeApp()
        defer { cleanup() }
        app.select(taskId: a)
        app.addTab(.shell)
        let tab = try #require(app.selectedTask?.tabs.first)
        app.setTitle("vim README", leafId: tab.root.leaves[0].id)
        #expect(app.tabLabel(tab) == "vim README")
        app.commitRename(.tab(task: a, tab: tab.id), "server")
        let renamed = try #require(app.selectedTask?.tabs.first)
        #expect(app.tabLabel(renamed) == "server")
    }

    @Test func groupMoveSkipsPinnedTasks() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        var ids = [a]
        app.perform { s in for n in ["c", "d", "e"] { ids.append(s.addTask(projectId: p, name: n)) } }
        app.setPinned(ids[1], true)  // c pinned: group shows a, d, e
        app.moveTask(ids[3], toGroupIndex: 0)  // e to the top of the group
        #expect(app.groupTasks(p).map(\.name) == ["e", "a", "d"])
        app.moveTask(ids[3], toGroupIndex: 2)
        #expect(app.groupTasks(p).map(\.name) == ["a", "d", "e"])
    }

    @Test func dropIndexByCenters() {
        #expect(dropIndex(heights: [32, 32, 32], from: 0, dy: 40) == 1)
        #expect(dropIndex(heights: [32, 32, 32], from: 0, dy: 0) == 0)
        #expect(dropIndex(heights: [32, 32, 32], from: 2, dy: -70) == 0)
        #expect(dropIndex(heights: [32, 32, 32], from: 1, dy: 500) == 2)
        #expect(dropIndex(heights: [96, 32, 64], from: 2, dy: -100) == 1)
    }

    @Test func f2Routing() {
        let task = UUID(), project = UUID(), tab = UUID()
        #expect(f2Route(.terminal, lastClicked: .project(project), selectedTask: task) == .passthrough)
        #expect(f2Route(.text, lastClicked: .project(project), selectedTask: task) == .passthrough)
        #expect(f2Route(.other, lastClicked: .project(project), selectedTask: task) == .rename(.project(project)))
        #expect(f2Route(.other, lastClicked: .tab(task: task, tab: tab), selectedTask: task) == .rename(.tab(task: task, tab: tab)))
        #expect(f2Route(.other, lastClicked: nil, selectedTask: task) == .rename(.task(task)))
        #expect(f2Route(.other, lastClicked: nil, selectedTask: nil) == .ignore)
    }

    @Test func clickedTargetIsForgottenWhenGone() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        app.lastClicked = .project(p)
        #expect(app.keyTarget == .project(p))
        app.perform { $0.removeProject(id: p) }
        #expect(app.keyTarget == nil)
        _ = a
    }
}
