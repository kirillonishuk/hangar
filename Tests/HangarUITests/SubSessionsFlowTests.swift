import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Sub-sessions end to end inside the app (#128, #131): spawn, done detection from hooks, the user's notification, wait,
/// archive. Nothing is ever sent to the parent's terminal.
@MainActor @Suite struct SubSessionsFlowTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-subs-\(UUID())")

    final class Fixture {
        let app: AppState
        var now = Date(timeIntervalSince1970: 1_000_000)
        var sent: [(leaf: UUID, text: String?, keys: [SendKey])] = []
        var screens: [UUID: String] = [:]
        var notices: [AgentNotice] = []
        let parent: UUID
        let parentLeaf: UUID
        let parentTab: UUID

        @MainActor init(dir: URL) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var s = WorkspaceState()
            let p = s.addProject(name: "app", path: dir.path)
            let t = s.addTask(projectId: p, name: "Main")
            let tab = s.addTab(taskId: t, kind: .claude)
            parent = t
            parentTab = tab
            parentLeaf = s.tasks.first { $0.id == t }!.tabs[0].root.leaves[0].id
            app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
            app.keepAwake = .inert()
            app.codexRead = nil
            app.subPollInterval = .milliseconds(30)
            app.probeDetached = { _ in nil }
            app.clock = { [unowned self] in self.now }
            app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running },
                                           send: { [unowned self] leaf, text, keys in self.sent.append((leaf, text, keys)) },
                                           read: { [unowned self] leaf in self.screens[leaf] })
            app.onSubSessionNotice = { [unowned self] in self.notices.append($0) }
        }

        @MainActor func spawn(_ name: String = "Release") async throws -> (task: UUID, tab: UUID, leaf: UUID, result: SpawnResult) {
            let r = await app.respond(1, .tasksSpawn(parent: parentLeaf.uuidString, name: name, prompt: "ship it", agent: .claude,
                                                     worktree: false, base: nil))
            guard case .success(let data) = r.body else { throw ControlError(code: .failed, message: "\(r.body)") }
            let result = try JSONDecoder().decode(SpawnResult.self, from: data)
            let task = app.state.tasks.first { $0.id == result.task.id }!
            return (task.id, task.tabs[0].id, task.tabs[0].root.leaves[0].id, result)
        }

        @MainActor func hook(_ kind: HookKind, tab: UUID, leaf: UUID, message: String? = nil, background: Int? = nil) {
            app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: kind, session: "s-\(leaf.uuidString.prefix(4))", message: message,
                                           background: background)))
        }
    }

    @Test func spawnCreatesAChildOfTheCaller() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        let task = try #require(f.app.state.tasks.first { $0.id == sub.task })
        #expect(task.parentTaskId == f.parent && task.projectId == f.app.state.tasks.first { $0.id == f.parent }?.projectId)
        #expect(sub.result.task.parent == f.parent)
        #expect(sub.result.link == "hangar://task/\(sub.task.uuidString.lowercased())")
        #expect(f.app.pendingPrompts[sub.leaf] == "ship it" + AppState.subSessionPromptSuffix)
        #expect(f.app.state.selectedTaskId != sub.task)
        #expect(f.app.groupRows(task.projectId).map(\.depth) == [0, 1])
        // By session name too; an unknown caller is refused.
        let other = await f.app.respond(2, .tasksSpawn(parent: UUID().uuidString, name: "x", prompt: "p", agent: nil, worktree: false, base: nil))
        if case .failure(let e) = other.body { #expect(e.code == .notFound) } else { Issue.record("spawned under nobody") }
        let free = await f.app.respond(3, .tasksSpawn(parent: nil, name: "x", prompt: "p", agent: nil, worktree: false, base: nil))
        if case .failure(let e) = free.body { #expect(e.code == .badParams) } else { Issue.record("spawned without a parent") }
    }

    /// The owner's release example: Stop with a background shell, the wake-up turn, then the final quiet Stop. The user
    /// is notified once; the parent's terminal gets nothing.
    @Test func doneOnlyAfterBackgroundWorkAndTheUserIsNotifiedOnce() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf, message: "ship it")
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "release kicked off, waiting", background: 1)
        f.now += 120
        f.app.evaluateSubSessions()
        #expect(f.notices.isEmpty)
        #expect(f.app.subSessionStatus(of: f.app.state.tasks.first { $0.id == sub.task }!) == .running)
        // The background shell ended: Claude's own next turn.
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "Released 1.2.3\nall green", background: 0)
        f.now += 2
        f.app.evaluateSubSessions()
        #expect(f.notices.isEmpty)
        f.now += 4
        f.app.evaluateSubSessions()
        try #require(f.notices.count == 1)
        let n = f.notices[0]
        #expect(n.title == L10n.subChatDone && n.subtitle == "Release" && n.body == "Released 1.2.3 all green")
        // The leaf's own «done» banner is replaced, not doubled; grouped under the parent.
        #expect(n.id == sub.leaf.uuidString && n.leaf == sub.leaf && n.thread == f.parent.uuidString)
        f.now += 60
        f.app.evaluateSubSessions()
        #expect(f.notices.count == 1)
        #expect(f.sent.isEmpty)
        let waited = await f.app.waitForSubSessions([sub.task], timeout: .seconds(1))
        #expect(waited.map(\.status) == ["done"] && waited.first?.message == "Released 1.2.3\nall green")
    }

    /// Needs-input and errors end `sessions_wait` at once; the banner for them is the leaf's own (permission, failure).
    @Test func needsInputAndErrorEndTheWaitAtOnce() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        let task = { f.app.state.tasks.first { $0.id == sub.task }! }
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.app.handle(.event(EventMessage(tab: sub.tab, leaf: sub.leaf, kind: .notification, notificationType: "permission_prompt",
                                         message: "Claude needs your permission to use Bash")))
        #expect(f.app.subSessionStatus(of: task()) == .needsInput)
        let asked = await f.app.waitForSubSessions([sub.task], timeout: .seconds(1))
        #expect(asked.first?.status == "needs-input" && asked.first?.message == "Claude needs your permission to use Bash")
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.app.handle(.event(EventMessage(tab: sub.tab, leaf: sub.leaf, kind: .stopFailure, message: "API Error", error: "server_error")))
        #expect(f.app.subSessionStatus(of: task()) == .error)
        #expect(f.notices.isEmpty && f.sent.isEmpty)
    }

    /// The owner's rule (#131): whatever the sub-chat does, and however it was made, the parent's terminal gets nothing.
    @Test func nothingIsEverSentToTheParent() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The parent sits idle at its prompt: the moment an old build would have typed into it.
        f.hook(.prompt, tab: f.parentTab, leaf: f.parentLeaf)
        f.hook(.stop, tab: f.parentTab, leaf: f.parentLeaf, message: "ok")
        f.screens[f.parentLeaf] = "> "
        let viaMCP = try await f.spawn("Quiet")
        guard case .success(let manual) = await f.app.spawnSubSession(parent: f.parent, name: "By hand", prompt: "look", kind: .claude,
                                                                      worktree: false, base: nil) else { Issue.record("not spawned"); return }
        let byHand = try #require(f.app.state.tasks.first { $0.id == manual })
        let handLeaf = byHand.tabs[0].root.leaves[0].id
        // Made by hand: the user's text as typed, no suffix.
        #expect(f.app.pendingPrompts[handLeaf] == "look")
        for (tab, leaf) in [(viaMCP.tab, viaMCP.leaf), (byHand.tabs[0].id, handLeaf)] {
            f.hook(.prompt, tab: tab, leaf: leaf)
            f.app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: .notification, notificationType: "permission_prompt", message: "may I?")))
            f.hook(.prompt, tab: tab, leaf: leaf)
            f.app.handle(.event(EventMessage(tab: tab, leaf: leaf, kind: .stopFailure, message: "API Error", error: "server_error")))
            f.hook(.prompt, tab: tab, leaf: leaf)
            f.hook(.stop, tab: tab, leaf: leaf, message: "found it in config/app.yml", background: 0)
        }
        f.now += 60
        f.app.evaluateSubSessions()
        f.hook(.prompt, tab: f.parentTab, leaf: f.parentLeaf)
        f.hook(.stop, tab: f.parentTab, leaf: f.parentLeaf, message: "ok")
        f.now += 60
        f.app.evaluateSubSessions()
        #expect(f.sent.isEmpty)
        #expect(Set(f.notices.map(\.subtitle)) == ["Quiet", "By hand"] && f.notices.count == 2)
    }

    /// Muted sub-chats and notifications turned off: no banner.
    @Test func mutedSubChatIsNotAnnounced() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.app.perform { s in if let i = s.tasks.firstIndex(where: { $0.id == sub.task }) { s.tasks[i].muted = true } }
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "done", background: 0)
        f.now += 6
        f.app.evaluateSubSessions()
        #expect(f.notices.isEmpty)
        #expect(f.app.subSessionStatus(of: f.app.state.tasks.first { $0.id == sub.task }!) == .done)
    }

    /// The caller's context pays for the result: capped, the cut marked, the tab for tabs_read given.
    @Test func resultIsCompact() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: String(repeating: "x", count: 1900), background: 0)
        f.now += 6
        let info = await f.app.waitForSubSessions([sub.task], timeout: .seconds(1)).first
        #expect(info?.status == "done" && info?.truncated == true && info?.tab == sub.tab)
        #expect((info?.message?.count ?? 0) <= SubSessionInfo.maxMessage && info?.message?.hasSuffix("[truncated; full output: tabs_read]") == true)
    }

    @Test func waitTimesOutWithStillRunning() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.screens[sub.leaf] = "line 1\nline 2"
        let r = await f.app.respond(4, .tasksWait(sessions: [], parent: f.parentLeaf.uuidString, timeout: 1))
        guard case .success(let data) = r.body else { Issue.record("\(r.body)"); return }
        let waited = try JSONDecoder().decode(WaitResult.self, from: data)
        #expect(waited.sessions.map(\.status) == ["still-running"] && waited.sessions.first?.message == "line 1\nline 2")
        #expect(waited.sessions.first?.agent == .claude && waited.sessions.first?.name == "Release")
    }

    /// The process probe reads the agent's pid on this Mac: never an exited agent's (reused pid) or a remote one's (spec §9).
    @Test func processProbeOnlyForALiveLocalAgent() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var probed: [Int32] = []
        f.app.probeDetached = { probed.append($0); return 1 }
        let sub = try await f.spawn()
        f.app.handle(.event(EventMessage(tab: sub.tab, leaf: sub.leaf, kind: .sessionStart, session: "s-\(sub.leaf.uuidString.prefix(4))",
                                         agentPid: 4242, tabAgent: true)))
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "ok", background: 0)
        f.now += 60
        let task = { f.app.state.tasks.first { $0.id == sub.task }! }
        #expect(f.app.statuses.status(sub.leaf).agentPid == 4242)
        #expect(f.app.subSessionStatus(of: task()) == .running)
        #expect(!probed.isEmpty && probed.allSatisfy { $0 == 4242 })
        let probes = probed.count

        var running = false
        f.app.terminals = TerminalAccess(start: { _ in }, state: { _ in running ? .running : .exited }, send: { _, _, _ in }, read: { _ in nil })
        #expect(f.app.subSessionStatus(of: task()) == .done && probed.count == probes)

        running = true
        f.app.remote = f.app.makeRemoteHosts(paths: SSHPaths(stateDir: dir.path), sshPath: "/usr/bin/false", isActive: { false })
        f.app.perform { s in
            let remote = s.addRemoteProject(name: "srv", host: "dev", path: "/srv/app")
            if let i = s.tasks.firstIndex(where: { $0.id == sub.task }) { s.tasks[i].projectId = remote }
        }
        #expect(f.app.subSessionStatus(of: task()) == .done && probed.count == probes)
    }

    /// Default placement (#131): the parent's own worktree; the sub-chat's terminal opens there, no new copy is made.
    @Test func subChatOpensInTheParentsWorktree() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = dir.appendingPathComponent("app.worktrees/feat").path
        let mode = TaskMode.worktree(path: wt, branch: "feat", base: "main")
        f.app.perform { s in if let i = s.tasks.firstIndex(where: { $0.id == f.parent }) { s.tasks[i].mode = mode } }
        let sub = try await f.spawn()
        let task = try #require(f.app.state.tasks.first { $0.id == sub.task })
        #expect(task.mode == mode && task.tabs[0].root.leaves[0].cwd == wt)
        #expect(sub.result.task.path == wt && sub.result.task.branch == "feat")
        #expect(task.tabs.count == 1)  // no setup tab: nothing was created
    }

    /// Archiving a sub-chat that shares its open parent's worktree keeps that worktree (no check, nothing removed).
    @Test func archivingASubChatKeepsTheSharedWorktree() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = dir.appendingPathComponent("app.worktrees/feat").path
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "work".write(toFile: wt + "/uncommitted.txt", atomically: true, encoding: .utf8)
        f.app.perform { s in
            if let i = s.tasks.firstIndex(where: { $0.id == f.parent }) { s.tasks[i].mode = .worktree(path: wt, branch: "feat", base: "main") }
        }
        let sub = try await f.spawn()
        let r = await f.app.respond(5, .tasksArchive(task: sub.task.uuidString))
        guard case .success(let data) = r.body else { Issue.record("\(r.body)"); return }
        #expect(try JSONDecoder().decode(ArchiveResult.self, from: data).worktreeRemoved == false)
        #expect(f.app.state.tasks.first { $0.id == sub.task }?.archived == true)
        #expect(f.app.state.tasks.first { $0.id == f.parent }?.archived == false)
        #expect(FileManager.default.fileExists(atPath: wt + "/uncommitted.txt"))
    }

    @Test func archivingTheParentArchivesItsSubSessions() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        _ = await f.app.respond(5, .tasksArchive(task: f.parent.uuidString))
        #expect(f.app.state.tasks.first { $0.id == sub.task }?.archived == true)
        #expect(f.app.state.tasks.first { $0.id == f.parent }?.archived == true)
    }
}
