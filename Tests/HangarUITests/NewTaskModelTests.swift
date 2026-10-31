import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace
import TestSupport

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
    private func repo() async throws -> TempRepo { try await TempRepo.offMain() }
    private func emptyRepo() async throws -> TempRepo { try await TempRepo.offMain { try TempRepo(emptyWithBranch: "main") } }

    private func wait(polls: Int = 3000, until condition: () -> Bool) async throws {
        try #require(await waitUntil(polls: polls, condition))
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

    /// Empty «Название» (decision #116): creatable; the branch follows the message, else «Чат N».
    @Test func emptyNameNamesTheChatAndItsBranch() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        L10n.language = .ru
        defer { L10n.language = .system }
        let project = Project(name: "p", location: .local(path: t.repo), worktreeByDefault: true)
        var names = ["Чат 1"]
        let m = NewTaskModel(project: project, git: Git(repo: t.repo), taskBranches: [], chatNames: { names })
        await m.load()
        #expect(m.head == .branch("main"))
        #expect(m.chatName == "Чат 2")
        #expect(m.branch == "chat-2")
        #expect(m.canCreate == true)
        names.append("Чат 2")  // another window created one meanwhile
        #expect(m.chatName == "Чат 3")
        m.message = "Почини логин"
        #expect(m.chatName == "Почини логин")
        #expect(m.branch == "pochini-login")
        m.name = "fix"
        #expect(m.branch == "fix")
        m.name = ""
        #expect(await m.create(skipFetch: false) == .worktree(path: t.repo + ".worktrees/pochini-login",
                                                              branch: "pochini-login", base: "origin/main"))
    }

    @Test func defaultsFromProject() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try await t.git("branch", "release", in: t.repo)
        try await t.pushBranch("release")
        let m = model(t, worktreeByDefault: true, lastBase: "origin/release")
        #expect(m.worktree == true)
        await m.load()
        #expect(m.availability == .ready)
        #expect(m.base == "origin/release")
        #expect(m.defaultBase == "origin/main")
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
        try await t.git("branch", "only-remote", in: t.repo)
        try await t.pushBranch("only-remote")
        try await t.git("branch", "-r", "-d", "origin/only-remote", in: t.repo)
        let m = model(t)
        await m.load()
        #expect(m.fetch == .done)
        #expect(m.branches.contains { $0.name == "origin/only-remote" && $0.isRemote })
        #expect(m.lastFetch != nil)
    }

    @Test func existingBranchIsRejected() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        try await t.git("branch", "fix", in: t.repo)
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
        try await t.git("branch", "pochinit-login", in: t.repo)                // local
        try await t.git("branch", "pochinit-login-2", in: t.repo)
        try await t.pushBranch("pochinit-login-2")
        try await t.git("branch", "-D", "pochinit-login-2", in: t.repo)          // remote only
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

    /// git can't have both `release` and `release/1.2` (a ref is a file or a folder): such a verbatim name → slug.
    @Test func verbatimNameClashingWithAPrefixFallsBackToSlug() async throws {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try t.git("branch", "Release", in: t.repo)
            try t.git("branch", "hotfix/x/y", in: t.repo)
            return t
        }
        defer { t.cleanup() }
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "release/1.2"  // an existing branch is a `/`-prefix of it (case-insensitive, as on disk)
        #expect(m.branch == "release-1.2")
        m.name = "hotfix/x"  // it is a `/`-prefix of an existing branch
        #expect(m.branch == "hotfix-x")
        m.name = "hotfix/z"
        #expect(m.branch == "hotfix/z")
        m.name = "release/1.2"
        #expect(await m.create(skipFetch: false) == .worktree(path: t.repo + ".worktrees/release-1.2", branch: "release-1.2", base: "origin/main"))
    }

    /// A host that isn't connected is «not connected», not «not a repository».
    @Test func offlineHostIsNotNotARepository() async {
        let project = Project(name: "p", location: .ssh(host: "dev", path: "/srv/app"), worktreeByDefault: true)
        let git = Git(repo: "/srv/app", runner: Runner { _, _ in throw RemoteHostError.notConnected("dev") })
        let m = NewTaskModel(project: project, git: git, taskBranches: [])
        await m.load()
        #expect(m.availability == .hostOffline("dev"))
        #expect(!m.worktree)
    }

    @Test func branchLikeNameIsSuggestedVerbatim() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "  feat/JS-13333 "
        #expect(m.branch == "feat/JS-13333")
        m.name = "Fix login"
        #expect(m.branch == "fix-login")
        m.name = "feat//x"
        #expect(m.branch == "feat-x")
        m.name = "Refactor"  // no `/`: a single word keeps the slug
        #expect(m.branch == "refactor")
        m.name = "origin/feature-x"  // starts with a remote: verbatim would shadow origin/feature-x
        #expect(m.branch == "origin-feature-x")
        m.name = "feat/JS-13333"
        let mode = await m.create(skipFetch: false)
        #expect(mode == .worktree(path: t.repo + ".worktrees/feat-js-13333", branch: "feat/JS-13333", base: "origin/main"))

        // Differs only in case: same folder (and same ref file on a case-insensitive disk) → suffix, not a clash.
        let m2 = model(t, worktreeByDefault: true)
        await m2.load()
        m2.name = "feat/js-13333"
        #expect(m2.branch == "feat/js-13333-2")
        let mode2 = await m2.create(skipFetch: false)
        #expect(mode2 == .worktree(path: t.repo + ".worktrees/feat-js-13333-2", branch: "feat/js-13333-2", base: "origin/main"))
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
        try await t.git("remote", "set-url", "origin", "/nonexistent", in: t.repo)
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
        let m = model(t, worktreeByDefault: true)
        await m.load()
        m.name = "busy"
        m.branch = "busy"  // typed by the user: no auto-suffix around the existing folder
        #expect(await m.create(skipFetch: false) == nil)
        #expect(m.createError?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: path + "/keep.txt"))
        #expect(try await t.git("branch", "--list", "busy", in: t.repo).isEmpty)  // the failed add left no branch
        #expect(!m.creating)  // the sheet is usable again: the user can fix the name and retry
    }

    @Test func noRemoteSkipsFetch() async throws {
        let t = try await emptyRepo()
        defer { t.cleanup() }
        try await t.commit(file: "a.txt", on: "main")
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
        // The switch shows off (and disabled): the remembered «worktree» can't block creating.
        #expect(m.worktree == false)
        m.name = "t"
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

    /// The probe answers before the sheet opens: a plain folder's sheet never starts with the copy chosen (#122).
    @Test func probedPlainFolderStartsWithoutCopy() async throws {
        let dir = NSTemporaryDirectory() + "hangar-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let known = await NewTaskModel.probe(Git(repo: dir))
        #expect(known == NewTaskModel.Probe(availability: .notRepository))
        let project = Project(name: "p", location: .local(path: dir), worktreeByDefault: true)
        let m = NewTaskModel(project: project, git: Git(repo: dir), taskBranches: [], known: known)
        #expect(m.availability == .notRepository && !m.worktree)
        await m.load()
        #expect(m.availability == .notRepository && !m.worktree)

        let t = try await repo()
        defer { t.cleanup() }
        let ready = await NewTaskModel.probe(Git(repo: t.repo))
        #expect(ready == NewTaskModel.Probe(availability: .ready, head: .branch("main")))
        let r = NewTaskModel(project: Project(name: "r", location: .local(path: t.repo), worktreeByDefault: true),
                             git: Git(repo: t.repo), taskBranches: [], known: ready)
        #expect(r.availability == .loading && r.worktree && r.head == .branch("main"))
    }

    @Test func cancelStopsHangingFetch() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        // A remote that never answers (the helper just sleeps).
        try await t.git("config", "protocol.ext.allow", "always", in: t.repo)
        try await t.git("remote", "set-url", "origin", "ext::sleep 120", in: t.repo)
        let m = model(t, worktreeByDefault: true)
        let loading = Task { await m.load() }
        // Long deadlines: under a full parallel run load() and create's first awaits wait for busy git spawns.
        try await wait(polls: 4500) { m.fetch == .running }
        #expect(m.fetch == .running)
        await m.refresh()  // no-op while running
        #expect(m.fetch == .running)
        m.name = "t"
        let creating = Task { await m.create(skipFetch: false) }
        try await wait(polls: 4500) { m.creating }
        let clock = SuspendingClock(), started = clock.now
        m.cancelFetch()
        #expect(m.fetch == .cancelled)
        await loading.value
        #expect(await creating.value == nil)
        #expect(clock.now - started < .seconds(60))  // well under the helper's 120 s
        #expect(m.fetch == .cancelled)

        // While creating: ↻ starts no fetch, and edits made during create's awaits don't change what is created.
        let skipping = Task { await m.create(skipFetch: true) }
        await Task.yield()  // runs create up to its first git await
        #expect(m.creating)
        m.branch = "edited"
        await m.refresh()
        #expect(m.fetch == .cancelled)
        #expect(await skipping.value == .worktree(path: t.repo + ".worktrees/t", branch: "t", base: "origin/main"))
    }

    @Test func staleBranchValidationIsDropped() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t)
        await m.load()
        m.branch = "main"  // exists: its (slower, git-backed) validation says so
        let first = Task { await m.validateBranch() }
        await Task.yield()  // runs it up to its first git await
        m.branch = ""
        await m.validateBranch()  // answers at once: «required»
        await first.value
        #expect(m.branchError == L10n.branchRequired)
    }

    @Test func clearingBranchClearsItsError() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t)
        await m.load()
        m.branch = "main"
        await m.validateBranch()
        #expect(m.branchError != nil)
        m.branch = ""
        #expect(m.branchFollowsName)
        #expect(m.branchError == nil)
    }

    @Test func loadCancelledBeforeFetchLeavesFetchIdle() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let m = model(t)
        let loading = Task { await m.load() }
        loading.cancel()
        await loading.value
        #expect(m.fetch == .idle)
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
