import AgentStatus
import ControlServer
import Exec
import CoreServices
import Foundation
import Observation
import Power
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
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                        configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.codexRead = nil  // a codex turn must not look for the real codex
        app.keepAwake = .inert()
        return app
    }

    private func event(_ app: AppState, tab n: Int, _ kind: HookKind, session: String? = nil, type: String? = nil, message: String? = nil,
                       source: String? = nil) {
        let tab = app.state.tasks[0].tabs[n]
        app.handle(.event(EventMessage(tab: tab.id, leaf: tab.root.leaves[0].id, kind: kind, session: session,
                                       notificationType: type, message: message, source: source)))
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
        #expect(app.statuses.status(leaf(app, 0).id).attention?.text == "Needs permission")
    }

    @Test func leafDoneFiresOnlyOnTransitionToDone() {
        let app = makeApp([.claude])
        var done: [UUID] = []
        app.onLeafDone = { done.append($0) }
        event(app, tab: 0, .prompt)
        #expect(done.isEmpty)
        event(app, tab: 0, .stop)
        #expect(done == [leaf(app, 0).id])
        event(app, tab: 0, .stop)
        #expect(done.count == 1)
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
        expected.archiveTask(id: before.tasks[0].id, at: archived.tasks[0].archivedAt ?? Date())  // same archive time
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

    /// `claude -p` run from the leaf's claude inherits HANGAR_* and reports with its own session id.
    @Test func nestedClaudeEventsIgnored() {
        let app = makeApp([.claude])
        let id = leaf(app, 0).id
        var transitions: [Transition] = []
        app.onTransition = { transitions.append($0) }
        event(app, tab: 0, .sessionStart, session: "main", source: "startup")
        event(app, tab: 0, .prompt, session: "main")
        let before = transitions.count
        event(app, tab: 0, .sessionStart, session: "nested", source: "startup")
        event(app, tab: 0, .notification, session: "nested", type: "permission_prompt", message: "nested asks")
        event(app, tab: 0, .stop, session: "nested")
        #expect(app.state(ofLeaf: id) == .working)
        #expect(leaf(app, 0).agentSessionId == "main")
        #expect(app.statuses.status(id).sessionId == "main")
        #expect(app.statuses.status(id).attention == nil)
        #expect(transitions.count == before)
        event(app, tab: 0, .stop, session: "main")
        #expect(app.state(ofLeaf: id) == .done)
    }

    @Test func clearSwitchesSession() {
        let app = makeApp([.claude])
        event(app, tab: 0, .sessionStart, session: "main", source: "startup")
        event(app, tab: 0, .sessionStart, session: "after-clear", source: "clear")
        #expect(leaf(app, 0).agentSessionId == "after-clear")
        event(app, tab: 0, .prompt, session: "after-clear")
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .working)
        // ↩ relaunch: the next launch's first id is taken even from a plain startup.
        app.signal(.relaunched, leaf: leaf(app, 0).id)
        event(app, tab: 0, .sessionStart, session: "fresh", source: "startup")
        #expect(leaf(app, 0).agentSessionId == "fresh")
    }

    @Test func codexNotifyNotFilteredBySession() {
        let app = makeApp([.codex])
        event(app, tab: 0, .codexNotify, session: "t1")
        event(app, tab: 0, .codexNotify, session: "t2")
        #expect(leaf(app, 0).agentSessionId == "t2")
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .done)
    }

    @Test func otherAgentSessionIdsIgnoredOnTheBoard() {
        let app = makeApp([.claude, .codex])
        event(app, tab: 0, .sessionStart, session: "main", source: "startup")
        event(app, tab: 0, .prompt, session: "main")
        // `codex` run in the claude tab's shell.
        event(app, tab: 0, .codexNotify, session: "thread")
        event(app, tab: 0, .stop, session: "main")
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .done)
        #expect(app.statuses.status(leaf(app, 0).id).sessionId == "main")
        // claude run in the codex tab.
        event(app, tab: 1, .sessionStart, session: "c1", source: "startup")
        #expect(app.statuses.status(leaf(app, 1).id).sessionId == nil)
        event(app, tab: 1, .codexNotify, session: "t1")
        #expect(app.statuses.status(leaf(app, 1).id).sessionId == "t1")
    }

    /// A repeated identical event (statusline ticks, duplicate hooks) must not invalidate observers.
    @Test func repeatedEventDoesNotWrite() {
        let app = makeApp([.claude])
        let t = Date(timeIntervalSince1970: 1_000_000)
        app.clock = { t }
        let usage = ControlMessage.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 10, resetsAt: nil)]))
        event(app, tab: 0, .prompt, session: "s1")
        app.handle(usage)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking {
            _ = app.statuses
            _ = app.usageClock
        } onChange: { flag.fired = true }
        event(app, tab: 0, .prompt, session: "s1")
        app.signal(.focused, leaf: leaf(app, 0).id)
        app.handle(usage)
        #expect(!flag.fired)
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
        #expect(app.statuses.status(id).attention?.text == "m1")
        event(app, tab: 0, .prompt)
        #expect(app.statuses.status(id).attention == nil)
        event(app, tab: 0, .notification, type: "permission_prompt", message: "m2")
        event(app, tab: 0, .notification, type: "permission_prompt")
        #expect(app.statuses.status(id).attention?.text == nil)
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
        app.signal(.desktopNotification(), leaf: leaf(app, 0).id)
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

    /// The window status bar counts what the rows show: agents on a full limit are «на лимите», neither working nor errors.
    @Test func statusBarCountsTheLimitApart() {
        let app = makeApp([.claude, .claude, .codex])
        app.perform { $0.selectedTaskId = $0.tasks[0].id }
        for n in 0...2 { event(app, tab: n, .prompt) }
        app.handle(.usage(UsageMessage(agent: "claude", windows: [WireWindow(name: "five_hour", usedPercent: 100, resetsAt: nil)])))
        #expect(app.usage.level(.claude, now: app.usageClock) == .full)
        #expect(app.displayState(ofLeaf: leaf(app, 1).id, kind: .claude) == .limit)
        #expect(app.statusBar.counts == StatusCounts(working: 1, limited: 2))
    }

    /// StopFailure (rate_limit) is «лимит»; a crashed agent stays an error.
    @Test func stopFailureIsTheLimitACrashIsAnError() {
        let app = makeApp([.claude, .claude])
        event(app, tab: 0, .stopFailure)
        #expect(app.state(ofLeaf: leaf(app, 0).id) == .limit)
        #expect(app.displayState(ofLeaf: leaf(app, 0).id, kind: .claude) == .limit)
        app.signal(.exited(code: 1), leaf: leaf(app, 1).id)
        #expect(app.state(ofLeaf: leaf(app, 1).id) == .failed)
    }

    /// The limit is over (its reset passed): the leaf that stopped on it is no longer «лимит».
    @Test func passedLimitLeavesTheStoppedLeafIdle() {
        let app = makeApp([.claude])
        let t = Date(timeIntervalSince1970: 1_000_000)
        var now = t
        app.clock = { now }
        _ = app.usage.update(.claude, windows: [UsageWindow(kind: .session, usedPercent: 100, resetsAt: t.addingTimeInterval(60), updatedAt: t)], plan: nil, now: t)
        event(app, tab: 0, .stopFailure)
        #expect(app.displayState(ofLeaf: leaf(app, 0).id, kind: .claude) == .limit)
        #expect(app.sessionStatus(of: app.state.tasks[0]).head == L10n.limitUntil(resetClock(t.addingTimeInterval(60), now: t, calendar: .current)))
        now = t.addingTimeInterval(120)
        app.refreshUsageClock()
        #expect(app.displayState(ofLeaf: leaf(app, 0).id, kind: .claude) == .idle)
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
        for n in 0...2 { event(app, tab: n, .prompt) }
        _ = app.usage.markLimitReached(.claude, now: Date())
        #expect(app.displayState(ofLeaf: leaf(app, 0).id, kind: .claude) == .limit)
        #expect(app.displayState(of: app.state.tasks[0].tabs[0]) == .limit)
        #expect(app.displayState(ofLeaf: leaf(app, 1).id, kind: .codex) == .working)
        #expect(app.displayState(ofLeaf: leaf(app, 2).id, kind: .shell) == .working)
        #expect(app.displayState(of: app.state.tasks[0]) == .limit)
    }

    @Test func displayStateCoversDrawerLeaf() {
        let app = makeApp([.shell], drawer: true)
        let d = app.state.tasks[0].drawer.leaf!.id
        app.handle(.event(EventMessage(tab: d, leaf: d, kind: .prompt)))
        #expect(app.displayState(of: app.state.tasks[0]) == .working)
    }

    @Test func limitExpiryRestoresDot() {
        let app = makeApp([.claude])
        let t = Date(timeIntervalSince1970: 1_000_000)
        _ = app.usage.update(.claude, windows: [UsageWindow(kind: .session, usedPercent: 50, resetsAt: t.addingTimeInterval(60), updatedAt: t)], plan: nil, now: t)
        event(app, tab: 0, .prompt)
        _ = app.usage.markLimitReached(.claude, now: t)
        let tab = app.state.tasks[0].tabs[0]
        app.usageClock = t
        #expect(app.displayState(of: tab) == .limit)
        app.usageClock = t.addingTimeInterval(120)
        #expect(app.displayState(of: tab) == .working)
    }

    @MainActor @Test func statusLabelsLocalized() {
        L10n.language = .en
        defer { L10n.language = .system }
        #expect(L10n.statusLabel(.waiting) == "waiting for you")
        #expect(L10n.statusLabel(.failed) == "error")
        #expect(L10n.rowWithStatus("fix-auth", .working) == "fix-auth, working")
        L10n.language = .ru
        #expect(L10n.rowWithStatus("fix-auth", .waiting) == "fix-auth, ждёт ответа")
        #expect(Set(AgentState.allCases.map { L10n.statusLabel($0) }).count == 6)
    }

    @Test func showsDotRules() {
        let app = makeApp([.shell, .shell, .claude])
        let tabs = app.state.tasks[0].tabs
        #expect(!app.showsDot(tabs[0], state: .idle))
        #expect(app.showsDot(tabs[1], state: .working))
        #expect(app.showsDot(tabs[2], state: .idle))
    }

    @Test func quitConfirmationText() {
        defer { L10n.language = .system }
        #expect(quitConfirmation(working: 0) == nil)
        L10n.language = .ru
        #expect(quitConfirmation(working: 2)?.message == "Работают агенты: 2. Выйти?")
        #expect(quitConfirmation(working: 2)?.info == "Их процессы будут завершены.")
        L10n.language = .en
        #expect(quitConfirmation(working: 2)?.message == "Agents working: 2. Quit?")
        #expect(quitConfirmation(working: 2)?.info == "Their processes will be terminated.")
    }

    @Test func quitDecisionOrder() {
        #expect(quitDecision(creating: false, working: 0, confirmed: false, asking: false, forced: false) == .terminateNow)
        #expect(quitDecision(creating: false, working: 3, confirmed: false, asking: false, forced: false) == .ask(3))
        #expect(quitDecision(creating: false, working: 3, confirmed: true, asking: false, forced: false) == .terminateNow)
        #expect(quitDecision(creating: true, working: 3, confirmed: false, asking: false, forced: false) == .cancelCreating)
        #expect(quitDecision(creating: true, working: 0, confirmed: true, asking: false, forced: false) == .cancelCreating)
    }

    /// A second ⌘Q / close while the confirm sheet is up is refused, never a second sheet or a pending reply.
    @Test func quitWhileAskingIsRefused() {
        #expect(quitDecision(creating: false, working: 3, confirmed: false, asking: true, forced: false) == .alreadyAsking)
        #expect(quitDecision(creating: true, working: 3, confirmed: false, asking: true, forced: false) == .cancelCreating)
        #expect(quitDecision(creating: false, working: 3, confirmed: false, asking: true, forced: true) == .terminateNow)
        #expect(quitDecision(creating: false, working: 0, confirmed: false, asking: true, forced: false) == .terminateNow)
    }

    /// Logout/shutdown and SIGTERM quit at once: no confirm sheet, not even for a worktree being created.
    @Test func forcedQuitNeverAsks() {
        #expect(quitDecision(creating: false, working: 3, confirmed: false, asking: false, forced: true) == .terminateNow)
        #expect(quitDecision(creating: true, working: 3, confirmed: false, asking: true, forced: true) == .terminateNow)
        #expect(isForcedQuit(sigterm: true, reason: nil))
        #expect(isForcedQuit(sigterm: false, reason: OSType(kAEShutDown)))
        #expect(!isForcedQuit(sigterm: false, reason: OSType(kAEQuitAll)))
        #expect(!isForcedQuit(sigterm: false, reason: nil))
        #expect(isSystemShutdown(reason: OSType(kAELogOut)))
        #expect(isSystemShutdown(reason: OSType(kAEReallyLogOut)))
        #expect(isSystemShutdown(reason: OSType(kAERestart)))
        #expect(isSystemShutdown(reason: OSType(kAEShowRestartDialog)))
        #expect(isSystemShutdown(reason: OSType(kAEShutDown)))
        #expect(isSystemShutdown(reason: OSType(kAEShowShutdownDialog)))
        #expect(!isSystemShutdown(reason: OSType(kAEQuitAll)))
        #expect(!isSystemShutdown(reason: nil))
    }

    /// Dock badge = leaves needing the user (permission, question, failed), set only when the number changes;
    /// attention once per new request.
    @Test func dockBadgeCountsAttentionLeaves() throws {
        let app = makeApp([.claude, .claude])
        app.perform { s in
            let t = s.addTask(projectId: s.projects[0].id, name: "u")
            s.addTab(taskId: t, kind: .claude)
        }
        var labels: [String] = [], attention = 0
        app.onDockBadge = { labels.append($0) }
        app.requestAttention = { attention += 1 }
        func wait(_ task: Int, _ tab: Int) {
            let t = app.state.tasks[task].tabs[tab]
            app.handle(.event(EventMessage(tab: t.id, leaf: t.root.leaves[0].id, kind: .notification, notificationType: "permission_prompt")))
        }
        event(app, tab: 0, .prompt)
        #expect(labels.isEmpty && attention == 0)
        wait(0, 0)
        #expect(labels == ["1"] && attention == 1)
        wait(0, 1)  // same task: each leaf counts
        #expect(labels == ["1", "2"] && attention == 2)
        wait(1, 0)
        #expect(labels == ["1", "2", "3"] && attention == 3)
        app.archive(taskId: app.state.tasks[1].id)
        #expect(labels == ["1", "2", "3", "2"])
        event(app, tab: 0, .prompt)
        event(app, tab: 1, .prompt)
        #expect(labels == ["1", "2", "3", "2", "1", ""])

        try app.setConfig("dock_badge", flag: false) { $0.dockBadge = false }
        wait(0, 0)
        #expect(labels.last == "" && attention == 3)
        try app.setConfig("dock_badge", flag: true) { $0.dockBadge = true }
        #expect(labels.last == "1")
        #expect(dockBadgeLabel(count: 0, enabled: true) == "")
        #expect(dockBadgeLabel(count: 3, enabled: true) == "3")
        #expect(dockBadgeLabel(count: 3, enabled: false) == "")
    }

    @Test func keepAwakeFollowsStatuses() throws {
        let app = makeApp([.claude])
        final class Log: @unchecked Sendable { var created: [String] = []; var released: [UInt32] = []; var delays: [Duration] = [] }
        let log = Log()
        app.keepAwake = KeepAwake(
            assertions: PowerAssertions(create: { log.created.append($0); return 7 }, rename: { _, _ in true },
                                        release: { log.released.append($0) }),
            schedule: { d, _ in log.delays.append(d); return {} })
        event(app, tab: 0, .prompt)
        #expect(log.created == ["Hangar: 1 agent working"] && app.keepAwake.held)
        event(app, tab: 0, .stop)
        #expect(log.delays == [.seconds(120)] && log.released.isEmpty)
        try app.setConfig("keep_awake", flag: false) { $0.keepAwake = false }
        #expect(log.released == [7] && !app.keepAwake.held)
    }
}
