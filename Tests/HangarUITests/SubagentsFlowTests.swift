import AgentStatus
import ControlServer
import Foundation
import History
import Testing
import TestSupport
@testable import HangarUI
import Workspace

/// Subagents in the app (spec agent-subagents): hooks build a chat's rows; the viewer watches the transcript only while open.
@MainActor @Suite struct SubagentsFlowTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar subagents \(UUID()) ж")

    private func makeApp() throws -> (AppState, task: HangarTask, tab: UUID, leaf: UUID) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.appendingPathComponent("repo").path)
        let t = s.addTask(projectId: p, name: "Main")
        let tab = s.addTab(taskId: t, kind: .claude)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        app.codexRead = nil
        app.claudeSettingsURL = dir.appendingPathComponent("claude/settings.json")
        app.integrationPathsCache = (app.claudeSettingsURL, dir.appendingPathComponent("codex/config.toml"), dir.appendingPathComponent("claude.json"))
        let task = app.state.tasks.first { $0.id == t }!
        return (app, task, tab, task.tabs[0].root.leaves[0].id)
    }

    private func hook(_ app: AppState, _ tab: UUID, _ leaf: UUID, _ kind: HookKind, _ fill: (inout EventMessage) -> Void = { _ in }) {
        var m = EventMessage(tab: tab, leaf: leaf, kind: kind, session: "sess-1")
        fill(&m)
        app.handle(.event(m))
    }

    @Test func hooksBuildTheChatsRows() throws {
        let (app, task, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .prompt)
        hook(app, tab, leaf, .tool)  // any other tool: no list at all
        #expect(app.subagents.isEmpty)
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.agentType = "Explore"; $0.title = "Implement Task 2.2"; $0.message = "Do it" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1"; $0.agentType = "Explore" }
        let rows = app.subagentRows(of: task)
        #expect(rows.map(\.item.title) == ["Implement Task 2.2"] && rows.first?.item.agentId == "a1" && rows.first?.leaf == leaf)
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a1"; $0.message = "Done: 3 files" }
        hook(app, tab, leaf, .tool) { $0.tool = "Agent"; $0.toolUseId = "t1"; $0.agentId = "a1" }
        // Finished: gone from the sidebar at once (HD-145); the list keeps it for its view until the next turn.
        #expect(app.subagentRows(of: task).isEmpty && app.subagent(leaf: leaf, id: "t1")?.result == "Done: 3 files")
        hook(app, tab, leaf, .stop)
        hook(app, tab, leaf, .prompt)
        #expect(app.subagentRows(of: task).isEmpty && app.subagents.isEmpty)
    }

    /// HD-145: the owner's case — the agent's turn ended while a background subagent runs on.
    @Test func backgroundSubagentAfterTheTurn() throws {
        let (app, task, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .prompt)
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "Write PLAN.md" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a1" }
        hook(app, tab, leaf, .tool) { $0.tool = "Agent"; $0.toolUseId = "t1"; $0.agentId = "a1" }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t2"; $0.agentType = "decision-reviewer"; $0.title = "Decision review" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a2"; $0.agentType = "decision-reviewer" }
        hook(app, tab, leaf, .tool) { $0.tool = "Agent"; $0.toolUseId = "t2"; $0.agentId = "a2"; $0.backgrounded = true }
        hook(app, tab, leaf, .stop)
        hook(app, tab, leaf, .tool) { $0.tool = "Read"; $0.inSubagent = true }
        #expect(app.state(of: task) == .done && app.statuses.status(leaf).unseen)
        #expect(app.subagentRows(of: task).map(\.item.title) == ["Decision review"])
        #expect(L10n.subagentsCounter(app.subagentRows(of: task).count).hasPrefix("1 "))
        // Its view stays open after it finished and even after its row left the list.
        app.openSubagentPanel(leaf: leaf, id: "t2")
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a2"; $0.message = "Approved" }
        #expect(app.subagentRows(of: task).isEmpty)
        hook(app, tab, leaf, .prompt)
        hook(app, tab, leaf, .stop)
        hook(app, tab, leaf, .prompt)
        app.syncSubagentPanel(windowVisible: true)
        let model = try #require(app.subagentPanel)
        #expect(app.subagents.isEmpty && model.item?.state == .done && model.report == "Approved")
        app.closeSubagentPanel()
        #expect(app.subagentPanel == nil)
    }

    /// claude's folder for the repo: every UTF-16 unit that isn't an ASCII letter or digit becomes `-`.
    private func transcript(_ app: AppState, agent: String, _ text: String) throws -> URL {
        let folder = String(dir.appendingPathComponent("repo").path.utf16.map { u in
            (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) ? Character(Unicode.Scalar(UInt8(u))) : "-"
        })
        let subs = app.claudeConfigDir.appendingPathComponent("projects/\(folder)/sess-1/subagents")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        let file = subs.appendingPathComponent("agent-\(agent).jsonl")
        try (#"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func append(_ file: URL, _ text: String) throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line.utf8))
        try h.close()
    }

    @Test func panelWatchesOnlyWhileOnScreen() async throws {
        let (app, _, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "Scan"; $0.message = "Hook prompt" }
        app.openSubagentPanel(leaf: leaf, id: "t1")
        let model = try #require(app.subagentPanel)
        #expect(app.state.inspectorVisible && app.subagentPanelJustOpened)
        // Not linked yet: the hook's prompt, no file, no watch.
        app.syncSubagentPanel(windowVisible: true)
        #expect(model.visible && model.watcher == nil && model.url == nil && model.prompt == "Hook prompt")

        let file = try transcript(app, agent: "a1", "Transcript prompt")
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }  // the row got its id while on screen: the file is found
        #expect(model.watcher != nil && model.prompt == "Transcript prompt")

        // An appended step arrives by FSEvents, no polling of ours.
        try append(file, "Working")
        #expect(await waitUntil { model.steps.map(\.text) == ["Working"] })

        // The inspector hidden: no watch, nothing read; shown again — the rest is read once and the watch resumes.
        app.perform { $0.inspectorVisible = false }
        app.syncSubagentPanel(windowVisible: true)
        #expect(app.subagentPanel === model && model.watcher == nil)
        try append(file, "Unseen")
        try await Task.sleep(for: .seconds(1))
        #expect(model.steps.map(\.text) == ["Working"])
        app.perform { $0.inspectorVisible = true }
        app.syncSubagentPanel(windowVisible: true)
        #expect(model.watcher != nil && model.steps.map(\.text) == ["Working", "Unseen"])

        // The window covered or minimised: the same.
        app.syncSubagentPanel(windowVisible: false)
        #expect(model.watcher == nil)
        app.syncSubagentPanel(windowVisible: true)
        #expect(model.watcher != nil)

        // «×» / Esc.
        app.closeSubagentPanel()
        #expect(app.subagentPanel == nil && model.watcher == nil)
    }

    @Test func panelSwitchesAndCloses() throws {
        let (app, task, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "One" }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t2"; $0.title = "Two" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a2" }
        _ = try transcript(app, agent: "a1", "P1")
        _ = try transcript(app, agent: "a2", "P2")

        app.openSubagentPanel(leaf: leaf, id: "t1")
        app.syncSubagentPanel(windowVisible: true)
        let first = try #require(app.subagentPanel)
        #expect(first.watcher != nil && first.prompt == "P1")
        // Another row switches the panel: the first one's watch ends.
        app.openSubagentPanel(leaf: leaf, id: "t2")
        app.syncSubagentPanel(windowVisible: true)
        let second = try #require(app.subagentPanel)
        #expect(second !== first && first.watcher == nil && second.watcher != nil && second.prompt == "P2")
        // The same row again keeps it.
        app.openSubagentPanel(leaf: leaf, id: "t2")
        #expect(app.subagentPanel === second)

        // A segment shortcut: back to the inspector's own view.
        app.showInspector(.files)
        #expect(app.subagentPanel == nil && second.watcher == nil)

        // Another chat selected: closed.
        app.openSubagentPanel(leaf: leaf, id: "t1")
        app.syncSubagentPanel(windowVisible: true)
        let third = try #require(app.subagentPanel)
        var other: UUID?
        app.perform { other = $0.addTask(projectId: task.projectId, name: "Other") }
        app.select(taskId: try #require(other))
        app.syncSubagentPanel(windowVisible: true)
        #expect(app.subagentPanel == nil && third.watcher == nil)

        // A row of a chat that isn't selected selects it.
        app.openSubagentPanel(leaf: leaf, id: "t1")
        #expect(app.selectedTask?.id == task.id && app.subagentPanel?.id == "t1")
        // The row gone (the next turn after they finished): the view stays until closed (HD-145).
        app.syncSubagentPanel(windowVisible: true)
        let fourth = try #require(app.subagentPanel)
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a1" }
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a2" }
        hook(app, tab, leaf, .stop)
        hook(app, tab, leaf, .prompt)
        app.syncSubagentPanel(windowVisible: true)
        #expect(app.subagentPanel === fourth && fourth.item?.state == .done)
    }

    @Test func remoteChatsShowTheHookOnlyPanel() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = WorkspaceState()
        let p = s.addRemoteProject(name: "api", host: "devbox", path: "/srv/api")
        let t = s.addTask(projectId: p, name: "Main")
        let tab = s.addTab(taskId: t, kind: .claude)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        app.codexRead = nil
        let leaf = app.state.tasks[0].tabs[0].root.leaves[0].id
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "Scan"; $0.message = "Hook prompt" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }
        app.openSubagentPanel(leaf: leaf, id: "t1")
        app.syncSubagentPanel(windowVisible: true)
        let model = try #require(app.subagentPanel)
        #expect(model.remote && model.url == nil && model.watcher == nil && model.prompt == "Hook prompt")
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a1"; $0.message = "All clear" }
        #expect(model.report == "All clear" && model.watcher == nil)
    }

    @Test func escClosesThePanelUnlessATerminalHasTheKeyboard() {
        #expect(subagentEscCloses(.other, inInspector: false, justOpened: false))
        #expect(subagentEscCloses(.text, inInspector: true, justOpened: false))
        #expect(subagentEscCloses(.terminal, inInspector: false, justOpened: true))
        #expect(!subagentEscCloses(.terminal, inInspector: false, justOpened: false))
        #expect(!subagentEscCloses(.text, inInspector: false, justOpened: false))
    }

    @Test func finishedRowsAreQuiet() {
        var s = Subagent(id: "t1", type: "Explore", title: "Scan", started: Date())
        #expect(StatusMark.icon(s.dotState) == .spinner)
        s.state = .done
        #expect(StatusMark.icon(s.dotState) == .check && StatusMark.dimmed(s.dotState, seen: s.dotSeen))
        s.state = .failed
        #expect(StatusMark.icon(s.dotState) == .exclamation && !s.dotSeen)
    }

    @Test func noFileNoTranscript() throws {
        let (app, _, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "Scan" }
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }
        #expect(app.subagentTranscriptURL(leaf: leaf, agentId: "a1") == nil)  // no file
    }

    @Test func elapsedIsInMinutes() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.subagentElapsed(30) == "<1 мин")
        #expect(L10n.subagentElapsed(185) == "3 мин")
        #expect(L10n.subagentElapsed(3900) == "1 ч 5 мин")
        #expect(L10n.subagentsCounter(1) == "1 субагент работает")
        #expect(L10n.subagentsCounter(3) == "3 субагента работают")
        #expect(L10n.subagentsCounter(5) == "5 субагентов работают")
    }
}
