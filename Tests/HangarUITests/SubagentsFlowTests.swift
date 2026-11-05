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
        var rows = app.subagentRows(of: task)
        #expect(rows.map(\.item.title) == ["Implement Task 2.2"] && rows.first?.item.agentId == "a1" && rows.first?.leaf == leaf)
        hook(app, tab, leaf, .subagentStop) { $0.agentId = "a1"; $0.message = "Done: 3 files" }
        hook(app, tab, leaf, .tool) { $0.tool = "Agent"; $0.toolUseId = "t1"; $0.agentId = "a1" }
        rows = app.subagentRows(of: task)
        #expect(rows.first?.item.state == .done && rows.first?.item.result == "Done: 3 files")
        hook(app, tab, leaf, .stop)
        hook(app, tab, leaf, .prompt)
        #expect(app.subagentRows(of: task).isEmpty && app.subagents.isEmpty)
    }

    @Test func viewerWatchesOnlyWhileOpen() async throws {
        let (app, _, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        hook(app, tab, leaf, .subagentStart) { $0.toolUseId = "t1"; $0.title = "Scan"; $0.message = "Hook prompt" }
        let model = SubagentViewerModel(app: app, leaf: leaf, id: "t1")
        // Not linked yet: the hook's prompt, no file, no watch.
        model.start()
        #expect(model.watcher == nil && model.url == nil && model.prompt == "Hook prompt")

        // claude's folder name: every UTF-16 unit that isn't an ASCII letter or digit becomes `-`.
        let folder = String(dir.appendingPathComponent("repo").path.utf16.map { u in
            (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) ? Character(Unicode.Scalar(UInt8(u))) : "-"
        })
        let subs = app.claudeConfigDir.appendingPathComponent("projects/\(folder)/sess-1/subagents")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        let file = subs.appendingPathComponent("agent-a1.jsonl")
        let first = #"{"type":"user","message":{"role":"user","content":"Transcript prompt"}}"# + "\n"
        try first.write(to: file, atomically: true, encoding: .utf8)
        hook(app, tab, leaf, .subagentRun) { $0.agentId = "a1" }
        model.start()  // the sheet does this when the row gets its agent id
        #expect(model.watcher != nil && model.prompt == "Transcript prompt")

        // An appended step arrives by FSEvents, no polling of ours.
        let step = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working"}]}}"# + "\n"
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(step.utf8))
        try h.close()
        #expect(await waitUntil { model.steps.map(\.text) == ["Working"] })

        model.stop()
        #expect(model.watcher == nil)
        let more = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Unseen"}]}}"# + "\n"
        let h2 = try FileHandle(forWritingTo: file)
        try h2.seekToEnd()
        try h2.write(contentsOf: Data(more.utf8))
        try h2.close()
        try await Task.sleep(for: .seconds(1))
        #expect(model.steps.map(\.text) == ["Working"])
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
        #expect(L10n.subagentsCounter(3, running: 1) == "3 субагента · 1 работает")
        #expect(L10n.subagentsCounter(1, running: 0) == "1 субагент")
    }
}
