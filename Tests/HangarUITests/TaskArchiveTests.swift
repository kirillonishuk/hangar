import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace

/// Archive removes a worktree task's folder (branch kept, data-loss checks as delete); restore/undo re-creates it.
@MainActor @Suite struct TaskArchiveTests {
    private final class Calls: @unchecked Sendable {
        var confirms: [String] = []
        var infos: [String] = []
        var errors: [(String, String)] = []
        var archived: [UUID] = []
    }

    /// Active worktree task "x" (branch x, a shell tab) under `<repo>.worktrees/x`, plus main-folder task "m".
    private func make(answer: Bool = true) async throws -> (TempRepo, AppState, UUID, UUID, String, Calls, ActionContext) {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
            _ = try t.git("worktree", "add", "-q", "-b", "x", t.worktrees + "/x", "main", in: t.repo)
            return t
        }
        let wt = t.worktrees + "/x"
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let id = s.addTask(projectId: p, name: "x", mode: .worktree(path: wt, branch: "x", base: "main"))
        _ = s.addTab(taskId: id, kind: .shell)
        let main = s.addTask(projectId: p, name: "m")
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        let calls = Calls()
        var ctx = ActionContext(app: app)
        ctx.confirm = { m, i, _, then in calls.confirms.append(m); calls.infos.append(i); if answer { then() } }
        ctx.showError = { calls.errors.append(($0, $1)) }
        ctx.didArchive = { calls.archived.append($0) }
        return (t, app, id, main, wt, calls, ctx)
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    private func archived(_ app: AppState, _ id: UUID) -> Bool { app.state.tasks.first { $0.id == id }?.archived == true }

    private func waitUntil(_ cond: () -> Bool) async -> Bool {
        // Generous: under a full parallel run git calls wait for busy spawns.
        let clock = SuspendingClock(), end = clock.now + .seconds(60)
        while clock.now < end, !cond() { try? await Task.sleep(for: .milliseconds(50)) }
        return cond()
    }

    @Test func cleanWorktreeIsRemovedBranchKept() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        #expect(archived(app, id))
        #expect(!exists(wt))
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
        #expect(calls.archived == [id] && calls.confirms.isEmpty && calls.errors.isEmpty)
    }

    @Test func mainFolderTaskJustArchives() async throws {
        let (t, app, _, main, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        await archiveTask(main, ctx: ctx)
        #expect(archived(app, main))
        #expect(exists(wt) && exists(t.repo + "/a.txt"))
        #expect(calls.archived == [main] && calls.confirms.isEmpty)
    }

    @Test func dirtyDeclinedChangesNothing() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try "u".write(toFile: wt + "/untracked.txt", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeDirty])
        #expect(!archived(app, id) && exists(wt + "/untracked.txt"))
        #expect(calls.archived.isEmpty)
    }

    @Test func ignoredAsksThenForces() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: true)
        defer { t.cleanup() }
        try ".env\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try t.git("add", ".gitignore", in: wt)
        _ = try t.git("commit", "-q", "-m", "ignore", in: wt)
        try "secret".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains(".env") == true)
        #expect(await waitUntil { archived(app, id) && !exists(wt) && !calls.archived.isEmpty })
        #expect(calls.archived == [id])
        #expect(try t.git("branch", "--list", "x", in: t.repo) != "")
    }

    @Test func restoreRecreatesWorktreeFromBranch() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        try t.commit(file: "work.txt", on: "x", in: wt)
        await archiveTask(id, ctx: ctx)
        #expect(!exists(wt))
        await restoreArchivedTask(id, ctx: ctx, reselect: true)
        #expect(!archived(app, id))
        #expect(exists(wt + "/work.txt"))
        #expect(try t.git("symbolic-ref", "--short", "HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines) == "x")
        #expect(app.state.selectedTaskId == id)
        #expect(calls.errors.isEmpty)
    }

    /// A task archived before this change kept its folder: restore just unarchives.
    @Test func restoreWithFolderPresentJustUnarchives() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        app.archive(taskId: id)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(!archived(app, id) && exists(wt))
        #expect(calls.errors.isEmpty && calls.confirms.isEmpty)
    }

    @Test func branchGoneOffersMainFolder() async throws {
        let (t, app, id, _, _, calls, ctx) = try await make(answer: true)
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        _ = try t.git("branch", "-D", "x", in: t.repo)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.branchGone("x")])
        #expect(await waitUntil { !archived(app, id) })
        let task = try #require(app.state.tasks.first { $0.id == id })
        #expect(task.mode == .mainFolder)
        #expect(task.tabs.flatMap(\.root.leaves).allSatisfy { $0.cwd == t.repo })
    }

    @Test func branchGoneDeclinedStaysArchived() async throws {
        let (t, app, id, _, _, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        _ = try t.git("branch", "-D", "x", in: t.repo)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.branchGone("x")])
        #expect(archived(app, id))
    }

    /// The undo toast hands the id to `onUndo` (the window restores through `restoreArchivedTask`).
    @Test func undoToastCallsOnUndo() {
        let undo = ArchiveUndo(delay: 60)
        var restored: [UUID] = []
        undo.onUndo = { restored.append($0) }
        let id = UUID()
        undo.show(id)
        undo.undo(undo.onUndo)
        #expect(restored == [id])
    }
}
