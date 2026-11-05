import AgentStatus
import ControlServer
import Foundation
import Testing
import Git
import TestSupport
@testable import HangarUI
import Workspace

/// Worktrees an agent makes or renames on its own (HD-134): Hangar follows and offers, never changes files unasked.
@MainActor @Suite struct AgentWorktreeUITests {
    private func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    /// Main-folder chat M (claude tab with a conversation) on `main`; the agent made `.claude/worktrees/aut` itself.
    private func make() async throws -> (TempRepo, AppState, m: UUID, tab: UUID, leaf: UUID, nested: String) {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try t.git("worktree", "add", "-q", "-b", "aut", t.repo + "/.claude/worktrees/aut", "main", in: t.repo)
            return t
        }
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let m = s.addTask(projectId: p, name: "m")
        let tab = s.addTab(taskId: m, kind: .claude)
        if case .leaf(var l) = s.tasks[0].tabs[0].root { l.agentSessionId = "s1"; s.tasks[0].tabs[0].root = .leaf(l) }
        let leaf = s.tasks[0].tabs[0].root.leaves[0].id
        s.select(taskId: m)
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.keepAwake = .inert()
        return (t, app, m, tab, leaf, real(t.repo + "/.claude/worktrees/aut"))
    }

    private func hook(_ app: AppState, tab: UUID, leaf: UUID, _ kind: HookKind = .stop, cwd: String, session: String = "s1") async {
        app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: kind, session: session, cwd: cwd)))
        await app.worktreeChecksIdle()
    }

    /// Everything under the repository, with sizes: nothing may change unless an action is clicked.
    private func snapshot(_ t: TempRepo) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let fm = FileManager.default
        for root in [t.repo] {
            guard let e = fm.enumerator(atPath: root) else { continue }
            for case let p as String in e where !p.hasPrefix(".git/index") && !p.hasPrefix(".git/logs") {
                out[p] = (try? fm.attributesOfItem(atPath: root + "/" + p)[.size] as? Int) ?? -1
            }
        }
        return out
    }

    @Test func agentInNestedWorktreeOffersAndAdopts() async throws {
        let (t, app, m, tab, leaf, nested) = try await make()
        defer { t.cleanup() }
        let before = try snapshot(t)
        // A subfolder of its own checkout: nothing to say.
        await hook(app, tab: tab, leaf: leaf, cwd: t.repo + "/src")
        #expect(app.selectedAgentElsewhere == nil)
        // A nested agent (another session) in the copy: not this tab's agent.
        await hook(app, tab: tab, leaf: leaf, cwd: nested, session: "other")
        #expect(app.selectedAgentElsewhere == nil)
        // The tab's agent entered the worktree (EnterWorktree): offered; until adopted it is also a copy without a chat.
        await hook(app, tab: tab, leaf: leaf, cwd: nested + "/src")
        #expect(app.selectedAgentElsewhere?.entry.path == nested)
        #expect(app.selectedAgentElsewhere?.entry.branch == "aut")
        #expect(app.spareWorktrees(of: app.state.projects[0].id).map(\.path) == [nested])
        #expect(try snapshot(t) == before)  // reading only

        // «Скрыть»: gone for this chat and copy.
        app.hideAgentPlace(m)
        #expect(app.selectedAgentElsewhere == nil)
        app.hiddenAgentPlaces = []

        app.adoptAgentWorktree(m)
        let task = app.state.tasks.first { $0.id == m }!
        #expect(task.mode == .worktree(path: nested, branch: "aut", base: "main"))
        let l = task.tabs[0].root.leaves[0]
        #expect(l.cwd == nested && l.relinkedFrom == t.repo && l.agentSessionId == "s1")  // resume follows, conversation copied at launch
        #expect(app.selectedAgentElsewhere == nil && app.worktreePlaces[m] == .inPlace)
        app.recheckWorktree(of: m)
        await app.worktreeChecksIdle()
        #expect(app.spareWorktrees(of: app.state.projects[0].id).isEmpty)
        #expect(try snapshot(t) == before)  // adopting touched nothing on disk
    }

    @Test func agentBackHomeOrOutsideClearsTheBar() async throws {
        let (t, app, _, tab, leaf, nested) = try await make()
        defer { t.cleanup() }
        await hook(app, tab: tab, leaf: leaf, cwd: nested)
        #expect(app.selectedAgentElsewhere != nil)
        await hook(app, tab: tab, leaf: leaf, cwd: t.repo)
        #expect(app.selectedAgentElsewhere == nil)
        await hook(app, tab: tab, leaf: leaf, cwd: t.root)  // outside the repository
        #expect(app.selectedAgentElsewhere == nil)
    }

    /// The agent renamed its worktree's branch: the chat's branch follows git, so archive + restore work.
    @Test func renamedBranchFollowsAndRestores() async throws {
        let (t, app, m, tab, leaf, nested) = try await make()
        defer { t.cleanup() }
        await hook(app, tab: tab, leaf: leaf, cwd: nested)
        app.adoptAgentWorktree(m)
        _ = try await t.git("branch", "-m", "aut", "aut-1076-renamed", in: nested)
        app.recheckWorktree(of: m)
        await app.worktreeChecksIdle()
        #expect(app.state.tasks.first { $0.id == m }?.branch == "aut-1076-renamed")

        // Renamed again right before archiving: archive records what git has, restore re-creates it.
        _ = try await t.git("branch", "-m", "aut-1076-renamed", "aut-final", in: nested)
        #expect(await app.archiveRemovingWorktree(m, force: true) == .archived(worktreeRemoved: true))
        #expect(app.state.tasks.first { $0.id == m }?.branch == "aut-final")
        #expect(await app.restoreFromArchive(m) == .restored)
        #expect(try await t.git("rev-parse", "--abbrev-ref", "HEAD", in: nested) == "aut-final")
    }

    /// A worktree the archive failed to remove, renamed meanwhile: restore finds it by its path, not its old branch.
    @Test func restoreFindsKeptWorktreeByPath() async throws {
        let (t, app, m, tab, leaf, nested) = try await make()
        defer { t.cleanup() }
        await hook(app, tab: tab, leaf: leaf, cwd: nested)
        app.adoptAgentWorktree(m)
        app.archive(taskId: m)  // archived without removing the folder (as a failed removal leaves it)
        _ = try await t.git("branch", "-m", "aut", "renamed", in: nested)
        #expect(await app.restoreFromArchive(m) == .restored)
        #expect(app.state.tasks.first { $0.id == m }?.branch == "renamed")
    }

    @Test func spareCopyOpensAsChatAndIsRemovedOnlyOnClick() async throws {
        let (t, app, _, _, _, nested) = try await make()
        defer { t.cleanup() }
        let p = app.state.projects[0].id
        app.checkWorktrees(projectId: p)
        await app.worktreeChecksIdle()
        #expect(FileManager.default.fileExists(atPath: nested))
        let spare = try #require(app.spareWorktrees(of: p).first)
        let id = try #require(app.openSpareWorktree(spare, projectId: p))
        #expect(app.state.tasks.first { $0.id == id }?.mode == .worktree(path: nested, branch: "aut", base: "main"))
        #expect(app.spareWorktrees(of: p).isEmpty)
        #expect(FileManager.default.fileExists(atPath: nested))

        // Removing a spare copy: asked first, then the archive's checks; the branch stays.
        app.perform { $0.deleteTask(id: id) }
        var asked: [String] = []
        var ctx = ActionContext(app: app)
        ctx.confirm = { m, _, _, then in asked.append(m); then() }
        await removeSpareWorktree(spare, projectId: p, ctx: ctx)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: nested) })
        #expect(asked.count == 1)
        #expect(try await t.git("branch", "--list", "aut", in: t.repo) != "")
    }

    /// Not ignored → noticed (read only); the `info/exclude` line is written only by the click.
    @Test func notIgnoredWorktreeIsHiddenOnlyOnClick() async throws {
        let (t, app, _, _, _, _) = try await make()
        defer { t.cleanup() }
        let p = app.state.projects[0].id
        let exclude = t.repo + "/.git/info/exclude"
        let before = try? String(contentsOfFile: exclude, encoding: .utf8)
        app.checkWorktrees(projectId: p)
        await app.worktreeChecksIdle()
        for _ in 0..<200 where app.unignoredCopies[p] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.unignoredCopies[p] == [".claude/worktrees/aut"])
        #expect((try? String(contentsOfFile: exclude, encoding: .utf8)) == before)
        #expect(await app.hideCopiesFromGit(p) == nil)
        #expect(try String(contentsOfFile: exclude, encoding: .utf8).hasSuffix("/.claude/worktrees/\n"))
        for _ in 0..<200 where app.unignoredCopies[p] != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.unignoredCopies[p] == nil)
        // Search skips the nested checkout (rg would descend into it).
        #expect(app.nestedCheckouts(in: t.repo) == [".claude/worktrees/aut"])
    }
}
