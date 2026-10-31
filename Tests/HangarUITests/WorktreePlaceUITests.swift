import Exec
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
        let agent = s.addTab(taskId: w, kind: .claude)
        if let i = s.tasks.firstIndex(where: { $0.id == w }), case .leaf(var leaf) = s.tasks[i].tabs.first(where: { $0.id == agent })!.root {
            leaf.agentSessionId = Self.session
            s.tasks[i].tabs[1].root = .leaf(leaf)
        }
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        return (t, app, w, old)
    }

    static let session = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"

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
        // The tab's claude conversation, recorded in the old folder (a temp claude config, never the real one).
        let config = URL(fileURLWithPath: t.root + "/claude")
        app.claudeSettingsURL = config.appendingPathComponent("settings.json")
        let recorded = config.appendingPathComponent("projects/" + claudeProjectFolder(old)!)
        try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
        try Data(#"{"type":"user","cwd":"\#(old)"}"#.utf8).write(to: recorded.appendingPathComponent(Self.session + ".jsonl"))
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
        // Nothing is copied at the click (claude may still be writing in the old folder): the tab only remembers where.
        var agent = task(app, w).tabs[1].root.leaves[0]
        #expect(agent.relinkedFrom == old)
        #expect(transcriptChoice(id: Self.session, cwd: real(new), configDir: config) == .foreign)
        // Its next launch copies the conversation as it is then (a turn said after the click included) and drops the mark.
        let file = recorded.appendingPathComponent(Self.session + ".jsonl")
        let later = try FileHandle(forWritingTo: file)
        try later.seekToEnd(); try later.write(contentsOf: Data("\n{\"type\":\"assistant\",\"cwd\":\"\(old)\"}".utf8)); try later.close()
        app.syncRelinkedTranscript(&agent)
        #expect(agent.relinkedFrom == nil && task(app, w).tabs[1].root.leaves[0].relinkedFrom == nil)
        #expect(transcriptChoice(id: Self.session, cwd: real(new), configDir: config) == .resume)
        let copy = config.appendingPathComponent("projects/" + claudeProjectFolder(real(new))! + "/" + Self.session + ".jsonl")
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("assistant"))
        #expect(FileManager.default.fileExists(atPath: file.path))  // the original stays
        #expect(task(app, w).mode == .worktree(path: real(new), branch: "feat/x", base: "main"))
        #expect(task(app, w).tabs[0].root.leaves[0].cwd == real(new))
        #expect(app.selectedWorktreeProblem == nil)
        await check(app, w)
        #expect(app.worktreePlaces[w] == .inPlace)
        #expect(app.head(of: task(app, w)) == .branch("feat/x"))
    }

    /// Asked again while a check runs: it runs once more after, not dropped.
    @Test func recheckDuringACheckRunsAgain() async throws {
        let (t, app, w, _) = try await make()
        defer { t.cleanup() }
        let p = task(app, w).projectId
        app.checkWorktrees(projectId: p)
        app.checkWorktrees(projectId: p)
        #expect(app.worktreeRechecks.contains(p))
        await app.worktreeChecksIdle()
        #expect(app.worktreeRechecks.isEmpty && app.worktreeChecks.isEmpty)
        #expect(app.worktreePlaces[w] == .inPlace)
    }

    /// A slow git: the sheet doesn't wait for it longer than the timeout.
    @Test func sheetProbeTimesOut() async {
        let start = ContinuousClock.now
        let slow: Int? = await answer(within: .milliseconds(50)) { try? await Task.sleep(for: .seconds(30)); return 1 }
        #expect(slow == nil && ContinuousClock.now - start < .seconds(10))
        let quick: Int? = await answer(within: .seconds(30)) { 2 }
        #expect(quick == 2)
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
