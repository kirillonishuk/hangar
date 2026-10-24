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

    @Test func projectsListHost() async throws {
        // The remote project's path exists on this Mac: `projects add` of it still makes a new local project.
        let path = try folder("same")
        var remote = UUID()
        let app = try makeApp { remote = $0.addRemoteProject(name: "app", host: "dev", path: path) }
        defer { cleanup() }
        let list = try await ok(app, .projectsList, ProjectsResult.self)
        #expect(list.projects.map(\.host) == ["dev"])
        #expect(list.projects[0].exists)  // the host was never given up on
        let added = try await ok(app, .projectsAdd(path: path), ProjectAddResult.self)
        #expect(added.added && added.project.id != remote && added.project.host == nil)
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
        app.terminals = TerminalAccess(start: { started.append($0) }, state: { _ in .running }, send: { _, _, _ in }, read: { _ in nil })

        let r = try await ok(app, .tasksCreate(project: "p", name: "B", worktree: false, base: nil, prompt: "hi"), TaskResult.self)
        let b = try #require(app.state.tasks.first { $0.name == "B" })
        #expect(r.task.id == b.id && r.task.mode == "main-folder" && r.task.path == path)
        #expect(app.state.selectedTaskId == a)
        #expect(b.tabs.count == 1 && b.tabs[0].root.leaves.map(\.kind) == [app.config.defaultAgent])
        #expect(r.task.tabs.map(\.id) == [b.tabs[0].id])
        #expect(started == [b.tabs[0].id])
        #expect(app.launchContext(for: b.tabs[0].root.leaves[0].id) == .created(prompt: "hi"))
        #expect(app.controlCreating == 0)
        // Pane #968: the agent may stop on its folder-trust dialog; Hangar never answers it.
        #expect(r.note?.contains("trust") == true)
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
        let j = try await ok(app, .tasksCreate(project: "repo", name: "feat/JS-13333", worktree: true, base: "main", prompt: nil), TaskResult.self)
        #expect(j.task.branch == "feat/JS-13333" && j.task.path == t.repo + ".worktrees/feat-js-13333")
        #expect(app.controlCreating == 0)
        // The sheet's remembered choice is the user's, not the CLI's.
        let repoProject = try #require(app.state.projects.first { $0.name == "repo" })
        #expect(!repoProject.worktreeByDefault && repoProject.lastBaseBranch == nil)

        // A name without letters still gives a branch (the slug falls back to "task").
        let punct = try await ok(app, .tasksCreate(project: "repo", name: "!!!", worktree: true, base: nil, prompt: nil), TaskResult.self)
        #expect(punct.task.branch == "task")
        #expect(app.controlCreating == 0)
        // Wire messages are English, never L10n.
        #expect(branchProblemMessage("", branches: []) == "session name gives an empty branch name")
        #expect(branchProblemMessage("main", branches: [Branch(name: "main", isRemote: false, lastCommit: Date())]) == #"branch "main" already exists"#)
        #expect(branchProblemMessage("a..b", branches: []) == #"invalid branch name "a..b""#)

        let noBase = await error(app, .tasksCreate(project: "repo", name: "Other", worktree: true, base: "nope", prompt: nil))
        #expect(noBase?.code == .notFound)
        #expect(app.controlCreating == 0)

        let notGit = await error(app, .tasksCreate(project: "plain", name: "Other", worktree: true, base: nil, prompt: nil))
        #expect(notGit?.code == .failed && notGit?.message == "not a git repository")
        #expect(app.controlCreating == 0)
        #expect(app.state.tasks.count == 3)
    }

    /// CLI/MCP never run the lockfile's suggested command (no consent); a command saved to the project runs.
    @Test func createWorktreeRunsOnlySavedSetup() async throws {
        let t = try await repoWithCommit()
        defer { t.cleanup() }
        try await Task.detached { try t.commit(file: "pnpm-lock.yaml", on: "main") }.value
        var project = UUID()
        let app = try makeApp { s in project = s.addProject(name: "repo", path: t.repo) }
        defer { cleanup() }
        let plain = try await ok(app, .tasksCreate(project: "repo", name: "a", worktree: true, base: "main", prompt: nil), TaskResult.self)
        #expect(app.state.tasks.first { $0.id == plain.task.id }?.tabs.count == 1)
        #expect(app.project(project)?.setupCommand == nil)
        app.perform { $0.setWorktreeSetup(id: project, copy: nil, command: "pnpm i") }
        let saved = try await ok(app, .tasksCreate(project: "repo", name: "b", worktree: true, base: "main", prompt: nil), TaskResult.self)
        let task = try #require(app.state.tasks.first { $0.id == saved.task.id })
        #expect(task.tabs.count == 2)
        let shell = try #require(task.tabs.last?.root.leaves.first)
        #expect(app.launchContext(for: shell.id) == .created(prompt: "pnpm i"))
    }

    /// tasks.create with a worktree on a host that isn't connected: says so in English, not "not a git repository".
    @Test func worktreeOnOfflineHost() async throws {
        let app = try makeApp { s in _ = s.addRemoteProject(name: "srv", host: "dev", path: "/srv/app") }
        defer { cleanup() }
        // Never a real ssh: the host is never connected, and this ssh could not dial anyway.
        app.remote = app.makeRemoteHosts(paths: SSHPaths(stateDir: dir.path), sshPath: "/usr/bin/false", isActive: { false })
        let e = await error(app, .tasksCreate(project: "srv", name: "Other", worktree: true, base: nil, prompt: nil))
        #expect(e?.code == .failed && e?.message == "host dev is not connected")
        #expect(app.state.tasks.isEmpty)
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

        // Dirty: refused without force, nothing changes; with force the folder goes, the branch stays.
        try "u".write(toFile: wt.task.path + "/untracked.txt", atomically: true, encoding: .utf8)
        let dirty = await error(app, .tasksArchive(task: wt.task.id.uuidString))
        #expect(dirty?.code == .confirmRequired)
        #expect(dirty?.message.contains("--force") == true && dirty?.message.contains("uncommitted") == true)
        #expect(app.state.tasks.first { $0.id == wt.task.id }?.archived == false)
        #expect(FileManager.default.fileExists(atPath: wt.task.path + "/untracked.txt"))

        let r = try await ok(app, .tasksArchive(task: wt.task.id.uuidString, force: true), ArchiveResult.self)
        #expect(r.task == wt.task.id && r.archived && r.worktreeRemoved)
        #expect(app.state.tasks.first { $0.id == wt.task.id }?.archived == true)
        #expect(!FileManager.default.fileExists(atPath: wt.task.path))
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
        #expect(await error(app, .tasksArchive(task: wt.task.id.uuidString))?.code == .notFound)

        // A main-folder task: just archived.
        let plain = try await ok(app, .tasksArchive(task: "x"), ArchiveResult.self)
        #expect(plain.archived && !plain.worktreeRemoved)
    }

    /// tasks.restore finds only archived tasks and re-creates the worktree from its kept branch.
    @Test func restoreRecreatesWorktree() async throws {
        let t = try await repoWithCommit()
        defer { t.cleanup() }
        let app = try makeApp { s in s.addProject(name: "repo", path: t.repo) }
        defer { cleanup() }
        let wt = try await ok(app, .tasksCreate(project: "repo", name: "y", worktree: true, base: nil, prompt: nil), TaskResult.self)
        #expect(await error(app, .tasksRestore(task: "y"))?.code == .notFound)  // not archived
        _ = try await ok(app, .tasksArchive(task: "y"), ArchiveResult.self)
        #expect(!FileManager.default.fileExists(atPath: wt.task.path))

        let r = try await ok(app, .tasksRestore(task: "y"), TaskResult.self)
        #expect(r.task.id == wt.task.id && r.task.branch == "y")
        #expect(app.state.tasks.first { $0.id == wt.task.id }?.archived == false)
        #expect(FileManager.default.fileExists(atPath: wt.task.path))

        // Branch gone: nothing changes, the error says why.
        _ = try await ok(app, .tasksArchive(task: "y"), ArchiveResult.self)
        _ = try t.git("branch", "-D", "y", in: t.repo)
        let gone = await error(app, .tasksRestore(task: "y"))
        #expect(gone?.code == .failed && gone?.message.contains("branch") == true)
        #expect(app.state.tasks.first { $0.id == wt.task.id }?.archived == true)
    }

    /// `git: true` adds changes vs base, dirty and ahead/behind; without it the list runs no git.
    @Test func tasksListGitStatus() async throws {
        let t = try await repoWithCommit()
        defer { t.cleanup() }
        let app = try makeApp { s in s.addProject(name: "repo", path: t.repo) }
        defer { cleanup() }
        let wt = try await ok(app, .tasksCreate(project: "repo", name: "z", worktree: true, base: "main", prompt: nil), TaskResult.self)
        try "one\ntwo\n".write(toFile: wt.task.path + "/b.txt", atomically: true, encoding: .utf8)
        _ = try t.git("add", "b.txt", in: wt.task.path)
        _ = try t.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "b", in: wt.task.path)
        try "u".write(toFile: wt.task.path + "/new.txt", atomically: true, encoding: .utf8)

        let plain = try await ok(app, .tasksList(project: nil), TasksResult.self)
        #expect(plain.tasks[0].changes == nil && plain.tasks[0].dirty == nil && plain.tasks[0].ahead == nil)

        let r = try await ok(app, .tasksList(project: nil, git: true), TasksResult.self)
        let task = r.tasks[0]
        #expect(task.changes == ChangesInfo(added: 2, removed: 0, files: 2))
        #expect(task.dirty == true)
        #expect(task.ahead == 1 && task.behind == 0)
    }
    /// Records what the control handlers ask of the terminals.
    private final class FakeTerminals {
        var started: [UUID] = []
        var sent: [(leaf: UUID, text: String?, keys: [SendKey])] = []
        /// Answered in order, then `.running`.
        var states: [LeafState] = []
        var screen: String?
        var onSend: (() -> Void)?
        var access: TerminalAccess {
            TerminalAccess(start: { self.started.append($0) },
                           state: { _ in self.states.isEmpty ? .running : self.states.removeFirst() },
                           send: { leaf, text, keys in self.sent.append((leaf, text, keys)); self.onSend?() },
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
        #expect(fake.started.isEmpty)

        fake.states = [.notStarted, .running]
        _ = try await ok(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []), SendResult.self)
        #expect(fake.started == [ids.tab])
        let sentCount = fake.sent.count
        // Spawned but still starting (no output yet): nothing is pasted, the caller retries.
        fake.states = [.notStarted, .starting]
        let starting = await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))
        #expect(starting?.code == .notStarted && starting?.message == "tab is starting, retry")
        #expect(fake.started == [ids.tab, ids.tab])
        fake.states = [.exited]
        let exited = await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))
        #expect(exited?.code == .exited && exited?.message == "process has exited; relaunch the tab")
        // Launch failed or cannot launch (missing folder): retrying will not help.
        fake.states = [.failed]
        let failed = await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))
        #expect(failed?.code == .failed && failed?.message == "tab could not start")
        fake.states = [.notStarted, .failed]
        #expect(await error(app, .tabsSend(tab: ids.tab.uuidString, text: "x", keys: []))?.code == .failed)
        #expect(fake.sent.count == sentCount)
    }

    /// The TERMINAL drawer's shell: listed in tasks.list, its leaf id works as the `tab` ref (decision #45).
    @Test func drawerLeafAddressable() async throws {
        var ids = (a: UUID(), b: UUID(), drawer: UUID(), oldDrawer: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            ids.a = s.addTask(projectId: p, name: "A")
            s.addTab(taskId: ids.a, kind: .claude)
            s.toggleDrawer(taskId: ids.a)
            ids.drawer = s.tasks[0].drawer.leaf!.id
            ids.b = s.addTask(projectId: p, name: "B")
            let old = s.addTask(projectId: p, name: "old")
            s.toggleDrawer(taskId: old)
            ids.oldDrawer = s.tasks.first { $0.id == old }!.drawer.leaf!.id
            s.archiveTask(id: old)
        }
        defer { cleanup() }
        let fake = FakeTerminals()
        app.terminals = fake.access

        let list = try await ok(app, .tasksList(project: nil), TasksResult.self)
        let a = try #require(list.tasks.first { $0.id == ids.a })
        #expect(a.drawer?.id == ids.drawer && a.drawer?.kind == .shell)
        #expect(a.tabs.allSatisfy { !$0.leaves.contains { $0.id == ids.drawer } })
        #expect(list.tasks.first { $0.id == ids.b }?.drawer == nil)

        // Never shown since launch: started hidden first, like a tab.
        fake.states = [.notStarted, .running]
        let r = try await ok(app, .tabsSend(tab: ids.drawer.uuidString, text: "ls", keys: [.enter]), SendResult.self)
        #expect(r.tab == ids.drawer && r.leaf == ids.drawer)
        #expect(fake.started == [ids.drawer])
        #expect(fake.sent.last?.leaf == ids.drawer && fake.sent.last?.text == "ls")
        fake.states = [.notStarted, .starting]
        #expect(await error(app, .tabsSend(tab: ids.drawer.uuidString, text: "x", keys: []))?.code == .notStarted)

        fake.screen = "$ ls\nfoo\n"
        let read = try await ok(app, .tabsRead(tab: String(ids.drawer.uuidString.prefix(8)), lines: 10), ScreenResult.self)
        #expect(read.tab == ids.drawer && read.leaf == ids.drawer && read.text == "$ ls\nfoo")

        // Archived tasks' drawers are never found.
        #expect(await error(app, .tabsRead(tab: ids.oldDrawer.uuidString, lines: 10))?.code == .notFound)
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

    private func agentApp(_ kind: LeafKind) throws -> (AppState, tab: UUID, leaf: UUID, FakeTerminals) {
        var ids = (tab: UUID(), leaf: UUID())
        let path = try folder("p")
        let app = try makeApp { s in
            let p = s.addProject(name: "p", path: path)
            let a = s.addTask(projectId: p, name: "A")
            ids.tab = s.addTab(taskId: a, kind: kind)
            ids.leaf = s.tasks[0].tabs[0].root.leaves[0].id
        }
        let fake = FakeTerminals()
        app.terminals = fake.access
        app.sendWaitTimeout = .milliseconds(50)
        return (app, ids.tab, ids.leaf, fake)
    }

    /// Pane #302/#723: `wait` confirms the turn started (claude's UserPromptSubmit hook → working).
    @Test func sendWaitConfirmsStart() async throws {
        let (app, tab, leaf, fake) = try agentApp(.claude)
        defer { cleanup() }
        let plain = try await ok(app, .tabsSend(tab: tab.uuidString, text: "hi", keys: [.enter]), SendResult.self)
        #expect(plain.status == "sent" && plain.hint == nil)

        app.sendWaitTimeout = .seconds(5)
        fake.onSend = { Task { @MainActor in app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: .prompt))) } }
        let started = try await ok(app, .tabsSend(tab: tab.uuidString, text: "hi", keys: [.enter], wait: true), SendResult.self)
        #expect(started.status == "started")

        // Already working: claude queues the input.
        fake.onSend = nil
        let queued = try await ok(app, .tabsSend(tab: tab.uuidString, text: "more", keys: [.enter], wait: true), SendResult.self)
        #expect(queued.status == "queued" && queued.hint != nil)
    }

    @Test func sendWaitTimesOut() async throws {
        let (app, tab, _, _) = try agentApp(.claude)
        defer { cleanup() }
        let r = try await ok(app, .tabsSend(tab: tab.uuidString, text: "hi", keys: [.enter], wait: true), SendResult.self)
        #expect(r.status == "not-started-yet" && r.hint?.contains("tabs read") == true)
    }

    /// Pane #945/#496: Enter into a working codex is refused; codex reports no turn start, so `wait` cannot confirm.
    @Test func codexBusyAndWait() async throws {
        let (app, tab, _, fake) = try agentApp(.codex)
        defer { cleanup() }
        fake.screen = "› fix it\n\n• Working (3s • esc to interrupt)\n"
        let busy = await error(app, .tabsSend(tab: tab.uuidString, text: "next", keys: [.enter]))
        #expect(busy?.code == .busy && busy?.message.contains("interrupt") == true)
        #expect(fake.sent.isEmpty)
        // Keys without Enter (an interrupt) still go through.
        _ = try await ok(app, .tabsSend(tab: tab.uuidString, text: nil, keys: [.interrupt]), SendResult.self)
        #expect(fake.sent.last?.keys == [.escape])

        fake.screen = "› \n"
        let r = try await ok(app, .tabsSend(tab: tab.uuidString, text: "go", keys: [.enter], wait: true), SendResult.self)
        #expect(r.status == "sent" && r.hint?.contains("codex") == true)
    }

    @Test func interruptKeyPerKind() async throws {
        let (app, tab, _, fake) = try agentApp(.shell)
        defer { cleanup() }
        _ = try await ok(app, .tabsSend(tab: tab.uuidString, text: nil, keys: [.interrupt, .enter]), SendResult.self)
        #expect(fake.sent.last?.keys == [.ctrlC, .enter])
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
        #expect(fake.started.isEmpty)
        // Never started: the read starts it hidden, like send, and the caller retries.
        fake.screen = nil
        fake.states = [.notStarted, .starting]
        let starting = await error(app, .tabsRead(tab: ids.tab.uuidString, lines: 10))
        #expect(starting?.code == .notStarted && starting?.message == "tab is starting, retry")
        #expect(fake.started == [ids.tab])
        // Same leaf states as send: a leaf that cannot launch says so instead of "retry".
        fake.states = [.notStarted, .failed]
        let failed = await error(app, .tabsRead(tab: ids.tab.uuidString, lines: 10))
        #expect(failed?.code == .failed && failed?.message == "tab could not start")
        fake.states = [.failed]
        #expect(await error(app, .tabsRead(tab: ids.tab.uuidString, lines: 10))?.code == .failed)
        // An exited leaf's last screen stays readable.
        fake.states = [.exited]
        fake.screen = "bye"
        #expect(try await ok(app, .tabsRead(tab: ids.tab.uuidString, lines: 10), ScreenResult.self).text == "bye")
    }
}
