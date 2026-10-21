import AgentStatus
import ControlServer
import Exec
import Foundation
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

        let noBase = await error(app, .tasksCreate(project: "repo", name: "Other", worktree: true, base: "nope", prompt: nil))
        #expect(noBase?.code == .notFound)
        #expect(app.controlCreating == 0)

        let notGit = await error(app, .tasksCreate(project: "plain", name: "Other", worktree: true, base: nil, prompt: nil))
        #expect(notGit?.code == .failed && notGit?.message == "not a git repository")
        #expect(app.controlCreating == 0)
        #expect(app.state.tasks.count == 1)
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
}
