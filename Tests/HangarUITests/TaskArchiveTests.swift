import Exec
import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace
import TestSupport

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

    @Test func cleanWorktreeIsRemovedBranchKept() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        #expect(archived(app, id))
        #expect(!exists(wt))
        #expect(try await t.git("branch", "--list", "x", in: t.repo) != "")
        #expect(calls.archived == [id] && calls.confirms.isEmpty && calls.errors.isEmpty)
    }

    @Test func archiveKeepsTimeAndChangesForSessions() async throws {
        let (t, app, id, _, wt, _, ctx) = try await make()
        defer { t.cleanup() }
        try "one\ntwo\n".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        _ = try await t.git("add", "new.txt", in: wt)
        _ = try await t.git("commit", "-q", "-m", "new", in: wt)
        let before = Date()
        await archiveTask(id, ctx: ctx)
        let task = try #require(app.state.tasks.first { $0.id == id })
        #expect(task.archived && !exists(wt))
        #expect(task.archivedChanges == LineChanges(added: 2, deleted: 0))
        #expect((task.archivedAt ?? .distantPast) >= before.addingTimeInterval(-1))
    }

    /// The +N −M measure is awaited before the folder goes: a restore meanwhile (the «Сессии» view lists the session
    /// as closed already) must keep the folder of the session that is open again.
    @Test func restoreDuringTheChangesMeasureKeepsTheFolder() async throws {
        let (t, app, id, _, wt, _, ctx) = try await make()
        defer { t.cleanup() }
        // git asks the fsmonitor hook before the diff: it marks the moment and holds that call until released (a fixed
        // hold lost the race when the main actor stalled for longer); bounded at 120 s so a failed test never hangs.
        let marker = t.root + "/measuring", release = t.root + "/release", hook = t.root + "/fsmonitor.sh"
        defer { FileManager.default.createFile(atPath: release, contents: nil) }
        try writeScript("""
        #!/bin/sh
        case "$(ps -o args= -p $PPID)" in *--numstat*)
          touch "${0%/*}/measuring"; n=0
          while [ ! -e "${0%/*}/release" ] && [ $n -lt 1200 ]; do sleep 0.1; n=$((n+1)); done ;;
        esac
        exit 1
        """, to: hook)
        _ = try await t.git("config", "core.fsmonitor", hook, in: wt)
        let archiving = Task { await archiveTask(id, ctx: ctx) }
        #expect(await waitUntil { exists(marker) })
        #expect(await app.restoreFromArchive(id) == .restored)
        FileManager.default.createFile(atPath: release, contents: nil)
        await archiving.value
        #expect(!archived(app, id))
        #expect(exists(wt))
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
        _ = try await t.git("add", ".gitignore", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        try "secret".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains(".env") == true)
        #expect(await waitUntil { archived(app, id) && !exists(wt) && !calls.archived.isEmpty })
        #expect(calls.archived == [id])
        #expect(try await t.git("branch", "--list", "x", in: t.repo) != "")
    }

    /// Ignores `.env`, `node_modules`, `*.db` on branch x; the main folder has `.env` (`SECRET=1`).
    private func ignoreSetup(_ t: TempRepo, _ wt: String) async throws {
        try ".env\nnode_modules/\n*.db\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try await t.git("add", ".gitignore", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        try "SECRET=1".write(toFile: t.repo + "/.env", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: wt + "/node_modules/pkg", withIntermediateDirectories: true)
        try "x".write(toFile: wt + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
    }

    /// A fresh worktree holding only what setup copied (`.env` as in the main folder) and reinstallable `node_modules`.
    @Test func copiesAndReinstallablesArchiveWithoutConfirm() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try await ignoreSetup(t, wt)
        try "SECRET=1".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms.isEmpty && calls.errors.isEmpty)
        #expect(archived(app, id) && !exists(wt))
    }

    /// A new local DB and a changed `.env` would be lost: asked, the new one listed first. Declined: the task stays
    /// unarchived and its tabs (stopped before the check) relaunch lazily, as after a restart.
    @Test func realLossAsksUniqueFirstAndDeclineRelaunchesLazily() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try await ignoreSetup(t, wt)
        try "CHANGED=1".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        try "db".write(toFile: wt + "/dev.db", atomically: true, encoding: .utf8)
        let leaf = try #require(app.state.tasks.first { $0.id == id }?.tabs.first?.root.leaves.first)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains("dev.db, .env") == true)
        #expect(calls.infos.first?.contains("node_modules") == false)
        #expect(!archived(app, id) && exists(wt + "/dev.db"))
        #expect(app.launchContext(for: leaf.id) == .restored(inResumeSet: true))
    }

    @Test func restoreRecreatesWorktreeFromBranch() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        try await t.commit(file: "work.txt", on: "x", in: wt)
        await archiveTask(id, ctx: ctx)
        #expect(!exists(wt))
        await restoreArchivedTask(id, ctx: ctx, reselect: true)
        #expect(!archived(app, id))
        #expect(exists(wt + "/work.txt"))
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines) == "x")
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
        var claude = UUID()
        app.perform { s in
            _ = s.addTab(taskId: id, kind: .claude)
            claude = s.tasks.first { $0.id == id }!.tabs.last!.root.leaves[0].id
            s.setAgentSessionId(leafId: claude, "0b6c4a52-7c1e-4c1a-9a55-3f1a2b3c4d5e")
        }
        await archiveTask(id, ctx: ctx)
        _ = try await t.git("branch", "-D", "x", in: t.repo)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.branchGone("x")])
        #expect(await waitUntil { !archived(app, id) })
        let task = try #require(app.state.tasks.first { $0.id == id })
        #expect(task.mode == .mainFolder)
        #expect(task.tabs.flatMap(\.root.leaves).allSatisfy { $0.cwd == t.repo })
        // Detached leaves start fresh: no `--resume <id>` / `--continue` into another task's conversation.
        #expect(task.tabs.flatMap(\.root.leaves).allSatisfy { $0.agentSessionId == nil })
        #expect(app.launchContext(for: claude) == .created(prompt: nil))
    }

    @Test func branchGoneDeclinedStaysArchived() async throws {
        let (t, app, id, _, _, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        _ = try await t.git("branch", "-D", "x", in: t.repo)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.branchGone("x")])
        #expect(archived(app, id))
    }

    /// Crash-safe archive (#59): the folder leaves its place in one rename, so a quit mid-removal
    /// leaves only `<path>.hangar-removing`, never a half folder at `<path>`.
    @Test func archiveRenamesToTombstoneFirst() async throws {
        let (t, app, id, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        let outcome = await app.archiveRemovingWorktree(id, force: false)
        #expect(outcome == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
        #expect(try await t.git("worktree", "list", in: t.repo).contains("/x\n") == false)
        #expect(await waitUntil { !exists(wt + ".hangar-removing") })
    }

    /// #105: Hangar's status line override in the worktree is taken out first, so it does not make the archive «at risk».
    @Test func archiveTakesStatuslineOverrideOut() async throws {
        let (t, app, id, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        try FileManager.default.createDirectory(atPath: wt + "/.claude", withIntermediateDirectories: true)
        try #"{"statusLine": {"type": "command", "command": "project-line"}}"#.write(toFile: wt + "/.claude/settings.json", atomically: true, encoding: .utf8)
        _ = try await TempRepo.offMain { try t.git("add", ".claude/settings.json", in: wt); try t.git("commit", "-qm", "line", in: wt); return t }
        let claude = t.root + "/claude.json"
        try #"{"statusLine": {"type": "command", "command": "/opt/hangar statusline"}}"#.write(toFile: claude, atomically: true, encoding: .utf8)
        app.claudeSettingsURL = URL(fileURLWithPath: claude)
        app.findAgentDirs = nil
        app.statuslineSync = true
        await app.syncProjectStatuslines(host: nil)
        #expect(exists(wt + "/.claude/settings.local.json"))
        #expect(await app.archiveRemovingWorktree(id, force: false) == .archived(worktreeRemoved: true))
    }

    /// Simulated quit before the background delete: the startup sweep removes the tombstone next to a known worktree
    /// root, and only there.
    @Test func startupSweepRemovesOnlyKnownTombstones() async throws {
        let (t, app, _, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        let fm = FileManager.default
        let leftover = t.worktrees + "/old.hangar-removing", stranger = t.root + "/other/y.hangar-removing"
        for d in [leftover + "/half", stranger] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        await app.sweepTombstones(host: nil)
        #expect(!exists(leftover))
        #expect(exists(stranger) && exists(wt + "/a.txt"))
    }

    /// An older build quit mid `worktree remove`: a partial folder without `.git` sits at the path. Restore keeps it
    /// aside as `<path>.hangar-orphan-<time>` (never deleted, the user is told) and re-creates the worktree.
    @Test func restoreRecreatesCorruptPartialFolder() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        try await t.commit(file: "work.txt", on: "x", in: wt)
        await archiveTask(id, ctx: ctx)
        try FileManager.default.createDirectory(atPath: wt + "/src", withIntermediateDirectories: true)
        try "half".write(toFile: wt + "/src/left.txt", atomically: true, encoding: .utf8)
        await restoreArchivedTask(id, ctx: ctx)
        #expect(calls.errors.map(\.0) == [L10n.orphanKept])
        let orphan = try #require(calls.errors.first?.1)
        #expect(orphan.hasPrefix(wt + ".hangar-orphan-") && exists(orphan + "/src/left.txt"))
        #expect(!archived(app, id))
        #expect(exists(wt + "/.git") && exists(wt + "/work.txt") && !exists(wt + "/src/left.txt"))
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines) == "x")
    }

    /// `.git` is there but git rejects the folder and `worktree repair` can't fix it: nothing is deleted.
    @Test func restoreLeavesBrokenFolderWithGitInPlace() async throws {
        let (t, app, id, _, wt, _, ctx) = try await make()
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "junk".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        try "mine".write(toFile: wt + "/notes.txt", atomically: true, encoding: .utf8)
        let outcome = await app.restoreFromArchive(id)
        #expect(outcome == .failed("\(wt) is not a valid worktree, left in place"))
        #expect(archived(app, id))
        #expect(exists(wt + "/notes.txt") && exists(wt + "/.git"))
    }

    /// A broken `.git` link is fixed by `git worktree repair`; the folder and its files stay.
    @Test func restoreRepairsBrokenGitLink() async throws {
        let (t, app, id, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        app.archive(taskId: id)
        try "mine".write(toFile: wt + "/notes.txt", atomically: true, encoding: .utf8)
        try "gitdir: /bogus/worktrees/x".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        #expect(await app.restoreFromArchive(id) == .restored)
        #expect(!archived(app, id) && exists(wt + "/notes.txt"))
        #expect(try await t.git("rev-parse", "--is-inside-work-tree", in: wt) == "true")
    }

    /// Same rules over ssh: a broken folder with `.git` stays, one without is kept aside.
    @Test func remoteRestoreKeepsBrokenFolder() async throws {
        let (t, app, id, _, wt, _, ctx) = try await make()
        defer { t.cleanup() }
        await archiveTask(id, ctx: ctx)
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let runner = Runner.ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path)
        let git = Git(repo: t.repo, runner: runner)
        try FileManager.default.createDirectory(atPath: wt + "/src", withIntermediateDirectories: true)
        try "junk".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        #expect(try await reviveWorktree(wt, branch: "x", git: git, runner: runner) == .failed("\(wt) is not a valid worktree, left in place"))
        #expect(exists(wt + "/.git") && exists(wt + "/src"))
        try FileManager.default.removeItem(atPath: wt + "/.git")
        let outcome = try await reviveWorktree(wt, branch: "x", git: git, runner: runner)
        guard case .restoredKeeping(let orphan) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt) == "x")
        #expect(!exists(wt + "/src") && exists(orphan + "/src"))
        _ = app
    }

    /// A task whose "worktree" is the project's main checkout never gets its folder moved.
    @Test func archiveRefusesMainCheckout() async throws {
        let (t, app, _, _, _, _, _) = try await make()
        defer { t.cleanup() }
        let pid = app.state.projects[0].id
        var bad = UUID()
        app.perform { bad = $0.addTask(projectId: pid, name: "bad", mode: .worktree(path: t.repo, branch: "main", base: "main")) }
        let outcome = await app.archiveRemovingWorktree(bad, force: true)
        guard case .worktreeKept = outcome else { Issue.record("\(outcome)"); return }
        #expect(exists(t.repo + "/a.txt") && exists(t.repo + "/.git"))
        #expect(!exists(t.repo + ".hangar-removing"))
    }

    /// Over ssh: the main folder and a plain repo are refused, a linked worktree goes.
    @Test func remoteRemovalOnlyForLinkedWorktrees() async throws {
        let (t, _, _, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let runner = Runner.ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path)
        let git = Git(repo: t.repo, runner: runner)
        await #expect(throws: (any Error).self) { try await removeWorktreeFolder(t.repo, git: git, runner: runner) }
        #expect(exists(t.repo + "/a.txt") && !exists(t.repo + ".hangar-removing"))
        let plain = t.root + "/plain"
        _ = try await t.git("init", "-q", plain, in: t.root)
        await #expect(throws: (any Error).self) { try await removeWorktreeFolder(plain, git: git, runner: runner) }
        #expect(exists(plain + "/.git"))
        try await removeWorktreeFolder(wt, git: git, runner: runner).value
        #expect(!exists(wt))
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
