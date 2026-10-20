import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Usage
import Workspace

@MainActor @Suite struct AgentWiringTests {
    /// One task in /tmp with tabs of the given kinds (one leaf each).
    private func makeApp(_ kinds: [LeafKind], drawer: Bool = false) -> AppState {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let t = s.addTask(projectId: p, name: "t")
        for kind in kinds { s.addTab(taskId: t, kind: kind) }
        if drawer { s.toggleDrawer(taskId: t) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-agents-\(UUID())")
        return AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                        configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
    }

    private func event(_ app: AppState, tab n: Int, _ kind: HookKind, session: String? = nil, type: String? = nil, message: String? = nil) {
        let tab = app.state.tasks[0].tabs[n]
        app.handle(.event(EventMessage(tab: tab.id, leaf: tab.root.leaves[0].id, kind: kind, session: session,
                                       notificationType: type, message: message)))
    }

    private func leaf(_ app: AppState, _ n: Int) -> Leaf { app.state.tasks[0].tabs[n].root.leaves[0] }

    @Test func eventUpdatesLeafAndTaskState() {
        let app = makeApp([.claude])
        var transitions: [Transition] = []
        app.onTransition = { transitions.append($0) }
        event(app, tab: 0, .prompt)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .working)
        #expect(app.state(of: app.state.tasks[0]) == .working)
        #expect(app.state(of: app.state.tasks[0].tabs[0]) == .working)
        #expect(app.workingLeafCount == 1)
        event(app, tab: 0, .notification, type: "permission_prompt", message: "Needs permission")
        #expect(app.state(of: app.state.tasks[0]) == .waiting)
        #expect(transitions.last?.leaf == leaf(app, 0).id)
        #expect(transitions.last.map { [$0.from, $0.to] } == [.working, .waiting])
        #expect(app.lastNotificationMessage[leaf(app, 0).id] == "Needs permission")
    }

    @Test func unknownTabOrLeafIgnored() {
        let app = makeApp([.claude, .claude])
        var called = false
        app.onTransition = { _ in called = true }
        let before = app.state
        let tab0 = app.state.tasks[0].tabs[0]
        app.handle(.event(EventMessage(tab: UUID(), leaf: UUID(), kind: .prompt, session: "a")))
        app.handle(.event(EventMessage(tab: tab0.id, leaf: UUID(), kind: .prompt, session: "a")))
        app.handle(.event(EventMessage(tab: UUID(), leaf: tab0.root.leaves[0].id, kind: .prompt, session: "a")))
        // Leaf from another tab.
        app.handle(.event(EventMessage(tab: tab0.id, leaf: leaf(app, 1).id, kind: .prompt, session: "a")))
        // Leaf of an archived task.
        app.archive(taskId: app.state.tasks[0].id)
        let archived = app.state
        app.handle(.event(EventMessage(tab: tab0.id, leaf: tab0.root.leaves[0].id, kind: .prompt, session: "a")))
        #expect(app.statuses.leaves.isEmpty)
        #expect(!called)
        #expect(app.state == archived)
        var expected = before
        expected.archiveTask(id: before.tasks[0].id)
        #expect(archived == expected)
    }

    @Test func sessionIdSavedToLeaf() throws {
        let app = makeApp([.claude])
        var changes = 0
        app.didChange = { changes += 1 }
        event(app, tab: 0, .sessionStart, session: "s1")
        #expect(leaf(app, 0).agentSessionId == "s1")
        #expect(resumeSet(for: app.state).contains(leaf(app, 0).id))
        let spec = try launchSpec(for: leaf(app, 0), tabId: app.state.tasks[0].tabs[0].id, config: app.config,
                                  socketPath: app.socketPath, userShell: "/bin/zsh", restoring: true, initialPrompt: nil)
        #expect(spec.command.contains("--resume s1"))
        let after = changes
        event(app, tab: 0, .prompt, session: "s1")
        #expect(changes == after)
    }

    @Test func hostileSessionIdNotStored() {
        let app = makeApp([.claude])
        for bad in ["-x", "--dangerously-skip-permissions", "x; rm -rf ~"] {
            event(app, tab: 0, .sessionStart, session: bad)
            #expect(leaf(app, 0).agentSessionId == nil, "\(bad)")
        }
        #expect(app.statuses.status(leaf(app, 0).id).sessionId == nil)
    }

    @Test func notificationMessageClearedByNextEvent() {
        let app = makeApp([.claude])
        let id = leaf(app, 0).id
        event(app, tab: 0, .notification, type: "permission_prompt", message: "m1")
        #expect(app.lastNotificationMessage[id] == "m1")
        event(app, tab: 0, .prompt)
        #expect(app.lastNotificationMessage[id] == nil)
        event(app, tab: 0, .notification, type: "permission_prompt", message: "m2")
        event(app, tab: 0, .notification, type: "permission_prompt")
        #expect(app.lastNotificationMessage[id] == nil)
    }

