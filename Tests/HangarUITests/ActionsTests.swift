import AppKit
import ControlServer
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

    /// «Port: 41234 (copy)» copies the task's `HANGAR_PORT` (#60); the leaf's launch env carries it.
    @Test func copyPortAndLaunchEnv() throws {
        let (app, _, a, _) = try makeApp()
        defer { cleanup() }
        let port = try #require(app.state.tasks.first { $0.id == a }?.port)
        #expect(Action.copyPort.title(for: .task(a), app: app) == L10n.portCopy(port))
        let pb = NSPasteboard(name: .init("hangar-test-\(UUID())"))
        var ctx = ActionContext(app: app)
        ctx.pasteboard = pb
        Action.copyPort.perform(.task(a), ctx)
        #expect(pb.string(forType: .string) == String(port))
        app.perform { _ = $0.addTab(taskId: a, kind: .shell) }
        let task = try #require(app.state.tasks.first { $0.id == a })
        let leaf = try #require(task.tabs.first?.root.leaves.first)
        let (spec, _) = try app.spec(for: leaf, tabId: task.tabs[0].id, context: .created(prompt: nil))
        #expect(spec.env["HANGAR_PORT"] == String(port))
    }

    @Test func taskProjectAndTabActions() throws {
        let (app, p, a, _) = try makeApp(externalEditor: "zed")
        defer { cleanup() }
        #expect(Action.list(for: .task(a), app: app)
            == [.rename, .togglePin, .toggleMute, .revealInFinder, .copyPath, .copyPort, .copyLink, .openInEditor, .archive])
        #expect(Action.list(for: .project(p), app: app)
            == [.newTask, .rename, .projectSettings, .projectNotifications, .revealInFinder, .copyPath, .copyLink, .openInEditor, .removeProject])
        let tab = UUID()
        #expect(Action.list(for: .tab(task: a, tab: tab), app: app) == [.rename, .copyLink, .splitRight, .splitDown, .closeTab])
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

    @Test func copyLinkPutsHangarLinkOnPasteboard() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        let tab = UUID()
        let board = NSPasteboard(name: .init("hangar-test-\(UUID())"))
        defer { board.releaseGlobally() }
        var ctx = ActionContext(app: app)
        ctx.pasteboard = board
        Action.copyLink.perform(.task(a), ctx)
        #expect(board.string(forType: .string) == "hangar://task/\(a.uuidString.lowercased())")
        Action.copyLink.perform(.tab(task: a, tab: tab), ctx)
        #expect(board.string(forType: .string) == "hangar://tab/\(tab.uuidString.lowercased())")
        Action.copyLink.perform(.project(p), ctx)
        #expect(board.string(forType: .string) == "hangar://project/\(p.uuidString.lowercased())")
    }

    @Test func shortcutsForActions() {
        #expect(shortcut(keyCode: 120, modifiers: []) == .rename)  // F2
        #expect(shortcut(keyCode: 120, modifiers: .function) == .rename)
        #expect(shortcut(keyCode: 13, modifiers: [.command, .shift]) == .archiveTask)
        #expect(shortcut(keyCode: 11, modifiers: .command) == .toggleSidebar)  // B
        #expect(shortcut(keyCode: 45, modifiers: [.command, .shift]) == .addProject)
        #expect(shortcut(keyCode: 126, modifiers: [.command, .option, .numericPad, .function]) == .focusSplit(.up))  // ↑: split, else task
        #expect(shortcut(keyCode: 125, modifiers: [.command, .option]) == .focusSplit(.down))  // ↓
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

    @Test func actionUsesCheckboxForWorktreeTask() throws {
        let (app, _, _, archived) = try makeApp()
        defer { cleanup() }
        var plain = 0, boxed = 0
        var ctx = ActionContext(app: app)
        ctx.confirm = { _, _, _, _ in plain += 1 }
        ctx.confirmWithCheckbox = { _, _, _, checkbox, _ in
            #expect(checkbox == L10n.alsoDeleteWorktree)
            boxed += 1
        }
        Action.deletePermanently.perform(.task(archived), ctx)
        #expect(plain == 1 && boxed == 0)
        app.perform { $0.tasks[1].mode = .worktree(path: "/wt/b", branch: "b", base: "main") }
        Action.deletePermanently.perform(.task(archived), ctx)
        #expect(plain == 1 && boxed == 1)
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

    @Test func taskSwitchingSkipsCollapsedProjects() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        let q = app.addProject(path: dir.path)
        app.createTask(projectId: q, name: "q", firstMessage: "", mode: .mainFolder)
        let qTask = app.state.tasks.last!.id
        app.select(taskId: a)
        app.setCollapsed(projectId: p, true)
        #expect(app.orderedTasks.map(\.id) == [qTask])
        app.setPinned(a, true)
        #expect(app.orderedTasks.map(\.id) == [a, qTask])  // pinned stays reachable
        app.setPinned(a, false)
        app.select(taskId: qTask)
        app.selectTask(offset: 1)
        #expect(app.state.selectedTaskId == qTask)
    }

    @Test func dropIndexByCenters() {
        #expect(dropIndex(heights: [32, 32, 32], from: 0, dy: 40) == 1)
        #expect(dropIndex(heights: [32, 32, 32], from: 0, dy: 0) == 0)
        #expect(dropIndex(heights: [32, 32, 32], from: 2, dy: -70) == 0)
        #expect(dropIndex(heights: [32, 32, 32], from: 1, dy: 500) == 2)
        #expect(dropIndex(heights: [96, 32, 64], from: 2, dy: -100) == 1)
    }

    @Test func clickThenF2Renames() {
        let task = UUID(), project = UUID(), tab = UUID()
        // The click leaves the terminal focused; F2 still renames what was clicked.
        #expect(f2Route(.terminal, lastInteraction: .chromeClick(.project(project)), selectedTask: task) == .rename(.project(project)))
        #expect(f2Route(.terminal, lastInteraction: .chromeClick(.tab(task: task, tab: tab)), selectedTask: task)
            == .rename(.tab(task: task, tab: tab)))
        #expect(f2Route(.other, lastInteraction: .chromeClick(.task(task)), selectedTask: nil) == .rename(.task(task)))
    }

    /// Monaco (editor or the diff's editable side) types like a text field: F2 is its rename, not the session's.
    @Test func monacoFocusIsTyping() {
        #expect(responderKind(isText: false, isWeb: true, inTerminalArea: true, isDiff: true) == .text)
        #expect(responderKind(isText: false, isWeb: true, inTerminalArea: true, isDiff: false) == .text)
        #expect(responderKind(isText: false, isWeb: false, inTerminalArea: true, isDiff: true) == .other)
        #expect(f2Route(responderKind(isText: false, isWeb: true, inTerminalArea: true, isDiff: true), lastInteraction: .typing,
                        selectedTask: UUID()) == .passthrough)
    }

    @Test func clickTypeThenF2PassesThrough() throws {
        let (app, p, _, _) = try makeApp()
        defer { cleanup() }
        app.chromeClicked(.project(p))
        #expect(f2Route(.terminal, lastInteraction: app.lastInteraction, selectedTask: nil) == .rename(.project(p)))
        app.keyReachedTerminal()
        #expect(app.lastInteraction == .typing)
        #expect(f2Route(.terminal, lastInteraction: app.lastInteraction, selectedTask: nil) == .passthrough)
        #expect(f2Route(.text, lastInteraction: app.lastInteraction, selectedTask: nil) == .passthrough)
    }

    @Test func noClickF2PassesThroughWhenTerminalFocused() {
        let task = UUID()
        #expect(f2Route(.terminal, lastInteraction: .typing, selectedTask: task) == .passthrough)
        // Nothing focused that could take F2: the selected task, else nothing.
        #expect(f2Route(.other, lastInteraction: .typing, selectedTask: task) == .rename(.task(task)))
        #expect(f2Route(.other, lastInteraction: .typing, selectedTask: nil) == .ignore)
    }

    @Test func clickedTargetIsForgottenWhenGone() throws {
        let (app, p, a, _) = try makeApp()
        defer { cleanup() }
        app.chromeClicked(.project(p))
        #expect(app.lastInteraction == .chromeClick(.project(p)))
        app.perform { $0.removeProject(id: p) }
        #expect(app.lastInteraction == .typing)
        _ = a
    }

    @Test func consumedShortcutEndsClickState() throws {
        let (app, p, _, _) = try makeApp()
        defer { cleanup() }
        app.chromeClicked(.project(p))
        app.hangarShortcutConsumed()  // click row -> ⌘T -> F2 must not rename the stale target
        #expect(app.lastInteraction == .typing)
        #expect(f2Route(.terminal, lastInteraction: app.lastInteraction, selectedTask: nil) == .passthrough)
    }

    @Test func sessionsViewKeepsKeysOffTheHiddenTerminals() {
        // «Сессии» covers the tabs: ⌘W closes the view (not the hidden tab, which would kill its agent unseen),
        // splits and ⌘J would change terminals nobody sees.
        #expect(drawerRoute(.closeTab, drawerFocused: false, diffActive: false, sessionsShown: true) == .closeSessions)
        #expect(drawerRoute(.closeTab, drawerFocused: true, diffActive: true, sessionsShown: true) == .closeSessions)
        for sc in [Shortcut.splitRight, .splitDown, .toggleDrawer] {
            #expect(drawerRoute(sc, drawerFocused: false, diffActive: false, sessionsShown: true) == .ignore)
        }
        #expect(drawerRoute(.sessions, drawerFocused: false, diffActive: false, sessionsShown: true) == .perform)
        #expect(drawerRoute(.newTask, drawerFocused: false, diffActive: false, sessionsShown: true) == .perform)
    }

    @Test func drawerFocusRoutesShortcuts() {
        // Terminal drawer focused: ⌘W collapses it, splits are ignored, ⌘T and the rest behave as usual.
        #expect(drawerRoute(.closeTab, drawerFocused: true, diffActive: false) == .collapseDrawer)
        #expect(drawerRoute(.splitRight, drawerFocused: true, diffActive: false) == .ignore)
        #expect(drawerRoute(.splitDown, drawerFocused: true, diffActive: false) == .ignore)
        #expect(drawerRoute(.newTab, drawerFocused: true, diffActive: false) == .perform)
        #expect(drawerRoute(.toggleDrawer, drawerFocused: true, diffActive: false) == .perform)
        #expect(drawerRoute(.tab(2), drawerFocused: true, diffActive: false) == .perform)
        for sc in [Shortcut.closeTab, .splitRight, .splitDown, .newTab] { #expect(drawerRoute(sc, drawerFocused: false, diffActive: false) == .perform) }
        // The shown diff tab is not a terminal: splits would split the hidden tab.
        #expect(drawerRoute(.splitRight, drawerFocused: false, diffActive: true) == .ignore)
        #expect(drawerRoute(.splitDown, drawerFocused: false, diffActive: true) == .ignore)
        #expect(drawerRoute(.newTab, drawerFocused: false, diffActive: true) == .perform)
        #expect(drawerRoute(.tab(1), drawerFocused: false, diffActive: true) == .perform)
        // The diff view holds the keyboard: not a terminal (F2 renames, keys don't count as typing).
        #expect(responderKind(isText: false, inTerminalArea: true, isDiff: true) == .other)
        #expect(responderKind(isText: false, inTerminalArea: true, isDiff: false) == .terminal)
        #expect(responderKind(isText: true, inTerminalArea: true, isDiff: false) == .text)
        #expect(responderKind(isText: false, inTerminalArea: false, isDiff: false) == .other)
    }

    @Test func drawerWithoutSurfaceHoldsFocus() throws {
        let (app, _, a, _) = try makeApp()
        app.select(taskId: a)
        cleanup()  // missing folder: the shell never starts, the leaf has no surface
        let drawer = TerminalDrawer(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(drawer)
        app.perform { $0.toggleDrawer(taskId: a) }
        drawer.sync()
        // ⌘W then sees `drawerFocused` (collapses the drawer), not the tab.
        #expect(window.makeFirstResponder(drawer.currentSurface))
        #expect(drawer.focusedLeaf != nil)
    }

    @Test func worktreeRootInputValidation() {
        L10n.language = .en
        #expect(worktreeRootInput("") == .success(nil))
        #expect(worktreeRootInput("  ") == .success(nil))
        #expect(worktreeRootInput("~/wt") == .success(NSHomeDirectory() + "/wt"))
        #expect(worktreeRootInput(" /tmp/wt ") == .success("/tmp/wt"))
        #expect(worktreeRootInput("wt") == .failure(PathInputError(message: L10n.pathMustBeAbsolute)))
        #expect(L10n.pathMustBeAbsolute == "Use an absolute path")
        #expect(L10n.branchAuto("origin/main") == "default (origin/main)")
        #expect(L10n.worktreeFolder == "Worktree folder")
        #expect(worktreeRootInsideProject("/p/app/wt", project: "/p/app"))
        #expect(worktreeRootInsideProject("/p/app", project: "/p/app/"))
        #expect(!worktreeRootInsideProject("/p/app.worktrees", project: "/p/app"))
        #expect(!worktreeRootInsideProject("/p", project: "/p/app"))
        #expect(worktreeRootInsideProject("~/app/wt", project: NSHomeDirectory() + "/app"))
        #expect(worktreeRootInsideProject(" /p/app/wt ", project: " /p/app "))
        #expect(L10n.creatingWorktreeWait == "Creating the worktree — wait a few seconds")
        L10n.language = .ru
        #expect(L10n.pathMustBeAbsolute == "Нужен абсолютный путь")
        #expect(L10n.branchAuto("origin/main") == "по умолчанию (origin/main)")
    }

    // MARK: Pane (leaf) actions

    /// Session "a" with a split tab: `kind` on the left (focused), a shell on the right.
    private func splitApp(_ kind: LeafKind = .shell) throws -> (AppState, task: UUID, tab: UUID, left: UUID, right: UUID) {
        let (app, _, a, _) = try makeApp()
        var tab = UUID(), left = UUID(), right = UUID()
        app.perform { s in
            tab = s.addTab(taskId: a, kind: kind)
            left = s.tasks.first { $0.id == a }!.tabs.first { $0.id == tab }!.root.leaves[0].id
            right = s.split(taskId: a, tabId: tab, leafId: left, axis: .horizontal, kind: .shell)
            s.setFocusedLeaf(taskId: a, tabId: tab, leafId: left)
        }
        return (app, a, tab, left, right)
    }

    private func tab(_ app: AppState, _ task: UUID, _ tab: UUID) -> Workspace.Tab? {
        app.state.tasks.first { $0.id == task }?.tabs.first { $0.id == tab }
    }

    @Test func leafActionsListAndEnablement() throws {
        let (app, a, t, left, right) = try splitApp()
        defer { cleanup() }
        let target = ActionTarget.leaf(task: a, tab: t, leaf: left)
        #expect(Action.list(for: target, app: app) == [.splitRight, .splitDown, .detachPane, .rename, .closePane])
        #expect(Action.detachPane.isEnabled(for: target, app: app))
        app.closeLeaf(right)
        #expect(!Action.detachPane.isEnabled(for: target, app: app))  // an unsplit tab is already its own tab
        // ⌘D from a pane's menu splits that pane.
        Action.splitDown.perform(target, ActionContext(app: app))
        #expect(tab(app, a, t)?.root.leaves.count == 2)
    }

    @Test func closePaneWithWorkingAgentAsks() throws {
        let (app, a, t, left, right) = try splitApp(.claude)
        defer { cleanup() }
        app.handle(.event(EventMessage(tab: t, leaf: left, kind: .prompt)))
        #expect(app.state(ofLeaf: left) == .working)
        var asked: [(String, String, String)] = []
        var pending: (() -> Void)?
        var ctx = ActionContext(app: app)
        ctx.confirm = { m, i, b, then in asked.append((m, i, b)); pending = then }
        Action.closePane.perform(.leaf(task: a, tab: t, leaf: left), ctx)
        #expect(asked.count == 1)
        #expect(asked.first?.0 == L10n.paneAgentWorking && asked.first?.1 == L10n.paneAgentWorkingInfo && asked.first?.2 == L10n.closePane)
        #expect(tab(app, a, t)?.root.leaf(id: left) != nil)  // nothing until confirmed
        let confirm = try #require(pending)
        confirm()
        #expect(tab(app, a, t)?.root.leaf(id: left) == nil)
        #expect(tab(app, a, t)?.root.leaves.map(\.id) == [right])
    }

    @Test func closePaneIdleClosesAtOnce() throws {
        let (app, a, t, left, right) = try splitApp()
        defer { cleanup() }
        var asked = 0
        var ctx = ActionContext(app: app)
        ctx.confirm = { _, _, _, _ in asked += 1 }
        Action.closePane.perform(.leaf(task: a, tab: t, leaf: right), ctx)
        #expect(asked == 0)
        #expect(tab(app, a, t)?.root.leaves.map(\.id) == [left])
    }

    /// Ruling R1: closing a whole tab with a working agent asks too.
    @Test func closeTabWithWorkingAgentAsks() throws {
        let (app, a, t, left, _) = try splitApp(.claude)
        defer { cleanup() }
        app.handle(.event(EventMessage(tab: t, leaf: left, kind: .prompt)))
        var pending: (() -> Void)?
        var title: String?
        var ctx = ActionContext(app: app)
        ctx.confirm = { m, _, _, then in title = m; pending = then }
        Action.closeTab.perform(.tab(task: a, tab: t), ctx)
        #expect(title == L10n.paneAgentWorking)
        #expect(tab(app, a, t) != nil)
        let confirm = try #require(pending)
        confirm()
        #expect(tab(app, a, t) == nil)
    }

    @Test func closeKeyRouteTable() throws {
        let (app, a, t, left, right) = try splitApp()
        defer { cleanup() }
        let split = try #require(tab(app, a, t))
        #expect(closeKeyRoute(split, focused: right) == .pane(right))
        #expect(closeKeyRoute(split, focused: nil) == .pane(left))
        app.closeLeaf(right)
        let single = try #require(tab(app, a, t))
        #expect(closeKeyRoute(single, focused: left) == .tab)
        #expect(closeKeyRoute(single, focused: nil) == .tab)
        // ⌘W with the TERMINAL drawer focused still collapses it (routed before `closeKeyRoute`).
        #expect(drawerRoute(.closeTab, drawerFocused: true, diffActive: false) == .collapseDrawer)
    }

    @Test func renameLeafViaCommit() throws {
        let (app, a, t, left, _) = try splitApp()
        defer { cleanup() }
        let target = ActionTarget.leaf(task: a, tab: t, leaf: left)
        Action.rename.perform(target, ActionContext(app: app))
        #expect(app.renaming == target)
        #expect(app.name(of: target) == app.paneTitle(try #require(app.leaf(id: left))))
        app.commitRename(target, "api")
        #expect(app.renaming == nil)
        #expect(app.leaf(id: left)?.customTitle == "api")
        #expect(app.name(of: target) == "api")
        app.commitRename(target, "")
        #expect(app.leaf(id: left)?.customTitle == nil)
    }

    @Test func f2RenamesClickedPane() throws {
        let (app, a, t, left, right) = try splitApp()
        defer { cleanup() }
        let target = ActionTarget.leaf(task: a, tab: t, leaf: left)
        app.chromeClicked(target)
        #expect(f2Route(.terminal, lastInteraction: app.lastInteraction, selectedTask: a) == .rename(target))
        app.closeLeaf(left)  // a clicked pane that is gone no longer takes F2
        #expect(app.lastInteraction == .typing)
        _ = right
    }

    /// Diff tab / «Сессии» cover the panes (ruling R3): no pane action applies to an unseen pane.
    @Test func leafActionsOffWhileSessionsShown() throws {
        let (app, a, t, left, _) = try splitApp()
        defer { cleanup() }
        let target = ActionTarget.leaf(task: a, tab: t, leaf: left)
        app.select(taskId: a)
        app.showSessionsView(projectId: try #require(app.state.projects.first?.id))
        for action in Action.list(for: target, app: app) { #expect(!action.isEnabled(for: target, app: app), "\(action)") }
    }
}
