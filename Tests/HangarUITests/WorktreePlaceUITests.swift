import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace

/// A worktree chat whose copy was moved out of the main checkout (`git worktree move`) or deleted (#122).
@MainActor @Suite struct WorktreePlaceUITests {
    private func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// Main repo on `main`, chat W on `feat/x` in `<repo>/.claude/worktrees/feat-x`.
    private func make() async throws -> (TempRepo, AppState, w: UUID, old: String) {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try t.git("worktree", "add", "-q", "-b", "feat/x", t.repo + "/.claude/worktrees/feat-x", "main", in: t.repo)
            return t
        }
        let old = t.repo + "/.claude/worktrees/feat-x"
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let w = s.addTask(projectId: p, name: "w", mode: .worktree(path: old, branch: "feat/x", base: "main"))
        s.addTab(taskId: w, kind: .shell)
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        return (t, app, w, old)
    }

    private func task(_ app: AppState, _ id: UUID) -> HangarTask { app.state.tasks.first { $0.id == id }! }

    private func check(_ app: AppState, _ w: UUID) async {
        app.recheckWorktree(of: w)
        await app.worktreeChecksIdle()
        app.refreshHead(taskId: w)
        await app.branchModel.idle()
    }

    @Test func movedCopyIsNotTheMainCheckoutAndRelinks() async throws {
        let (t, app, w, old) = try await make()
        defer { t.cleanup() }
        app.perform { $0.select(taskId: w) }
        // Unchecked: no folder for git yet (never the main checkout by accident).
        #expect(app.gitFolder(of: w) == nil)
        await app.worktreeChecksIdle()
        #expect(app.gitFolder(of: w) == old)
        _ = app.branchModel.request(w)
        await check(app, w)
        #expect(app.head(of: task(app, w)) == .branch("feat/x"))

        let new = t.worktrees + "/feat-x"
        try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
        try await t.git("worktree", "move", old, new, in: t.repo)
        try FileManager.default.createDirectory(atPath: old + "/.claude", withIntermediateDirectories: true)
        await check(app, w)
        #expect(app.worktreePlaces[w] == .moved(to: real(new)))
        #expect(app.gitFolder(of: w) == nil)
        // The old folder answers as the main checkout: its `main` is not shown as the chat's branch.
        #expect(app.head(of: task(app, w)) == nil)
        #expect(app.selectedWorktreeProblem?.place == .moved(to: real(new)))
        #expect(app.inspectorNotice == L10n.inspectorWorktreeMoved)
        await #expect(throws: (any Error).self) { try await app.branchChoices(of: task(app, w)) }

        app.relinkWorktree(w)
        #expect(task(app, w).mode == .worktree(path: real(new), branch: "feat/x", base: "main"))
        #expect(task(app, w).tabs[0].root.leaves[0].cwd == real(new))
        #expect(app.selectedWorktreeProblem == nil)
        await check(app, w)
        #expect(app.worktreePlaces[w] == .inPlace)
        #expect(app.head(of: task(app, w)) == .branch("feat/x"))
    }

    @Test func deletedCopyIsMissing() async throws {
        let (t, app, w, old) = try await make()
        defer { t.cleanup() }
        try FileManager.default.removeItem(atPath: old)
        await check(app, w)
        #expect(app.worktreePlaces[w] == .missing)
        #expect(app.gitFolder(of: w) == nil)
        app.perform { $0.select(taskId: w) }
        #expect(app.inspectorNotice == L10n.inspectorWorktreeMissing)
        // Nothing to relink to: the path stays.
        app.relinkWorktree(w)
        #expect(task(app, w).mode == .worktree(path: old, branch: "feat/x", base: "main"))
    }
}
