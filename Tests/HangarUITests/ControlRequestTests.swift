import AgentStatus
import ControlServer
import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// `AppState.respond`: projects and tasks commands against a real model (and real temp repos for worktrees).
@MainActor @Suite struct ControlRequestTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-control-\(UUID())")

    private func makeApp(_ build: (inout WorkspaceState) -> Void = { _ in }) throws -> AppState {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        build(&s)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        app.codexRead = nil
        return app
    }

    private func folder(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    private func ok<T: Decodable>(_ app: AppState, _ call: ControlCall, _: T.Type) async throws -> T {
        let r = await app.respond(7, call)
        #expect(r.id == 7)
        switch r.body {
        case .success(let data): return try JSONDecoder().decode(T.self, from: data)
        case .failure(let e): throw e
        }
    }

    private func error(_ app: AppState, _ call: ControlCall) async -> ControlError? {
        if case .failure(let e) = await app.respond(7, call).body { return e }
        return nil
    }

    // Fixtures run git synchronously: off the main actor so other suites' main-actor tasks keep running.
    private func repoWithCommit() async throws -> TempRepo {
        try await Task.detached {
            let t = try TempRepo(emptyWithBranch: "main")
            try t.commit(file: "a.txt", on: "main")
            return t
        }.value
    }

    @Test func projectsListAndAdd() async throws {
        let app = try makeApp()
        defer { cleanup() }
        let path = try folder("proj")
        let first = try await ok(app, .projectsAdd(path: path), ProjectAddResult.self)
        #expect(first.added && first.project.path == path && first.project.name == "proj" && first.project.exists)
        let again = try await ok(app, .projectsAdd(path: path + "/"), ProjectAddResult.self)
        #expect(!again.added && again.project.id == first.project.id)
        #expect(app.state.projects.count == 1)
        #expect(await error(app, .projectsAdd(path: dir.path + "/nope"))?.code == .notFound)

        let gone = try folder("gone")
        _ = try await ok(app, .projectsAdd(path: gone), ProjectAddResult.self)
        try FileManager.default.removeItem(atPath: gone)
        let list = try await ok(app, .projectsList, ProjectsResult.self)
        #expect(list.projects.map(\.path) == [path, gone])
        #expect(list.projects.map(\.exists) == [true, false])
    }

    @Test func tasksListShape() async throws {
        var ids: (p: UUID, q: UUID, a: UUID, b: UUID, archived: UUID, tab: UUID, claude: UUID) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        let pPath = try folder("p"), qPath = try folder("q")
        let app = try makeApp { s in
            ids.p = s.addProject(name: "p", path: pPath)
            ids.q = s.addProject(name: "q", path: qPath)
            ids.a = s.addTask(projectId: ids.p, name: "a")
            ids.b = s.addTask(projectId: ids.q, name: "b")
            ids.archived = s.addTask(projectId: ids.p, name: "old")
            s.archiveTask(id: ids.archived)
            ids.tab = s.addTab(taskId: ids.a, kind: .claude)
            ids.claude = s.tasks[0].tabs[0].root.leaves[0].id
            s.split(taskId: ids.a, tabId: ids.tab, leafId: ids.claude, axis: .horizontal, kind: .shell)
            s.addTab(taskId: ids.b, kind: .shell)
        }
        defer { cleanup() }
        app.handle(.event(EventMessage(tab: ids.tab, leaf: ids.claude, kind: .prompt)))

        let all = try await ok(app, .tasksList(project: nil), TasksResult.self)
        #expect(all.tasks.map(\.id) == [ids.a, ids.b])
        let a = all.tasks[0]
        #expect(a.status == "working" && a.mode == "main-folder" && a.path == pPath && a.projectName == "p" && a.project == ids.p)
        #expect(a.branch == nil && a.base == nil)
        #expect(a.tabs.count == 1 && a.tabs[0].id == ids.tab && a.tabs[0].leaves.count == 2)
        #expect(a.tabs[0].leaves.map(\.kind) == [.claude, .shell])
        #expect(a.tabs[0].leaves[0].status == "working")
        #expect(all.tasks[1].status == "idle")

        let byName = try await ok(app, .tasksList(project: "q"), TasksResult.self)
        #expect(byName.tasks.map(\.id) == [ids.b])
        let byPath = try await ok(app, .tasksList(project: pPath), TasksResult.self)
        #expect(byPath.tasks.map(\.id) == [ids.a])
        let missing = await error(app, .tasksList(project: "zzz"))
        #expect(missing?.code == .notFound && missing?.message == #"no project "zzz""#)
    }

    @Test func createMainFolderKeepsSelection() async throws {
        var a = UUID()
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            a = s.addTask(projectId: p, name: "A")
            s.addTab(taskId: a, kind: .shell)
            s.select(taskId: a)
        }
        defer { cleanup() }
        var started: [UUID] = []
        app.terminals = TerminalAccess(start: { started.append($0) }, send: { _, _, _ in .sent }, read: { _ in nil })

        let r = try await ok(app, .tasksCreate(project: "p", name: "B", worktree: false, base: nil, prompt: "hi"), TaskResult.self)
        let b = try #require(app.state.tasks.first { $0.name == "B" })
        #expect(r.task.id == b.id && r.task.mode == "main-folder" && r.task.path == path)
        #expect(app.state.selectedTaskId == a)
        #expect(b.tabs.count == 1 && b.tabs[0].root.leaves.map(\.kind) == [app.config.defaultAgent])
        #expect(r.task.tabs.map(\.id) == [b.tabs[0].id])
        #expect(started == [b.tabs[0].id])
        #expect(app.launchContext(for: b.tabs[0].root.leaves[0].id) == .created(prompt: "hi"))
        #expect(app.controlCreating == 0)
    }

    @Test func createWorktree() async throws {
        let t = try await repoWithCommit()
        defer { t.cleanup() }
        let plain = try folder("plain")
        let app = try makeApp { s in
            s.addProject(name: "repo", path: t.repo)
            s.addProject(name: "plain", path: plain)
        }
        defer { cleanup() }

        let r = try await ok(app, .tasksCreate(project: "repo", name: "Fix login", worktree: true, base: "main", prompt: nil), TaskResult.self)
        #expect(r.task.mode == "worktree" && r.task.branch == "fix-login" && r.task.base == "main")
        #expect(FileManager.default.fileExists(atPath: r.task.path))
        #expect(app.controlCreating == 0)
        // The sheet's remembered choice is the user's, not the CLI's.
        let repoProject = try #require(app.state.projects.first { $0.name == "repo" })
        #expect(!repoProject.worktreeByDefault && repoProject.lastBaseBranch == nil)

        // A name without letters still gives a branch (the slug falls back to "task").
        let punct = try await ok(app, .tasksCreate(project: "repo", name: "!!!", worktree: true, base: nil, prompt: nil), TaskResult.self)
        #expect(punct.task.branch == "task")
        #expect(app.controlCreating == 0)
        // Wire messages are English, never L10n.
        #expect(branchProblemMessage("", branches: []) == "task name gives an empty branch name")
        #expect(branchProblemMessage("main", branches: [Branch(name: "main", isRemote: false, lastCommit: Date())]) == #"branch "main" already exists"#)
        #expect(branchProblemMessage("a..b", branches: []) == #"invalid branch name "a..b""#)

        let noBase = await error(app, .tasksCreate(project: "repo", name: "Other", worktree: true, base: "nope", prompt: nil))
        #expect(noBase?.code == .notFound)
        #expect(app.controlCreating == 0)

        let notGit = await error(app, .tasksCreate(project: "plain", name: "Other", worktree: true, base: nil, prompt: nil))
        #expect(notGit?.code == .failed && notGit?.message == "not a git repository")
        #expect(app.controlCreating == 0)
        #expect(app.state.tasks.count == 2)
    }

    @Test func archiveResolvesStrictly() async throws {
        let t = try await repoWithCommit()
        defer { t.cleanup() }
        let other = try folder("other")
        let app = try makeApp { s in
            s.addProject(name: "repo", path: t.repo)
            let o = s.addProject(name: "other", path: other)
            s.addTask(projectId: o, name: "x")
        }
        defer { cleanup() }
        let wt = try await ok(app, .tasksCreate(project: "repo", name: "x", worktree: true, base: nil, prompt: nil), TaskResult.self)

        let both = await error(app, .tasksArchive(task: "x"))
        #expect(both?.code == .ambiguous)
        #expect(both?.message.contains(wt.task.id.uuidString) == true)
        #expect(app.state.tasks.allSatisfy { !$0.archived })

        let r = try await ok(app, .tasksArchive(task: wt.task.id.uuidString), ArchiveResult.self)
        #expect(r.task == wt.task.id && r.archived)
        #expect(app.state.tasks.first { $0.id == wt.task.id }?.archived == true)
        #expect(FileManager.default.fileExists(atPath: wt.task.path))
        #expect(await error(app, .tasksArchive(task: wt.task.id.uuidString))?.code == .notFound)
    }
    /// Records what the control handlers ask of the terminals.
    private final class FakeTerminals {
        var started: [UUID] = []
        var sent: [(leaf: UUID, text: String?, keys: [SendKey])] = []
        var outcomes: [SendOutcome] = []
        var screen: String?
        var access: TerminalAccess {
            TerminalAccess(start: { self.started.append($0) },
                           send: { leaf, text, keys in
                               self.sent.append((leaf, text, keys))
                               return self.outcomes.isEmpty ? .sent : self.outcomes.removeFirst()
                           },
                           read: { _ in self.screen })
        }
    }

    @Test func tabsOpenKeepsActiveTab() async throws {
        var ids = (a: UUID(), x: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            ids.a = s.addTask(projectId: p, name: "A")
            ids.x = s.addTab(taskId: ids.a, kind: .shell)
            s.select(taskId: ids.a)
            let old = s.addTask(projectId: p, name: "old")
            s.archiveTask(id: old)
        }
        defer { cleanup() }
        let fake = FakeTerminals()
        app.terminals = fake.access

        let r = try await ok(app, .tabsOpen(task: "A", kind: .claude, prompt: "go"), TabResult.self)
        let task = try #require(app.state.tasks.first { $0.id == ids.a })
        #expect(task.tabs.count == 2 && task.activeTabId == ids.x)
        #expect(app.state.selectedTaskId == ids.a)
        let new = task.tabs[1]
        #expect(r.task == ids.a && r.tab.id == new.id && r.tab.kind == .claude)
        #expect(fake.started == [new.id])
        #expect(app.launchContext(for: new.root.leaves[0].id) == .created(prompt: "go"))
        #expect(await error(app, .tabsOpen(task: "old", kind: .shell, prompt: nil))?.code == .notFound)
    }

    @Test func tabsSendTargets() async throws {
        var ids = (tab: UUID(), first: UUID(), second: UUID(), drawer: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            let a = s.addTask(projectId: p, name: "A")
            ids.tab = s.addTab(taskId: a, kind: .claude)
            ids.first = s.tasks[0].tabs[0].root.leaves[0].id
            ids.second = s.split(taskId: a, tabId: ids.tab, leafId: ids.first, axis: .horizontal, kind: .shell)
            s.setFocusedLeaf(taskId: a, tabId: ids.tab, leafId: ids.first)
            s.toggleDrawer(taskId: a)
            ids.drawer = s.tasks[0].drawer.leaf!.id
        }
        defer { cleanup() }
        let fake = FakeTerminals()
        app.terminals = fake.access

        let r = try await ok(app, .tabsSend(tab: ids.tab.uuidString, text: "hi", keys: [.enter]), SendResult.self)
        #expect(r.tab == ids.tab && r.leaf == ids.first)
        #expect(fake.sent.last?.leaf == ids.first && fake.sent.last?.text == "hi" && fake.sent.last?.keys == [.enter])
        let second = try await ok(app, .tabsSend(tab: String(ids.second.uuidString.prefix(8)), text: nil, keys: [.ctrlC]), SendResult.self)
        #expect(second.leaf == ids.second && fake.sent.last?.leaf == ids.second && fake.sent.last?.text == nil)
        #expect(await error(app, .tabsSend(tab: ids.drawer.uuidString, text: "x", keys: []))?.code == .notFound)
        #expect(fake.started.isEmpty)

        fake.outcomes = [.notStarted, .sent]
        _ = try await ok(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []), SendResult.self)
        #expect(fake.started == [ids.tab])
        // Spawned but still starting (no output yet): nothing is pasted, the caller retries.
        fake.outcomes = [.notStarted, .notStarted]
        let starting = await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))
        #expect(starting?.code == .notStarted && starting?.message == "tab is starting, retry")
        #expect(fake.started == [ids.tab, ids.tab])
        fake.outcomes = [.exited]
        let exited = await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))
        #expect(exited?.code == .exited && exited?.message == "process has exited; relaunch the tab")
    }

    @Test func waitingLeafAcceptsSend() async throws {
        var ids = (tab: UUID(), leaf: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            let a = s.addTask(projectId: p, name: "A")
            ids.tab = s.addTab(taskId: a, kind: .claude)
            ids.leaf = s.tasks[0].tabs[0].root.leaves[0].id
        }
        defer { cleanup() }
        let fake = FakeTerminals()
        app.terminals = fake.access
        app.handle(.event(EventMessage(tab: ids.tab, leaf: ids.leaf, kind: .prompt)))
        app.handle(.event(EventMessage(tab: ids.tab, leaf: ids.leaf, kind: .notification, notificationType: "permission_prompt")))
        #expect(app.state(ofLeaf: ids.leaf) == .waiting)
        _ = try await ok(app, .tabsSend(tab: ids.tab.uuidString, text: nil, keys: [.enter]), SendResult.self)
        #expect(app.state(ofLeaf: ids.leaf) == .waiting)
    }

    @Test func tabsReadLastLines() async throws {
        var ids = (tab: UUID(), leaf: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            let a = s.addTask(projectId: p, name: "A")
            ids.tab = s.addTab(taskId: a, kind: .shell)
            ids.leaf = s.tasks[0].tabs[0].root.leaves[0].id
        }
        defer { cleanup() }
        let fake = FakeTerminals()
        app.terminals = fake.access

        fake.screen = "a\nb\nc\n\n\n"
        let two = try await ok(app, .tabsRead(tab: ids.tab.uuidString, lines: 2), ScreenResult.self)
        #expect(two.text == "b\nc" && two.lines == 2 && two.truncated && two.tab == ids.tab && two.leaf == ids.leaf)
        let ten = try await ok(app, .tabsRead(tab: ids.tab.uuidString, lines: 10), ScreenResult.self)
        #expect(ten.text == "a\nb\nc" && ten.lines == 3 && !ten.truncated)
        fake.screen = String(repeating: "\u{44F}", count: 1_048_576)  // 2 MiB of 2-byte characters, one line
        let big = try await ok(app, .tabsRead(tab: ids.tab.uuidString, lines: 10), ScreenResult.self)
        #expect(big.text.utf8.count <= 524_288 && big.text.utf8.count > 524_000 && big.truncated)
        fake.screen = nil
        #expect(await error(app, .tabsRead(tab: ids.tab.uuidString, lines: 10))?.code == .notStarted)
    }
}
