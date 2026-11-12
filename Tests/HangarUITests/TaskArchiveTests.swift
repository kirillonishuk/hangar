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

    /// «В архив всё равно» agreed to lose `.env` only: a tracked edit made while the dialog was open asks again (HD-154).
    @Test func forcedArchiveAsksAgainAboutNewWork() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try ".env\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try await t.git("add", ".gitignore", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        try "secret".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        let shown = WorktreeCheck.atRisk(dirty: false, ignored: [".env"])
        try "edit".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        try "db".write(toFile: wt + "/new.env", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx, shown: shown)
        #expect(calls.confirms == [L10n.worktreeDirty])
        #expect(!archived(app, id) && exists(wt + "/a.txt"))
        // What was shown is still all there is: it goes.
        _ = try await t.git("checkout", "--", "a.txt", in: wt)
        try FileManager.default.removeItem(atPath: wt + "/new.env")
        #expect(await app.archiveRemovingWorktree(id, force: true, shown: shown) == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
    }

    /// The dialog said «uncommitted changes»: a further edit of that file or a new file meanwhile is not covered (HD-154).
    @Test func forcedArchiveAsksAgainAboutFurtherEdits() async throws {
        let (t, app, id, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        try "mine".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        let shown = try await checkWorktree(wt, git: Git(repo: t.repo), runner: .local)
        try "agent".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        guard case .atRisk(true, _, _) = await app.archiveRemovingWorktree(id, force: true, shown: shown) else { Issue.record("not asked"); return }
        try "mine".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        try "n".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        guard case .atRisk = await app.archiveRemovingWorktree(id, force: true, shown: shown) else { Issue.record("not asked"); return }
        try FileManager.default.removeItem(atPath: wt + "/new.txt")
        #expect(await app.archiveRemovingWorktree(id, force: true, shown: shown) == .archived(worktreeRemoved: true))
        #expect(!exists(wt))
    }

    @Test func coveredRisk() {
        let shown = WorktreeCheck.atRisk(dirty: false, ignored: [".env", "dev.db"])
        #expect(WorktreeCheck.clean.isCovered(by: nil))
        #expect(!shown.isCovered(by: nil))
        #expect(WorktreeCheck.atRisk(dirty: false, ignored: ["dev.db"]).isCovered(by: shown))
        #expect(!WorktreeCheck.atRisk(dirty: true, ignored: [".env"]).isCovered(by: shown))
        #expect(!WorktreeCheck.atRisk(dirty: false, ignored: [".env", "x.log"]).isCovered(by: shown))
        #expect(WorktreeCheck.atRisk(dirty: true, ignored: []).isCovered(by: .atRisk(dirty: true, ignored: [])))
        let edited = WorktreeCheck.atRisk(dirty: true, ignored: [], changes: ["a.txt": " M 1", "b.txt": "?? 2"])
        #expect(WorktreeCheck.atRisk(dirty: true, ignored: [], changes: ["a.txt": " M 1"]).isCovered(by: edited))
        #expect(!WorktreeCheck.atRisk(dirty: true, ignored: [], changes: ["a.txt": " M 3"]).isCovered(by: edited))
        #expect(!WorktreeCheck.atRisk(dirty: true, ignored: [], changes: ["c.txt": "?? 4"]).isCovered(by: edited))
    }

    /// Double ⌘⇧W (or CLI with the UI): the second archive during the first one's check refuses, the folder goes once.
    @Test func concurrentArchiveRefuses() async throws {
        let (t, app, id, _, wt, _, _) = try await make()
        defer { t.cleanup() }
        async let first = app.archiveRemovingWorktree(id, force: false)
        async let second = app.archiveRemovingWorktree(id, force: false)
        let outcomes = await [first, second]
        #expect(outcomes.contains(.archived(worktreeRemoved: true)))
        #expect(outcomes.contains(.inProgress))
        #expect(!exists(wt))
    }

    /// A sub-chat in its parent's worktree (HD-131): `x` and the sub-chat share `wt`.
    private func shared(_ app: AppState, parent: UUID) throws -> UUID {
        var sub: UUID?
        app.perform { sub = $0.addSubSession(parent: parent, name: "sub", kind: .shell)?.task }
        return try #require(sub)
    }

    /// The worktree stays while another session works in it; only the last one to leave checks and removes it.
    @Test func sharedWorktreeStaysUntilTheLastSessionLeaves() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        let sub = try shared(app, parent: id)
        try "u".write(toFile: wt + "/untracked.txt", atomically: true, encoding: .utf8)
        await archiveTask(sub, ctx: ctx)
        #expect(archived(app, sub) && !archived(app, id))
        #expect(exists(wt + "/untracked.txt") && calls.confirms.isEmpty)  // the parent's work: not even asked about
        try FileManager.default.removeItem(atPath: wt + "/untracked.txt")
        await archiveTask(id, ctx: ctx)
        #expect(archived(app, id) && !exists(wt))
        #expect(try await t.git("branch", "--list", "x", in: t.repo) != "")
    }

    /// Archiving the parent takes a sub-chat sharing its worktree along: one check for both; declined, both stay open.
    @Test func parentArchiveChecksTheSharedWorktreeOnceForBoth() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        let sub = try shared(app, parent: id)
        app.select(taskId: sub)
        try "u".write(toFile: wt + "/untracked.txt", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeDirty])
        #expect(!archived(app, id) && !archived(app, sub) && exists(wt + "/untracked.txt"))
        #expect(app.state.selectedTaskId == sub)
        // Clean: both go, and the folder with them.
        try FileManager.default.removeItem(atPath: wt + "/untracked.txt")
        await archiveTask(id, ctx: ctx)
        #expect(archived(app, id) && archived(app, sub) && !exists(wt))
        // Restoring the parent brings the worktree back; its sub-chat stays in History.
        await restoreArchivedTask(id, ctx: ctx)
        #expect(!archived(app, id) && archived(app, sub) && exists(wt))
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
    /// unarchived and its tabs keep running: asked before they stop (HD-154).
    @Test func realLossAsksUniqueFirstBeforeTabsStop() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try await ignoreSetup(t, wt)
        try "CHANGED=1".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        try "db".write(toFile: wt + "/dev.db", atomically: true, encoding: .utf8)
        let leaf = try #require(app.state.tasks.first { $0.id == id }?.tabs.first?.root.leaves.first)
        app.restoredLeaves.remove(leaf.id)  // a live tab, not one waiting to resume after a restart
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains("dev.db, .env") == true)
        #expect(calls.infos.first?.contains("node_modules") == false)
        #expect(!archived(app, id) && exists(wt + "/dev.db"))
        // Asked before anything changed (HD-154): the tabs were never stopped, so the session never left the sidebar.
        #expect(app.launchContext(for: leaf.id) == .created(prompt: nil))
    }

    /// Claude Code's `.claude/.cache` (and other tool caches) in the copy do not ask (HD-154); `.claude/settings.local.json` does.
    @Test func toolCachesArchiveWithoutConfirm() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try ".claude/*\n!.claude/settings.json\n__pycache__/\n.DS_Store\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: wt + "/.claude", withIntermediateDirectories: true)
        try "{}".write(toFile: wt + "/.claude/settings.json", atomically: true, encoding: .utf8)
        _ = try await t.git("add", ".gitignore", ".claude/settings.json", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        for dir in [wt + "/.claude/.cache/x", wt + "/__pycache__"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try "c".write(toFile: wt + "/.claude/.cache/x/blob", atomically: true, encoding: .utf8)
        try "p".write(toFile: wt + "/__pycache__/m.pyc", atomically: true, encoding: .utf8)
        try "d".write(toFile: wt + "/.DS_Store", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms.isEmpty && calls.errors.isEmpty)
        #expect(archived(app, id) && !exists(wt))
    }

    @Test func claudeLocalSettingsStillAsk() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make(answer: false)
        defer { t.cleanup() }
        try ".claude/*\n!.claude/settings.json\n".write(toFile: wt + "/.gitignore", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: wt + "/.claude", withIntermediateDirectories: true)
        try "{}".write(toFile: wt + "/.claude/settings.json", atomically: true, encoding: .utf8)
        _ = try await t.git("add", ".gitignore", ".claude/settings.json", in: wt)
        _ = try await t.git("commit", "-q", "-m", "ignore", in: wt)
        try FileManager.default.createDirectory(atPath: wt + "/.claude/.cache", withIntermediateDirectories: true)
        try "c".write(toFile: wt + "/.claude/.cache/blob", atomically: true, encoding: .utf8)
        try "{}".write(toFile: wt + "/.claude/settings.local.json", atomically: true, encoding: .utf8)
        await archiveTask(id, ctx: ctx)
        #expect(calls.confirms == [L10n.worktreeIgnored])
        #expect(calls.infos.first?.contains("settings.local.json") == true)
        #expect(calls.infos.first?.contains(".cache") == false)
        #expect(!archived(app, id) && exists(wt))
    }

    @Test func restoreRecreatesWorktreeFromBranch() async throws {
        let (t, app, id, _, wt, calls, ctx) = try await make()
        defer { t.cleanup() }
        try await t.commit(file: "work.txt", on: "x", in: wt)
        // The chat itself lives with the agent (~/.claude/projects/<folder>), not in the copy: restore resumes it there.
        var claude = UUID()
        let sid = "0b6c4a52-7c1e-4c1a-9a55-3f1a2b3c4d5e"
        app.perform { s in
            _ = s.addTab(taskId: id, kind: .claude)
            claude = s.tasks.first { $0.id == id }!.tabs.last!.root.leaves[0].id
            s.setAgentSessionId(leafId: claude, sid)
        }
        await archiveTask(id, ctx: ctx)
        #expect(!exists(wt))
        await restoreArchivedTask(id, ctx: ctx, reselect: true)
        #expect(!archived(app, id))
        #expect(exists(wt + "/work.txt"))
        let leaf = try #require(app.state.tasks.first { $0.id == id }?.tabs.flatMap(\.root.leaves).first { $0.id == claude })
        #expect(leaf.agentSessionId == sid && leaf.cwd == wt)
        #expect(app.launchContext(for: claude) == .restored)
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

    /// Crash-safe archive (HD-059): the folder leaves its place in one rename, so a quit mid-removal
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

    /// HD-105: Hangar's status line override in the worktree is taken out first, so it does not make the archive «at risk».
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
        // Deleted in the background, shown as a removal until done.
        #expect(await waitUntil { !exists(leftover) && app.worktreeRemovals.items.isEmpty })
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
        let (t, app, _, main, _, _, _) = try await make()
        defer { t.cleanup() }
        let pid = app.state.projects[0].id
        var bad = UUID(), bad2 = UUID()
        app.perform { s in
            bad = s.addTask(projectId: pid, name: "bad", mode: .worktree(path: t.repo, branch: "main", base: "main"))
            bad2 = s.addTask(projectId: pid, name: "bad2", mode: .worktree(path: t.repo + "/", branch: "main", base: "main"))
        }
        // The main-folder chat works there (HD-132): the folder is theirs, not even checked.
        #expect(await app.archiveRemovingWorktree(bad2, force: true) == .archived(worktreeRemoved: false))
        app.perform { $0.archiveTask(id: main) }
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
        await #expect(throws: (any Error).self) { try await moveWorktreeAside(t.repo, git: git, runner: runner) }
        #expect(exists(t.repo + "/a.txt") && !exists(t.repo + ".hangar-removing"))
        let plain = t.root + "/plain"
        _ = try await t.git("init", "-q", plain, in: t.root)
        await #expect(throws: (any Error).self) { try await moveWorktreeAside(plain, git: git, runner: runner) }
        #expect(exists(plain + "/.git"))
        try await deleteTombstone(try await moveWorktreeAside(wt, git: git, runner: runner), runner: runner)
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

    /// The pointer over the toast holds it (§3.15): the pending hide is cancelled; leaving arms a fresh one.
    @Test func toastHoverHolds() {
        var items: [DispatchWorkItem] = []
        let undo = ArchiveUndo(delay: 5) { _, item in items.append(item) }
        let id = UUID()
        undo.show(id)
        undo.hold(true)
        #expect(items.count == 1 && items[0].isCancelled)
        #expect(undo.taskId == id)
        undo.hold(false)
        #expect(items.count == 2 && !items[1].isCancelled)
        items[1].perform()
        #expect(undo.taskId == nil)
        undo.hold(false)  // nothing shown: no new timer
        #expect(items.count == 2)
        // A newer toast while held arms nothing; leaving does.
        undo.show(id)
        #expect(items.count == 3)
        undo.hold(true)
        undo.show(message: "x")
        #expect(items.count == 3)
        undo.hold(false)
        #expect(items.count == 4 && !items[3].isCancelled)
    }
}
