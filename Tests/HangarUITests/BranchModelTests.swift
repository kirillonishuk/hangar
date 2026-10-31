import AppKit
import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace

/// Live HEAD per chat and the switcher's actions (#114) on a real repo: main-folder chats A and C, worktree chat W on `x`.
@MainActor @Suite struct BranchModelTests {
    private func make() async throws -> (TempRepo, AppState, a: UUID, c: UUID, w: UUID, wt: String) {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
            try t.git("worktree", "add", "-q", "-b", "x", t.worktrees + "/x", "main", in: t.repo)
            return t
        }
        let wt = t.worktrees + "/x"
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let a = s.addTask(projectId: p, name: "a-chat")
        let c = s.addTask(projectId: p, name: "c-chat")
        let w = s.addTask(projectId: p, name: "wt-chat", mode: .worktree(path: wt, branch: "x", base: "main"))
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        return (t, app, a, c, w, wt)
    }

    private func task(_ app: AppState, _ id: UUID) -> HangarTask { app.state.tasks.first { $0.id == id }! }

    private func load(_ app: AppState, _ ids: UUID...) async {
        for id in ids {
            app.requestHead(task(app, id))
            await app.worktreeChecksIdle()
            await app.branchModel.idle()
        }
    }

    @Test func headsFollowSwitchCreateAndDetach() async throws {
        let (t, app, a, c, w, wt) = try await make()
        defer { t.cleanup() }
        await load(app, a, c, w)
        #expect(app.head(of: task(app, a)) == .branch("main"))
        #expect(app.head(of: task(app, w)) == .branch("x"))

        // Taken by the worktree chat: refused with its name, nothing moves.
        let taken = await app.switchBranch(of: task(app, a), to: Branch(name: "x", isRemote: false, lastCommit: .now))
        #expect(taken?.contains("wt-chat") == true)

        // Uncommitted changes: switching refuses, a new branch at HEAD takes them along.
        try "x".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        try await t.git("branch", "other", in: t.repo)
        let dirty = await app.switchBranch(of: task(app, a), to: Branch(name: "other", isRemote: false, lastCommit: .now))
        #expect(dirty == app.branchMessage(.dirty(files: 1), projectId: task(app, a).projectId))
        #expect(await app.createBranch(of: task(app, a), name: "a b") == L10n.branchInvalid)
        #expect(await app.createBranch(of: task(app, a), name: "feat/new") == nil)
        await app.branchModel.idle()
        await app.branchModel.idle()
        // Chat C shares the folder: it follows.
        #expect(app.head(of: task(app, a)) == .branch("feat/new"))
        #expect(app.head(of: task(app, c)) == .branch("feat/new"))

        let choices = try await app.branchChoices(of: task(app, a))
        #expect(choices.head == .branch("feat/new"))
        #expect(choices.uncommitted == 1)
        #expect(choices.elsewhere == ["x": "wt-chat"])
        #expect(Set(choices.local.map(\.name)) == ["main", "x", "other", "feat/new"])
        #expect(choices.remote.map(\.name) == ["origin/main"])

        // The agent or a terminal detaches the worktree: the next refresh shows the short hash.
        let short = try await t.git("rev-parse", "--short", "HEAD", in: wt)
        try await t.git("checkout", "-q", "--detach", in: wt)
        app.refreshHead(taskId: w)
        await app.branchModel.idle()
        #expect(app.head(of: task(app, w)) == .detached(short))
    }

    /// Inspector hidden or shown, a `git switch` in a terminal reaches the selected chat's branch: hidden through the
    /// `HEAD` file stream, shown through the inspector's own stream (no second one).
    @Test(arguments: [false, true]) func selectedChatFollowsTerminalSwitch(inspector: Bool) async throws {
        let (t, app, a, _, _, _) = try await make()
        defer { t.cleanup() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let watch = InspectorWatch(app: app, window: window)
        watch.windowVisible = { true }
        app.perform { $0.inspectorVisible = inspector }
        app.select(taskId: a)
        watch.update()
        await app.branchModel.idle()
        #expect(app.head(of: task(app, a)) == .branch("main"))
        try await Task.sleep(nanoseconds: 500_000_000)  // the git-dir lookup and the stream start
        #expect((watch.watcher != nil) == inspector)
        #expect((watch.headWatcher != nil) == !inspector)
        try await t.git("switch", "-q", "-c", "from-terminal", in: t.repo)
        for _ in 0..<50 where app.head(of: task(app, a)) != .branch("from-terminal") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(app.head(of: task(app, a)) == .branch("from-terminal"))
    }

    @Test func safetyRefusalsAreMessages() async throws {
        let (t, app, a, _, _, _) = try await make()
        defer { t.cleanup() }
        try await t.git("bisect", "start", in: t.repo)
        let msg = await app.switchBranch(of: task(app, a), to: Branch(name: "other", isRemote: false, lastCommit: .now))
        #expect(msg == L10n.branchOperationInProgress("bisect"))
        let files = app.branchMessage(.wouldOverwriteIgnored([".env", "a", "b", "c"]), projectId: task(app, a).projectId)
        #expect(files.contains(".env, a, b, …"))
    }
}
