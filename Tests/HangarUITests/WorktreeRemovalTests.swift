import Exec
import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace
import TestSupport

/// Worktree removal never fails silently and is shown while it runs (#132): the removal rows' state machine and real-git
/// removals — a big folder, a missing one, a locked one, a process inside, a failure and its retry.
@MainActor @Suite struct WorktreeRemovalTests {
    /// Active worktree task "x" (branch x, a shell tab) under `<repo>.worktrees/x`.
    private func make() async throws -> (TempRepo, AppState, UUID, String) {
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
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        return (t, app, id, wt)
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    private func chmod(_ mode: Int, _ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
    private func registered(_ t: TempRepo) async throws -> Bool {
        try await t.git("worktree", "list", "--porcelain", in: t.repo).contains("/x\n")
    }

    // MARK: State machine

    @Test func rowShowsAfterTheDelayFailsAtOnceAndRetries() {
        var shows: [DispatchWorkItem] = []
        let r = WorktreeRemovals(delay: 1) { _, item in shows.append(item) }
        let quick = r.begin(name: "quick", path: "/w/quick", local: true)
        r.finish(quick)
        shows[0].perform()  // done before the delay: never shown
        #expect(r.items.isEmpty && r.visible.isEmpty)

        let slow = r.begin(name: "slow", path: "/w/slow", local: true)
        #expect(r.items.count == 1 && r.visible.isEmpty)
        shows[1].perform()
        #expect(r.visible.map(\.id) == [slow] && r.visible[0].failure == nil)
        r.moved(slow, to: "/w/slow.hangar-removing")
        #expect(r.items[0].path == "/w/slow.hangar-removing")
        r.dismiss(slow)  // «×» only on a failure
        #expect(r.items.count == 1)

        let failing = r.begin(name: "f", path: "/w/f", local: false)
        var retried = 0
        r.fail(failing, "Permission denied") { retried += 1 }
        #expect(r.visible.map(\.id) == [slow, failing] && r.visible[1].failure == "Permission denied")
        r.retry(failing)
        #expect(retried == 1 && r.items[1].failure == nil)
        r.retry(failing)  // the retry was used up: nothing runs twice
        #expect(retried == 1)
        r.fail(failing, "again") { retried += 1 }
        r.dismiss(failing)
        #expect(r.items.map(\.id) == [slow])
        r.finish(slow)
        #expect(r.items.isEmpty)
    }

    @Test func untilMovedWaitsForTheRename() async {
        let r = WorktreeRemovals(delay: 60) { _, _ in }
        await r.untilMoved("k")  // nothing moving: at once
        r.startMoving("k")
        #expect(r.isMoving("k"))
        var done = false
        let waiter = Task { await r.untilMoved("k"); done = true }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!done)
        r.doneMoving("k")
        await waiter.value
        #expect(done && !r.isMoving("k"))
    }

    // MARK: Real git

    /// 20 000 small files in an ignored `node_modules` (reinstallable, not at risk): the archive returns once the folder
    /// is moved aside; the row stays until the background delete is done.
    @Test func bigWorktreeGoesInTheBackgroundAndIsShownMeanwhile() async throws {
        let (t, app, id, wt) = try await make()
        defer { t.cleanup() }
        try "node_modules/\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try await t.git("add", ".gitignore", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        let fill = #"cd "$1" && for d in $(seq 1 200); do mkdir -p "node_modules/p$d" && (cd "node_modules/p$d" && touch $(seq -f 'f%g.js' 1 100)); done"#
        _ = try await Runner.local.run(["sh", "-c", fill, "sh", wt], "/")
        #expect(FileManager.default.subpaths(atPath: wt + "/node_modules")?.count ?? 0 >= 20_000)
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
        #expect(try await !registered(t))
        #expect(await waitUntil { app.worktreeRemovals.items.isEmpty && !exists(wt + ".hangar-removing") })
    }

    /// The folder was deleted by hand and the worktree is locked: archive still clears the registration (prune skips
    /// locked ones), so restore can check the branch out again.
    @Test func missingLockedWorktreeArchivesAndRestores() async throws {
        let (t, app, id, wt) = try await make()
        defer { t.cleanup() }
        _ = try await t.git("worktree", "lock", wt, in: t.repo)
        try FileManager.default.removeItem(atPath: wt)
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
        #expect(try await !registered(t))
        #expect(app.worktreeRemovals.items.isEmpty)
        #expect(await app.restoreFromArchive(id) == .restored)
        #expect(exists(wt + "/a.txt"))
    }

    /// A locked worktree: unlocked before the rename, so no stale registration blocks restore or `branch -d`.
    @Test func lockedWorktreeIsRemovedAndRestores() async throws {
        let (t, app, id, wt) = try await make()
        defer { t.cleanup() }
        _ = try await t.git("worktree", "lock", "--reason", "agent", wt, in: t.repo)
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
        #expect(try await !registered(t))
        #expect(await app.restoreFromArchive(id) == .restored)
        #expect(exists(wt + "/a.txt"))
    }

    /// Someone else's process working in the folder is seen, waited for (bounded), never killed; the folder still goes.
    @Test func processInTheFolderIsWaitedForNotKilled() async throws {
        let (t, app, id, wt) = try await make()
        defer { t.cleanup() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        p.currentDirectoryURL = URL(fileURLWithPath: wt)
        try p.run()
        defer { p.terminate() }
        #expect(await waitUntil { await processesWorking(in: wt).contains(p.processIdentifier) })
        let clock = ContinuousClock(), start = clock.now
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
        #expect(clock.now - start >= .seconds(2.5))
        #expect(!exists(wt) && p.isRunning)
        #expect(await processesWorking(in: t.root + "/nope").isEmpty)
    }

    /// The rename aside fails (the worktrees folder is read-only): archived, the folder stays, the row shows the reason
    /// at once; «Повторить» once the folder is writable removes it.
    @Test func failedRemovalShowsAndRetries() async throws {
        let (t, app, id, wt) = try await make()
        defer { try? chmod(0o755, t.worktrees); t.cleanup() }
        try chmod(0o555, t.worktrees)
        guard case .worktreeKept = await app.archiveRemovingWorktree(id, force: false) else { Issue.record("not kept"); return }
        #expect(exists(wt + "/a.txt"))
        let item = try #require(app.worktreeRemovals.visible.first)
        #expect(item.failure != nil && item.name == "x" && item.local)
        try chmod(0o755, t.worktrees)
        app.worktreeRemovals.retry(item.id)
        #expect(await waitUntil { app.worktreeRemovals.items.isEmpty && !exists(wt) && !exists(wt + ".hangar-removing") })
        #expect(try await !registered(t))
    }

    /// New changes since the archive's check: «Повторить» checks again and keeps the folder (the row says why).
    @Test func retryAfterNewChangesKeepsTheFolder() async throws {
        let (t, app, id, wt) = try await make()
        defer { try? chmod(0o755, t.worktrees); t.cleanup() }
        try chmod(0o555, t.worktrees)
        _ = await app.archiveRemovingWorktree(id, force: false)
        let item = try #require(app.worktreeRemovals.items.first)
        try "new".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        try chmod(0o755, t.worktrees)
        app.worktreeRemovals.retry(item.id)
        #expect(await waitUntil { app.worktreeRemovals.items.first?.failure == L10n.removeCopyChanged })
        #expect(exists(wt + "/new.txt"))
    }

    /// The background delete fails (its parent is read-only): the row shows it; «Повторить» deletes it.
    @Test func failedBackgroundDeleteShowsAndRetries() async throws {
        let (t, app, _, _) = try await make()
        let ro = t.root + "/ro", tomb = ro + "/y.hangar-removing"
        defer { try? chmod(0o755, ro); t.cleanup() }
        try FileManager.default.createDirectory(atPath: tomb + "/deep", withIntermediateDirectories: true)
        try chmod(0o555, ro)
        let item = app.worktreeRemovals.begin(name: "y", path: tomb, local: true)
        await app.deleteTombstoneTracked(tomb, item: item, runner: .local)
        #expect(app.worktreeRemovals.visible.first?.failure != nil && exists(tomb))
        try chmod(0o755, ro)
        app.worktreeRemovals.retry(item)
        #expect(await waitUntil { app.worktreeRemovals.items.isEmpty && !exists(tomb) })
    }

    /// Read-only folders inside (Go's module cache) don't stop the delete; only tombstones are ever deleted.
    @Test func readOnlyFoldersAreDeleted() async throws {
        let (t, _, _, _) = try await make()
        defer { t.cleanup() }
        let tomb = t.root + "/z.hangar-removing", locked = tomb + "/pkg/mod"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try "x".write(toFile: locked + "/f.go", atomically: true, encoding: .utf8)
        try chmod(0o444, locked + "/f.go")
        try chmod(0o555, locked)
        try await deleteTombstone(tomb, runner: .local)
        #expect(!exists(tomb))
        try await deleteTombstone(tomb, runner: .local)  // gone already: fine
        await #expect(throws: (any Error).self) { try await deleteTombstone(t.repo, runner: .local) }
        #expect(exists(t.repo + "/a.txt"))
    }
}
