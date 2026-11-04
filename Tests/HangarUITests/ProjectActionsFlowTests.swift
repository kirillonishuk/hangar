import ControlServer
import Exec
import Foundation
import Testing
import TestSupport
@testable import HangarUI
import Workspace

/// Project actions in the app (#133): runs, restarts, stops, repository approvals, CLI/MCP and the launch rules.
@MainActor @Suite struct ProjectActionsFlowTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-actions-\(UUID())")

    /// A fake terminal side: leaf states set by the test; started tabs and sent keys recorded.
    private final class Terminals {
        var states: [UUID: LeafState] = [:]
        var started: [UUID] = []
        var sent: [(UUID, [SendKey])] = []
    }

    private func makeApp(repoFile: String? = nil) throws -> (AppState, Terminals, task: UUID) {
        let folder = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".hangar"), withIntermediateDirectories: true)
        if let repoFile { try repoFile.write(to: folder.appendingPathComponent(repoActionsFile), atomically: true, encoding: .utf8) }
        var s = WorkspaceState()
        let p = s.addProject(name: "proj", path: folder.path)
        s.setActions(projectId: p, [ProjectAction(name: "Dev", command: "pnpm dev"), ProjectAction(name: "Test", command: "pnpm test", restart: false)])
        let t = s.addTask(projectId: p, name: "Main")
        s.addTab(taskId: t, kind: .claude)
        s.select(taskId: t)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        app.codexRead = nil
        let fake = Terminals()
        app.terminals = TerminalAccess(start: { fake.started.append($0) }, state: { fake.states[$0] ?? .notStarted },
                                       send: { leaf, _, keys in fake.sent.append((leaf, keys)) }, read: { _ in nil })
        return (app, fake, t)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    private func actionLeaves(_ app: AppState, _ task: UUID) -> [Leaf] {
        app.state.tasks.first { $0.id == task }!.tabs.flatMap(\.root.leaves).filter { $0.action != nil }
    }

    @Test func newTabThenRestartInPlace() async throws {
        let (app, fake, t) = try makeApp()
        defer { cleanup() }
        let dev = try #require(app.actions(of: app.selectedTask!).first)
        let first = try #require(app.startAction(dev, taskId: t, leaf: nil, activate: true))
        #expect(!first.restarted && fake.started == [first.tab])
        let leaf = try #require(actionLeaves(app, t).first)
        #expect(app.pendingPrompts[leaf.id] == "pnpm dev" && app.selectedTask?.activeTabId == first.tab)
        #expect(app.title(of: leaf) == "Dev" && app.project(app.selectedTask!.projectId)?.lastAction == "Dev")

        // Not running (exited): the same tab gets a fresh terminal at once.
        let again = try #require(app.startAction(dev, taskId: t, leaf: nil, activate: true))
        let renewed = try #require(actionLeaves(app, t).first)
        #expect(again.tab == first.tab && !again.restarted && renewed.id != leaf.id && actionLeaves(app, t).count == 1)
        #expect(app.pendingPrompts[renewed.id] == "pnpm dev")

        // Running: ⌃C first; the fresh terminal comes only once the old one ended (not a failure).
        fake.states[renewed.id] = .running
        let restart = try #require(app.startAction(dev, taskId: t, leaf: nil, activate: true))
        #expect(restart.restarted && fake.sent.last?.0 == renewed.id && fake.sent.last?.1 == [.ctrlC])
        #expect(actionLeaves(app, t).first?.id == renewed.id)
        app.exited(leafId: renewed.id, code: 130)
        #expect(app.state(ofLeaf: renewed.id) == .idle)
        try await waitFor { actionLeaves(app, t).first?.id != renewed.id }
        #expect(actionLeaves(app, t).count == 1)
    }

    @Test func noRestartOpensAnotherTabAndFailuresShow() throws {
        let (app, _, t) = try makeApp()
        defer { cleanup() }
        let test = try #require(app.actions(of: app.selectedTask!).first { $0.name == "Test" })
        app.startAction(test, taskId: t, leaf: nil, activate: false)
        app.startAction(test, taskId: t, leaf: nil, activate: false)
        let leaves = actionLeaves(app, t)
        #expect(leaves.count == 2 && leaves.allSatisfy { $0.action == "Test" })
        // Started from CLI/MCP the visible tab stays.
        #expect(app.selectedTask?.activeTabId == app.selectedTask?.tabs.first?.id)
        app.exited(leafId: leaves[0].id, code: 1)
        #expect(app.state(ofLeaf: leaves[0].id) == .failed)
        app.exited(leafId: leaves[1].id, code: 0)
        #expect(app.state(ofLeaf: leaves[1].id) == .idle && actionLeaves(app, t).count == 2)  // a clean exit keeps the tab
    }

    @Test func stopHangsUpWhatIgnoresCtrlC() async throws {
        let (app, fake, t) = try makeApp()
        defer { cleanup() }
        let dev = try #require(app.actions(of: app.selectedTask!).first)
        app.startAction(dev, taskId: t, leaf: nil, activate: true)
        let leaf = try #require(actionLeaves(app, t).first)
        fake.states[leaf.id] = .running
        #expect(app.runningActions(of: app.selectedTask!).map(\.name) == ["Dev"])
        app.stopAction(leaf.id)
        #expect(fake.sent.last?.1 == [.ctrlC] && app.runningActions(of: app.selectedTask!).isEmpty)
        // Still running after the grace: a fresh, not started terminal in the same tab.
        try await waitFor { actionLeaves(app, t).first?.id != leaf.id }
        let fresh = try #require(actionLeaves(app, t).first)
        #expect(app.pendingPrompts[fresh.id] == nil)
    }

    @Test func repoActionsNeedApprovalOnce() async throws {
        let (app, _, t) = try makeApp(repoFile: #"{"actions":[{"name":"Lint","command":"pnpm lint"},{"name":"Dev","command":"evil"}]}"#)
        defer { cleanup() }
        let list = try await ok(app, .actionsList(task: "Main"), ActionsResult.self)
        #expect(list.actions.map(\.name) == ["Dev", "Test", "Lint"])  // the project's «Dev» wins over the file's
        #expect(list.actions.map(\.approved) == [true, true, false] && list.error == nil)

        let refused = await app.respond(1, .actionsRun(task: "Main", name: "Lint"))
        guard case .failure(let e) = refused.body else { Issue.record("ran an unapproved command"); return }
        #expect(e.message.contains("not approved"))
        #expect(actionLeaves(app, t).isEmpty)

        // The app asks; «Запустить» approves this exact text.
        var asked: [String] = []
        app.confirmActionRun = { name, command, then in asked.append("\(name):\(command)"); then() }
        app.runAction("Lint", taskId: t)
        try await waitFor { !actionLeaves(app, t).isEmpty }
        #expect(asked == ["Lint:pnpm lint"])
        let run = try await ok(app, .actionsRun(task: "Main", name: "Lint"), ActionRunResult.self)
        #expect(run.tab.title == "Lint")
        #expect(await app.respond(1, .actionsRun(task: "Main", name: "Nope")).isFailure(code: .notFound))
    }

    @Test func badRepoFileIsReported() async throws {
        let (app, _, _) = try makeApp(repoFile: "{oops")
        defer { cleanup() }
        let list = try await ok(app, .actionsList(task: "Main"), ActionsResult.self)
        #expect(list.actions.map(\.name) == ["Dev", "Test"] && list.error?.contains("not valid JSON") == true)
    }

    @Test func actionLaunchRules() {
        #expect(actionLaunches(.created(prompt: "pnpm dev"), remote: false))
        #expect(!actionLaunches(.created(prompt: nil), remote: false))
        #expect(!actionLaunches(.restored, remote: false))
        #expect(actionLaunches(.restored, remote: true))  // a server's tmux may still run it: reattach
        let mode = LaunchMode(restoring: false, initialPrompt: "x")
        #expect(actionLaunches(.relaunch(previous: mode, exitCode: nil), remote: false))
        #expect(!actionLaunches(.relaunch(previous: mode, exitCode: 1), remote: false))
        #expect(actionWasStopped(130) && actionWasStopped(-1) && !actionWasStopped(1) && !actionWasStopped(0))
    }

    @Test func settingsInput() {
        #expect(projectActionsInput([ActionDraft(name: " Dev ", command: "pnpm dev", folder: "./apps/cms/"), ActionDraft()])
                == .success([ProjectAction(name: "Dev", command: "pnpm dev", folder: "apps/cms")]))
        #expect(projectActionsInput([ActionDraft(name: "Dev", command: "x", folder: "../up")]) == .failure(PathInputError(message: L10n.actionFolderInvalid)))
        #expect(projectActionsInput([ActionDraft(name: "Dev", command: "")]) == .failure(PathInputError(message: L10n.actionIncomplete)))
        #expect(projectActionsInput([ActionDraft(name: "A", command: "a"), ActionDraft(name: "A", command: "b")])
                == .failure(PathInputError(message: L10n.actionDuplicate("A"))))
    }

    @Test func folderRunsAndMissingFolderRefuses() async throws {
        let (app, _, t) = try makeApp()
        defer { cleanup() }
        let root = dir.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: root + "/apps/cms", withIntermediateDirectories: true)
        app.perform { s in
            s.setActions(projectId: s.projects[0].id, [ProjectAction(name: "cms", command: "pnpm run dev", folder: "apps/cms"),
                                                       ProjectAction(name: "web", command: "pnpm run dev", folder: "apps/web")])
        }
        let run = try await ok(app, .actionsRun(task: "Main", name: "cms"), ActionRunResult.self)
        #expect(run.tab.title == "cms" && actionLeaves(app, t).first?.cwd == root + "/apps/cms")
        let refused = await app.respond(1, .actionsRun(task: "Main", name: "web"))
        guard case .failure(let e) = refused.body else { Issue.record("ran in a missing folder"); return }
        #expect(e.code == .notFound && e.message.contains("apps/web"))
        var failed: [String] = []
        app.actionFailed = { title, details in failed.append(title + "|" + details) }
        app.runAction("web", taskId: t)
        try await waitFor { !failed.isEmpty }
        #expect(failed.first?.contains("apps/web") == true && actionLeaves(app, t).count == 1)
        let list = try await ok(app, .actionsList(task: "Main"), ActionsResult.self)
        #expect(list.actions.first?.folder == "apps/cms")
    }

    @Test func hiddenRepoActionsLeaveTheList() async throws {
        let (app, _, _) = try makeApp(repoFile: #"{"actions":[{"name":"Lint","command":"pnpm lint"}]}"#)
        defer { cleanup() }
        app.perform { s in s.setActions(projectId: s.projects[0].id, s.projects[0].actions ?? [], hidden: ["Lint"]) }
        let list = try await ok(app, .actionsList(task: "Main"), ActionsResult.self)
        #expect(list.actions.map(\.name) == ["Dev", "Test"])
    }

    /// The two discovery runs against a real pnpm monorepo layout in a temp folder (`Runner.local`, as on a server via ssh).
    @Test func discoversWorkspaceScripts() async throws {
        let (app, _, _) = try makeApp()
        defer { cleanup() }
        let root = dir.appendingPathComponent("proj")
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("package.json", #"{"packageManager":"pnpm@10.28.2","scripts":{"dev":"turbo dev","lint":"biome lint"}}"#)
        try write("pnpm-workspace.yaml", "packages:\n  - apps/*\n  - packages/*\n")
        try write("pnpm-lock.yaml", "")
        try write("apps/cms/package.json", #"{"scripts":{"dev":"vite","build":"vite build"}}"#)
        try write("apps/saas/package.json", #"{"scripts":{"dev":"next dev"}}"#)
        try write("packages/ui/package.json", #"{"name":"ui"}"#)
        try write("Makefile", "deploy:\n\t./deploy.sh\n")
        let project = try #require(app.state.projects.first)
        let groups = await app.discoverActions(folder: root.path, project: project)
        #expect(groups.map(\.folder) == ["", "apps/cms", "apps/saas"])
        #expect(groups[0].actions.map(\.name) == ["dev", "lint", "make deploy"])
        #expect(groups[1].actions == [ProjectAction(name: "cms: dev", command: "pnpm run dev", folder: "apps/cms"),
                                      ProjectAction(name: "cms: build", command: "pnpm run build", folder: "apps/cms")])
        // Already in the list (same command and folder) or not matching the search: not offered.
        let shown = actionSuggestionsShown(groups, rows: [ActionDraft(name: "x", command: "pnpm run dev", folder: "apps/cms")], query: "cms")
        #expect(shown.map(\.folder) == ["apps/cms"] && shown[0].actions.map(\.name) == ["cms: build"])
    }

    // MARK: helpers

    private func ok<T: Decodable>(_ app: AppState, _ call: ControlCall, _: T.Type) async throws -> T {
        switch await app.respond(7, call).body {
        case .success(let data): return try JSONDecoder().decode(T.self, from: data)
        case .failure(let e): throw e
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let met = await waitUntil { condition() }
        try #require(met)
    }
}

private extension ControlResponse {
    func isFailure(code: ControlErrorCode) -> Bool { if case .failure(let e) = body { e.code == code } else { false } }
}
