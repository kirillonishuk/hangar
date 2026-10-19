import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// Real temp repositories (bare origin + clone); no mocked git output.
@MainActor @Suite struct NewTaskModelTests {
    private func model(_ t: TempRepo, path: String? = nil, worktreeByDefault: Bool = false, lastBase: String? = nil,
                       root: String? = nil) -> NewTaskModel {
        let dir = path ?? t.repo
        let project = Project(name: "p", location: .local(path: dir), lastBaseBranch: lastBase,
                              worktreeByDefault: worktreeByDefault, worktreeRoot: root)
        return NewTaskModel(project: project, git: Git(repo: dir), taskBranches: [])
    }

    // Fixtures run git synchronously: build them off the main actor so other suites' main-actor tasks keep running.
    private func repo() async throws -> TempRepo { try await Task.detached { try TempRepo() }.value }
    private func emptyRepo() async throws -> TempRepo {
        try await Task.detached { try TempRepo(emptyWithBranch: "main") }.value
    }

    /// Generous: parallel tests' fixtures run git synchronously on the main actor.
    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func branchFollowsNameUntilEdited() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t)
        m.name = "Починить логин"
        #expect(m.branch == "pochinit-login")
        m.branch = "feat/login"
        m.name = "x"
        #expect(m.branch == "feat/login")
        m.branch = ""
        m.name = "y"
        #expect(m.branch == "y")
    }

    @Test func defaultsFromProject() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try t.git("branch", "release", in: t.repo)
        try t.pushBranch("release")
        let m = model(t, worktreeByDefault: true, lastBase: "origin/release")
        #expect(m.worktree == true)
        await m.load()
        #expect(m.availability == .ready)
        #expect(m.base == "origin/release")
        #expect(m.defaultBase == "origin/main")
        #expect(m.currentBranch == "main")
    }

    @Test func staleLastBaseFallsBackToDefault() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, lastBase: "origin/gone")
        await m.load()
        #expect(m.base == "origin/main")
    }

    @Test func refreshFetchesNewRemoteBranches() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try t.git("branch", "only-remote", in: t.repo)
        try t.pushBranch("only-remote")
        try t.git("branch", "-r", "-d", "origin/only-remote", in: t.repo)
        let m = model(t)
        await m.load()
        #expect(m.fetch == .done)
        #expect(m.branches.contains { $0.name == "origin/only-remote" && $0.isRemote })
        #expect(m.lastFetch != nil)
    }

    @Test func existingBranchIsRejected() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try t.git("branch", "fix", in: t.repo)
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "n"
        m.branch = "fix"
        await m.validateBranch()
        #expect(m.branchError == L10n.branchExists("fix"))
        #expect(m.canCreate == false)
        m.branch = "bad..x"
        await m.validateBranch()
        #expect(m.branchError == L10n.branchInvalid)
        m.branch = ""
        await m.validateBranch()
        #expect(m.branchError == L10n.branchRequired)
        m.branch = "fresh"
        await m.validateBranch()
        #expect(m.branchError == nil)
        #expect(m.canCreate == true)
    }

    @Test func suggestedBranchSkipsTakenNamesAndFolders() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try t.git("branch", "pochinit-login", in: t.repo)                // local
        try t.git("branch", "pochinit-login-2", in: t.repo)
        try t.pushBranch("pochinit-login-2")
        try t.git("branch", "-D", "pochinit-login-2", in: t.repo)          // remote only
        try FileManager.default.createDirectory(atPath: t.repo + ".worktrees/pochinit-login-3",
                                                withIntermediateDirectories: true)   // folder only
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "Починить логин"
        #expect(m.branch == "pochinit-login-4")
        let mode = await m.create(skipFetch: false)
        #expect(mode == .worktree(path: t.repo + ".worktrees/pochinit-login-4", branch: "pochinit-login-4",
                                  base: "origin/main"))

        // A user-typed name that exists gets an error, not a suffix.
        let m2 = model(t, worktreeByDefault: true)
        await m2.load()
        m2.name = "x"
        m2.branch = "pochinit-login"
        #expect(await m2.create(skipFetch: false) == nil)
        #expect(m2.branch == "pochinit-login")
        #expect(m2.branchError == L10n.branchExists("pochinit-login"))
    }

    @Test func createMakesWorktreeFromBase() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "Починить логин"
        let path = t.repo + ".worktrees/pochinit-login"
        #expect(await m.create(skipFetch: false) == .worktree(path: path, branch: "pochinit-login", base: "origin/main"))
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
        #expect(m.fetch == .done)
        #expect(m.creating == false)
    }

    @Test func worktreeRootIsUsed() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let root = t.root + "/wt root"
        let m = model(t, worktreeByDefault: true, root: root)
        await m.load()
        m.name = "a b"
        #expect(await m.create(skipFetch: false) == .worktree(path: root + "/a-b", branch: "a-b", base: "origin/main"))
        #expect(FileManager.default.fileExists(atPath: root + "/a-b/a.txt"))
    }

    @Test func fetchFailureBlocksUntilSkip() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try t.git("remote", "set-url", "origin", "/nonexistent", in: t.repo)
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "task"
        #expect(await m.create(skipFetch: false) == nil)
        guard case .failed(let stderr) = m.fetch else { Issue.record("expected .failed, got \(m.fetch)"); return }
        #expect(!stderr.isEmpty)
        let path = t.repo + ".worktrees/task"
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await m.create(skipFetch: true) == .worktree(path: path, branch: "task", base: "origin/main"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func existingFolderKeepsSheetOpen() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let path = t.repo + ".worktrees/busy"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "x".write(toFile: path + "/keep.txt", atomically: true, encoding: .utf8)
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: URL(fileURLWithPath: t.root + "/state")),
                           config: HangarConfig(), configURL: URL(fileURLWithPath: t.root + "/c.toml"))
        let before = app.state
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "busy"
        m.branch = "busy"  // typed by the user: no auto-suffix around the existing folder
        #expect(await m.create(skipFetch: false) == nil)
        #expect(m.createError?.isEmpty == false)
        #expect(m.createError?.contains("already exists") == true)
        #expect(FileManager.default.fileExists(atPath: path + "/keep.txt"))
        #expect(app.state == before)
    }

    @Test func noRemoteSkipsFetch() async throws {
        let t = try await emptyRepo()
        defer { t.cleanup() }
        try t.commit(file: "a.txt", on: "main")
        let m = model(t, worktreeByDefault: true)
        await m.load()
        #expect(m.fetch == .noRemote)
        #expect(m.base == "main")
        m.name = "t"
        #expect(await m.create(skipFetch: false) == .worktree(path: t.repo + ".worktrees/t", branch: "t", base: "main"))
    }

    @Test func emptyRepoDisablesWorktree() async throws {
        let t = try await emptyRepo()
        defer { t.cleanup() }
        let m = model(t, worktreeByDefault: true)
        await m.load()
        #expect(m.availability == .noCommits)
        m.name = "t"
        #expect(m.canCreate == false)
        m.worktree = false
        #expect(m.canCreate == true)
        #expect(await m.create(skipFetch: false) == .mainFolder)
    }

    @Test func nonRepositoryHidesWorktree() async throws {
        let dir = NSTemporaryDirectory() + "hangar-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = Project(name: "p", location: .local(path: dir), worktreeByDefault: true)
        let m = NewTaskModel(project: project, git: Git(repo: dir), taskBranches: [])
        await m.load()
        #expect(m.availability == .notRepository)
        m.name = "t"
        #expect(m.canCreate == true)
        #expect(await m.create(skipFetch: false) == .mainFolder)
    }

    @Test func cancelStopsHangingFetch() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        // A remote that never answers (the helper just sleeps).
        try t.git("config", "protocol.ext.allow", "always", in: t.repo)
        try t.git("remote", "set-url", "origin", "ext::sleep 30", in: t.repo)
        let m = model(t, worktreeByDefault: true)
        let loading = Task { await m.load() }
        try await wait { m.fetch == .running }
        #expect(m.fetch == .running)
        await m.refresh()  // no-op while running
        #expect(m.fetch == .running)
        m.name = "t"
        let creating = Task { await m.create(skipFetch: false) }
        try await wait { m.creating }
        let started = ContinuousClock.now
        m.cancelFetch()
        #expect(m.fetch == .cancelled)
        await loading.value
        #expect(await creating.value == nil)
        #expect(ContinuousClock.now - started < .seconds(15))  // well under the helper's 30 s
        #expect(m.fetch == .cancelled)
        #expect(await m.create(skipFetch: true) == .worktree(path: t.repo + ".worktrees/t", branch: "t", base: "origin/main"))
    }

    @Test func createTaskRemembersChoice() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp/p")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-create-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"))
        app.createTask(projectId: p, name: "t", firstMessage: "",
                       mode: .worktree(path: "/tmp/p.worktrees/t", branch: "t", base: "origin/dev"))
        let project = try #require(app.project(p))
        #expect(project.worktreeByDefault == true)
        #expect(project.lastBaseBranch == "origin/dev")
        let task = try #require(app.state.tasks.first)
        #expect(app.state.selectedTaskId == task.id)
        #expect(task.tabs.first?.root.leaves.first?.cwd == "/tmp/p.worktrees/t")
        #expect(app.taskBranches(p) == ["t"])

        app.createTask(projectId: p, name: "u", firstMessage: "", mode: .mainFolder)
        #expect(app.project(p)?.worktreeByDefault == false)
        #expect(app.project(p)?.lastBaseBranch == "origin/dev")
    }

    @Test func newStringsAreLocalized() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.branchExists("fix") == "Ветка «fix» уже существует")
        #expect(L10n.createWithoutFetch == "Создать без fetch")
        L10n.language = .en
        #expect(L10n.branchExists("fix") == "Branch “fix” already exists")
        #expect(L10n.noCommits == "the repository has no commits")
    }
}