    @Test func sessionIdNotWrittenToShellLeaf() {
        let app = makeApp([.shell, .codex])
        event(app, tab: 0, .prompt, session: "s1")
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .working)
        #expect(leaf(app, 0).agentSessionId == nil)
        // A claude hook in a codex leaf is not its session either; codex-notify is.
        event(app, tab: 1, .sessionStart, session: "c1")
        #expect(leaf(app, 1).agentSessionId == nil)
        event(app, tab: 1, .codexNotify, session: "c2")
        #expect(leaf(app, 1).agentSessionId == "c2")
    }

    @Test func drawerLeafEvent() {
        let app = makeApp([.shell], drawer: true)
        let d = app.state.tasks[0].drawer.leaf!.id
        app.handle(.event(EventMessage(tab: d, leaf: d, kind: .prompt)))
        #expect(app.state(ofLeaf: d) == .working)
        #expect(app.state(of: app.state.tasks[0]) == .working)
    }

    @Test func bellOnShellIgnored() {
        let app = makeApp([.shell, .codex])
        app.signal(.bell, leaf: leaf(app, 0).id)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .idle)
        app.signal(.desktopNotification, leaf: leaf(app, 0).id)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .idle)
        app.signal(.bell, leaf: leaf(app, 1).id)
        #expect(app.state(ofLeaf: leaf(app, 1).id) == .waiting)
        app.signal(.focused, leaf: leaf(app, 1).id)
        #expect(app.state(ofLeaf: leaf(app, 1).id) == .idle)
    }

    @Test func exitFailedThenRelaunchIdle() {
        let app = makeApp([.claude])
        app.signal(.exited(code: 2), leaf: leaf(app, 0).id)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .failed)
        app.signal(.relaunched, leaf: leaf(app, 0).id)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .idle)
    }

    @Test func archivedTaskStatusesCleared() {
        let app = makeApp([.claude])
        event(app, tab: 0, .prompt)
        #expect(app.statuses.leaves[leaf(app, 0).id] != nil)
        app.archive(taskId: app.state.tasks[0].id)
        #expect(app.statuses.leaves[leaf(app, 0).id] == nil)
        #expect(app.workingLeafCount == 0)
    }

    @Test func usageMessagesUpdateBoard() {
        let app = makeApp([.claude])
        var alerts: [[UsageAlert]] = []
        app.onUsageAlerts = { alerts.append($0) }
        app.handle(.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 86, resetsAt: nil)])))
        #expect(app.usage.view(.claude, now: Date())?.windows[0].usedPercent == 86)
        #expect(alerts.last?.map(\.level) == [.warn])
        var turns = 0
        app.onCodexTurn = { turns += 1 }
        event(app, tab: 0, .stopFailure)
        #expect(app.usage.level(.claude, now: Date()) == .full)
        #expect(turns == 0)
    }

    @Test func codexNotifyCallsCodexTurn() {
        let app = makeApp([.codex])
        var turns = 0
        app.onCodexTurn = { turns += 1 }
        event(app, tab: 0, .codexNotify)
        #expect(turns == 1)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .done)
    }

    @Test func limitReachedTurnsAgentDotsRed() {
        let app = makeApp([.claude, .codex, .shell])
        event(app, tab: 0, .prompt)
        event(app, tab: 1, .codexNotify)  // any event; codex leaf stays non-failed
        app.statuses.apply(.hook(.prompt, session: nil, notificationType: nil), leaf: leaf(app, 1).id)
        app.statuses.apply(.hook(.prompt, session: nil, notificationType: nil), leaf: leaf(app, 2).id)
        _ = app.usage.markLimitReached(.claude, now: Date())
        #expect(app.displayState(ofLeaf: leaf(app, 0).id) == .failed)
        #expect(app.displayState(of: app.state.tasks[0].tabs[0]) == .failed)
        #expect(app.displayState(ofLeaf: leaf(app, 1).id) == app.state(ofLeaf: leaf(app, 1).id))
        #expect(app.displayState(ofLeaf: leaf(app, 1).id) != .failed)
        #expect(app.displayState(ofLeaf: leaf(app, 2).id) == .working)
        #expect(app.displayState(of: app.state.tasks[0]) == .failed)
    }

    @Test func showsDotRules() {
        let app = makeApp([.shell, .shell, .claude])
        let tabs = app.state.tasks[0].tabs
        #expect(!app.showsDot(tabs[0], state: .idle))
        #expect(app.showsDot(tabs[1], state: .working))
        #expect(app.showsDot(tabs[2], state: .idle))
    }
}
