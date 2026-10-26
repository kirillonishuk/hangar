import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// End to end on a real repo for the user's branch shape `<type>/JS-<n>-<descr>` (#48): create → guard → archive → restore.
@MainActor @Suite struct WorktreeBranchFlowTests {
    private let name = "feat/JS-12345-short-descr"
    private let slug = "feat-js-12345-short-descr"

    /// The repo has an `apps/saas` subfolder; the worktree root contains spaces.
    private func repo() async throws -> TempRepo {
        try await TempRepo.offMain {
            let t = try TempRepo()
            try FileManager.default.createDirectory(atPath: t.repo + "/apps/saas", withIntermediateDirectories: true)
            try "{}".write(toFile: t.repo + "/apps/saas/package.json", atomically: true, encoding: .utf8)
            try t.git("add", ".", in: t.repo)
            try t.git("commit", "-q", "-m", "saas", in: t.repo)
            try t.git("push", "-q", "origin", "main", in: t.repo)
            return t
        }
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    /// `projectPath`: the repo itself or its subfolder. Returns the app, task id and worktree path.
    private func flow(_ t: TempRepo, projectPath: String) async throws -> (AppState, UUID, String) {
        let root = t.root + "/my work trees"
        let project = Project(name: "p", location: .local(path: projectPath), worktreeByDefault: true, worktreeRoot: root)
        let m = NewTaskModel(project: project, git: Git(repo: projectPath), taskBranches: [])
        await m.load()
        m.name = name
        #expect(m.branch == name)  // verbatim, not the slug (#48)
        guard case .worktree(let wt, let branch, _)? = await m.create(skipFetch: false) else {
            Issue.record("worktree not created: \(m.createError ?? "-")")
            throw CancellationError()
        }
        #expect(branch == name && wt == root + "/" + slug)
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt) == name)
        // `--no-track`: no upstream, so a push goes to the same-named branch, not to the base.
        #expect(throws: (any Error).self) { try t.git("rev-parse", "--abbrev-ref", name + "@{upstream}", in: wt) }

        var s = WorkspaceState()
        s.projects.append(project)
        let id = s.addTask(projectId: project.id, name: name, mode: .worktree(path: wt, branch: branch, base: "main"))
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        return (app, id, wt)
    }

    private func archiveAndRestore(_ t: TempRepo, _ app: AppState, _ id: UUID, _ wt: String) async throws {
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
        #expect(try await t.git("branch", "--list", name, in: t.repo) != "")
        #expect(await app.restoreFromArchive(id) == .restored)
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt) == name)
        #expect(app.state.tasks.first { $0.id == id }?.archived == false)
    }

    @Test func branchWithSlashAndCapitalsFullCycle() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let (app, id, wt) = try await flow(t, projectPath: t.repo)
        #expect(try await linkedWorktree(wt, mainFolder: t.repo, runner: .local) != nil)
        try await archiveAndRestore(t, app, id, wt)
    }

    /// A project in `apps/saas`: the guard takes the worktree's top level (not its `apps/saas`) and the repo of the subfolder.
    @Test func subfolderProjectComparesWorktreeTopLevel() async throws {
        let t = try await repo()
        defer { t.cleanup() }
        let saas = t.repo + "/apps/saas"
        let (app, id, wt) = try await flow(t, projectPath: saas)
        #expect(try await linkedWorktree(wt, mainFolder: saas, runner: .local) != nil)
        #expect(try await linkedWorktree(wt + "/apps/saas", mainFolder: saas, runner: .local) == nil)
        try await archiveAndRestore(t, app, id, wt)
    }
}
