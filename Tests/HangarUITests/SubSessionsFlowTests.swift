import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Sub-sessions end to end inside the app (#128): spawn, done detection from hooks, the parent's note, wait, archive.
@MainActor @Suite struct SubSessionsFlowTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-subs-\(UUID())")

    final class Fixture {
        let app: AppState
        var now = Date(timeIntervalSince1970: 1_000_000)
        var sent: [(leaf: UUID, text: String?, keys: [SendKey])] = []
        var screens: [UUID: String] = [:]
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
            app.noteRetryInterval = .seconds(3600)
            app.probeDetached = { _ in nil }
            app.clock = { [unowned self] in self.now }
            app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running },
                                           send: { [unowned self] leaf, text, keys in self.sent.append((leaf, text, keys)) },
                                           read: { [unowned self] leaf in self.screens[leaf] })
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

    /// The owner's release example: Stop with a background shell, the wake-up turn, then the final quiet Stop.
    @Test func doneOnlyAfterBackgroundWorkAndTheNoteIsTypedOnce() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf, message: "ship it")
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "release kicked off, waiting", background: 1)
        f.now += 120
        f.app.evaluateSubSessions()
        #expect(f.sent.isEmpty)
        #expect(f.app.subSessionStatus(of: f.app.state.tasks.first { $0.id == sub.task }!) == .running)
        // The background shell ended: Claude's own next turn.
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "Released 1.2.3\nall green", background: 0)
        f.now += 2
        f.app.evaluateSubSessions()
        #expect(f.sent.isEmpty)
        f.now += 4
        f.app.evaluateSubSessions()
        try #require(f.sent.count == 1)
        #expect(f.sent[0].leaf == f.parentLeaf && f.sent[0].keys == [.enter])
        #expect(f.sent[0].text == "[Hangar] sub-session \"Release\" finished (done): Released 1.2.3 all green — hangar://task/\(sub.task.uuidString.lowercased())")
        f.now += 60
        f.app.evaluateSubSessions()
        #expect(f.sent.count == 1)
        let waited = await f.app.waitForSubSessions([sub.task], timeout: .seconds(1))
        #expect(waited.map(\.status) == ["done"] && waited.first?.message == "Released 1.2.3\nall green")
    }

    @Test func needsInputAndErrorAreReportedAtOnce() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.app.handle(.event(EventMessage(tab: sub.tab, leaf: sub.leaf, kind: .notification, notificationType: "permission_prompt",
                                         message: "Claude needs your permission to use Bash")))
        #expect(f.sent.last?.text?.contains("is waiting for input (needs-input)") == true)
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.app.handle(.event(EventMessage(tab: sub.tab, leaf: sub.leaf, kind: .stopFailure, message: "API Error", error: "server_error")))
        #expect(f.sent.last?.text?.contains("stopped with an error (error): API Error") == true)
        #expect(f.sent.count == 2)
    }

    @Test func notesWaitForTheUserAndTheParentsTurn() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        // The parent is mid-turn, then the user starts typing in it.
        f.hook(.prompt, tab: f.parentTab, leaf: f.parentLeaf)
        f.hook(.prompt, tab: sub.tab, leaf: sub.leaf)
        f.hook(.stop, tab: sub.tab, leaf: sub.leaf, message: "done!", background: 0)
        f.now += 6
        f.app.evaluateSubSessions()
        #expect(f.sent.isEmpty)
        f.hook(.stop, tab: f.parentTab, leaf: f.parentLeaf, message: "ok")
        #expect(f.sent.count == 1)  // the parent's own Stop brings the note
        f.sent.removeAll()

        let second = try await f.spawn("Second")
        f.app.keyTyped(leaf: f.parentLeaf, keyCode: 0, modifiers: [], characters: "a")
        f.hook(.prompt, tab: second.tab, leaf: second.leaf)
        f.hook(.stop, tab: second.tab, leaf: second.leaf, message: "fine", background: 0)
        f.now += 60
        f.app.evaluateSubSessions()
        f.app.deliverNotes(to: f.parent)
        #expect(f.sent.isEmpty)  // a draft is never typed over
        f.app.keyTyped(leaf: f.parentLeaf, keyCode: 36, modifiers: [], characters: "\r")
        f.app.deliverNotes(to: f.parent)
        #expect(f.sent.isEmpty)  // the typing pause
        f.now += 6
        // Busy screen: claude's spinner.
        f.screens[f.parentLeaf] = "✻ Working… (esc to interrupt)"
        f.app.deliverNotes(to: f.parent)
        #expect(f.sent.isEmpty)
        f.screens[f.parentLeaf] = "> "
        f.app.deliverNotes(to: f.parent)
        #expect(f.sent.map(\.text) == ["[Hangar] sub-session \"Second\" finished (done): fine — hangar://task/\(second.task.uuidString.lowercased())"])
    }

    /// «Notify me only»: nothing is typed into the parent; the user gets one banner.
    @Test func notifyOnlyNeverTypesIntoTheParent() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var notices: [AgentNotice] = []
        f.app.onSubSessionNotice = { notices.append($0) }
        let r = await f.app.respond(1, .tasksSpawn(parent: f.parentLeaf.uuidString, name: "Quiet", prompt: "look", agent: nil,
                                                   worktree: false, base: nil, notifyOnly: true))
        guard case .success(let data) = r.body else { Issue.record("\(r.body)"); return }
        let id = try JSONDecoder().decode(SpawnResult.self, from: data).task.id
        let task = try #require(f.app.state.tasks.first { $0.id == id })
        #expect(task.subDelivery == .notify)
        let tab = task.tabs[0].id, leaf = task.tabs[0].root.leaves[0].id
        f.hook(.prompt, tab: tab, leaf: leaf)
        f.hook(.stop, tab: tab, leaf: leaf, message: "found it in config/app.yml", background: 0)
        f.now += 6
        f.app.evaluateSubSessions()
        #expect(f.sent.isEmpty)
        #expect(notices.count == 1 && notices.first?.body == "found it in config/app.yml" && notices.first?.subtitle == "Quiet")
    }

    /// The parent's context pays for the result: capped, the cut marked, the tab for tabs_read given.
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
        f.app.evaluateSubSessions()
        #expect((f.sent.first?.text?.count ?? 0) < SubSessionNote.maxMessage + 200)
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

    @Test func archivingTheParentArchivesItsSubSessions() async throws {
        let f = try Fixture(dir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = try await f.spawn()
        _ = await f.app.respond(5, .tasksArchive(task: f.parent.uuidString))
        #expect(f.app.state.tasks.first { $0.id == sub.task }?.archived == true)
        #expect(f.app.state.tasks.first { $0.id == f.parent }?.archived == true)
    }
}
