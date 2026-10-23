import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace

@MainActor @Suite struct TaskDeletionTests {
    private final class Calls: @unchecked Sendable {
        var confirms: [String] = []
        var infos: [String] = []
        var errors: [(String, String)] = []
    }

    /// Archived worktree task "x" on branch x with a real worktree under `<repo>.worktrees/x`.
    private func make(answer: Bool = true) throws -> (TempRepo, AppState, UUID, String, Calls, ActionContext) {
        let t = try TempRepo()
        let wt = t.worktrees + "/x"
        try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
        try t.git("worktree", "add", "-q", "-b", "x", wt, "main", in: t.repo)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let id = s.addTask(projectId: p, name: "x", mode: .worktree(path: wt, branch: "x", base: "main"))
        s.archiveTask(id: id)
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        let calls = Calls()
        var ctx = ActionContext(app: app)
        ctx.confirm = { m, i, _, then in calls.confirms.append(m); calls.infos.append(i); if answer { then() } }
        ctx.showError = { calls.errors.append(($0, $1)) }
        return (t, app, id, wt, calls, ctx)
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    @Test func withoutCheckboxKeepsWorktreeAndBranch() async throws {
        let (t, app, id, wt, calls, ctx) = try make()
        defer { t.cleanup() }
        await deleteTaskPermanently(id, alsoWorktree: false, ctx: ctx, git: Git(repo: t.repo))
        #expect(!app.state.tasks.contains { $0.id == id })
        #expect(exists(wt))
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
        #expect(calls.confirms.isEmpty && calls.errors.isEmpty)
    }

    @Test func cleanWorktreeAndMergedBranchRemoved() async throws {
        let (t, app, id, wt, calls, ctx) = try make()
        defer { t.cleanup() }
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(!app.state.tasks.contains { $0.id == id })
        #expect(!exists(wt))
        #expect(try t.git("branch", "--list", "x", in: t.repo) == "")
        #expect(calls.confirms.isEmpty && calls.errors.isEmpty)
    }

    @Test func dirtyAsksThenForces() async throws {
        let (t, app, id, wt, calls, ctx) = try make(answer: true)
        defer { t.cleanup() }
        try "u".write(toFile: wt + "/untracked.txt", atomically: true, encoding: .utf8)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(calls.confirms == [L10n.worktreeDirty])
        // The forced removal runs in a Task started by the confirm callback.
        // Generous: under a full parallel run its git calls wait for busy spawns (5 s was seen to be too short).
        let clock = SuspendingClock(), end = clock.now + .seconds(60)
        while clock.now < end, app.state.tasks.contains(where: { $0.id == id }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!exists(wt) && !app.state.tasks.contains { $0.id == id })
    }

    @Test func dirtyDeclinedChangesNothing() async throws {
        let (t, app, id, wt, calls, ctx) = try make(answer: false)
        defer { t.cleanup() }
        try "u".write(toFile: wt + "/untracked.txt", atomically: true, encoding: .utf8)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(calls.confirms == [L10n.worktreeDirty])
        #expect(exists(wt) && app.state.tasks.contains { $0.id == id })
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
    }

    /// `.env`-style file: ignored, so `status --porcelain` is clean but `worktree remove` would delete it silently.
    private func addIgnored(_ t: TempRepo, _ wt: String) throws {
        try ".env\n".write(toFile: t.repo + "/.gitignore", atomically: true, encoding: .utf8)
        try t.git("add", ".gitignore", in: t.repo)
        try t.git("commit", "-q", "-m", "ignore", in: t.repo)
        try t.git("merge", "-q", "main", in: wt)
        try "secret".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
    }

    @Test func ignoredOnlyAsksThenForces() async throws {
        let (t, app, id, wt, calls, ctx) = try make(answer: true)
        defer { t.cleanup() }
        try addIgnored(t, wt)
        #expect(try await Git(repo: t.repo).isDirty(path: wt) == false)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains(".env") == true)
        // Generous: under a full parallel run its git calls wait for busy spawns (5 s was seen to be too short).
        let clock = SuspendingClock(), end = clock.now + .seconds(60)
        while clock.now < end, app.state.tasks.contains(where: { $0.id == id }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!exists(wt) && !app.state.tasks.contains { $0.id == id })
    }

    @Test func ignoredDeclinedChangesNothing() async throws {
        let (t, app, id, wt, calls, ctx) = try make(answer: false)
        defer { t.cleanup() }
        try addIgnored(t, wt)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(exists(wt + "/.env") && app.state.tasks.contains { $0.id == id })
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
    }

    @Test func unmergedBranchIsKept() async throws {
        let (t, app, id, wt, calls, ctx) = try make()
        defer { t.cleanup() }
        try t.commit(file: "b.txt", on: "x", in: wt)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(!app.state.tasks.contains { $0.id == id } && !exists(wt))
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
        #expect(calls.errors.map(\.0) == [L10n.branchKept("x")])
    }

    @Test func missingWorktreeFolderIsPruned() async throws {
        let (t, app, id, wt, calls, ctx) = try make()
        defer { t.cleanup() }
        try FileManager.default.removeItem(atPath: wt)
        await deleteTaskPermanently(id, alsoWorktree: true, ctx: ctx, git: Git(repo: t.repo))
        #expect(!app.state.tasks.contains { $0.id == id })
        #expect(!(try t.git("worktree", "list", in: t.repo)).contains("/x"))
        #expect(try t.git("branch", "--list", "x", in: t.repo) == "")
        #expect(calls.errors.isEmpty && calls.confirms.isEmpty)
    }

    @Test func archiveAndRemoveProjectKeepWorktree() throws {
        let (t, app, id, wt, _, _) = try make()
        defer { t.cleanup() }
        app.restore(taskId: id)
        app.archive(taskId: id)
        let project = app.state.projects[0].id
        app.perform { $0.removeProject(id: project) }
        #expect(exists(wt))
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
    }
}
