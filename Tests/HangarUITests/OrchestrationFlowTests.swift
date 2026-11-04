import AgentStatus
import ControlServer
import Foundation
import Integration
import Testing
@testable import HangarUI
import Workspace

/// `sessions_note`, `tabs_wait` and the «Скилл Hangar» switch inside the app.
@MainActor @Suite struct OrchestrationFlowTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-orch-\(UUID())")

    private func makeApp() throws -> (app: AppState, task: UUID, tab: UUID, leaf: UUID) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        let t = s.addTask(projectId: p, name: "Main")
        let tab = s.addTab(taskId: t, kind: .claude)
        let leaf = s.tasks.first { $0.id == t }!.tabs[0].root.leaves[0].id
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"),
                           socketPath: dir.appendingPathComponent("state/hangar.sock").path)
        app.keepAwake = .inert()
        app.codexRead = nil
        app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running }, send: { _, _, _ in }, read: { _ in nil })
        return (app, t, tab, leaf)
    }

    private func hook(_ app: AppState, _ kind: HookKind, tab: UUID, leaf: UUID, message: String? = nil) {
        app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: kind, session: "s-1", message: message)))
    }

    @Test func noteIsSetByTheCallerAndPersisted() async throws {
        let (app, task, _, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await app.respond(1, .tasksNote(task: leaf.uuidString, note: "Задача 3/7"))
        guard case .success(let data) = r.body else { Issue.record("\(r.body)"); return }
        #expect(try JSONDecoder().decode(NoteResult.self, from: data) == NoteResult(task: task, note: "Задача 3/7"))
        #expect(app.state.tasks.first { $0.id == task }?.note == "Задача 3/7")
        #expect(app.taskInfo(app.state.tasks.first { $0.id == task }!).note == "Задача 3/7")
        // Saved with the chat.
        let back = try JSONDecoder().decode(HangarTask.self, from: JSONEncoder().encode(app.state.tasks.first { $0.id == task }!))
        #expect(back.note == "Задача 3/7")
        _ = await app.respond(2, .tasksNote(task: "Main", note: nil))
        #expect(app.state.tasks.first { $0.id == task }?.note == nil)
        let none = await app.respond(3, .tasksNote(task: nil, note: "x"))
        if case .failure(let e) = none.body { #expect(e.code == .badParams) } else { Issue.record("noted nobody") }
    }

    @Test func noteFollowsTheProjectInTheToolbar() throws {
        let (app, task, _, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.select(taskId: task)
        #expect(windowTitle(app.state)?.subtitle == "app")
        app.perform { $0.setNote(taskId: task, "Раунд 2") }
        #expect(windowTitle(app.state)?.subtitle == "app · Раунд 2")
    }

    @Test func tabWaitEndsOnTheStatusItAsksFor() async throws {
        let (app, _, tab, leaf) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Already idle: answers at once.
        let now = await app.waitForTab((tab, leaf), for: .any, timeout: .seconds(5))
        #expect(now.status == "idle")
        hook(app, .prompt, tab: tab, leaf: leaf, message: "go")
        #expect(app.state(ofLeaf: leaf) == .working)
        // Working: still-running at the timeout.
        let timedOut = await app.waitForTab((tab, leaf), for: .any, timeout: .milliseconds(50))
        #expect(timedOut.status == "still-running" && timedOut.message == nil)
        // A question ends `any` but not `idle`; the Stop ends `idle` with its message.
        let idle = Task { await app.waitForTab((tab, leaf), for: .idle, timeout: .seconds(10)) }
        let any = Task { await app.waitForTab((tab, leaf), for: .any, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        hook(app, .notification, tab: tab, leaf: leaf, message: "Allow?")
        #expect(await any.value.status == "waiting")
        hook(app, .stop, tab: tab, leaf: leaf, message: "All green")
        let r = await idle.value
        #expect(["done", "idle"].contains(r.status) && r.message == "All green")
        #expect(app.tabWaiters.isEmpty)
        // A new prompt forgets the old message.
        hook(app, .prompt, tab: tab, leaf: leaf, message: "again")
        #expect(app.lastAgentMessage[leaf] == nil)
    }

    @Test func tabWaitStates() {
        #expect(tabWaitOver(.waiting, for: .any) && tabWaitOver(.waiting, for: .waiting) && !tabWaitOver(.waiting, for: .idle))
        #expect(tabWaitOver(.done, for: .idle) && tabWaitOver(.idle, for: .any) && !tabWaitOver(.idle, for: .waiting))
        #expect(!tabWaitOver(.working, for: .any))
        #expect(tabWaitOver(.failed, for: .waiting) && tabWaitOver(.limit, for: .idle))
    }

    /// Off by default: nothing written; on writes it, off removes only Hangar's file (backups kept); a foreign skill stays.
    @Test func skillSwitchInstallsAndRemoves() async throws {
        let (app, _, _, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")
        app.integrationCLI = "/Applications/Hangar.app/Contents/Helpers/hangar"
        app.claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
        app.codexConfigURL = home.appendingPathComponent(".codex/config.toml")
        app.findAgentDirs = nil
        let file = home.appendingPathComponent(".claude/skills/hangar/SKILL.md")
        let bundled = try #require(AppState.hangarSkillText)
        #expect(bundled.contains(hangarSkillMarker) && bundled.hasPrefix("---\nname: hangar\n"))
        await app.syncSkill()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await app.setSkill(.claude, on: true).value
        #expect(try String(contentsOf: file, encoding: .utf8) == bundled)
        #expect(app.config.claudeSkill && !app.config.codexSkill)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/skills").path))
        await app.setSkill(.claude, on: false).value
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        #expect(app.integrations.skill[.claude] == .synced(backup: tildePath(try #require(backupPath(app)))))
        // Someone else's skill under the same name.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: file, atomically: true, encoding: .utf8)
        await app.setSkill(.claude, on: true).value
        #expect(app.integrations.skill[.claude] == .foreign)
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
    }

    private func backupPath(_ app: AppState) -> String? {
        let root = dir.appendingPathComponent("state/backups")
        let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        return all.first { $0.contains("SKILL.md.hangar-backup-") }.map { root.appendingPathComponent($0).path }
    }
}
