import AgentStatus
import ControlServer
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// One attention list in `AppState`: Dock, inbox and notifications read it.
@MainActor @Suite struct AttentionWiringTests {
    struct Fixture {
        var app: AppState
        var task: UUID
        var other: UUID
        /// claude, codex (task), claude, claude (other)
        var leaves: [Leaf]
        var tabs: [UUID]
    }

    private func make(_ config: HangarConfig = HangarConfig()) -> Fixture {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop-api", path: "/tmp")
        let t = s.addTask(projectId: p, name: "fix-auth")
        s.addTab(taskId: t, kind: .claude)
        s.addTab(taskId: t, kind: .codex)
        let o = s.addTask(projectId: p, name: "other")
        s.addTab(taskId: o, kind: .claude)
        s.addTab(taskId: o, kind: .claude)
        s.select(taskId: t)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-attn-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        app.codexRead = nil
        var t0 = Date(timeIntervalSince1970: 1_000_000)
        app.clock = { t0 = t0.addingTimeInterval(1); return t0 }
        let tabs = [t, o].flatMap { id in app.state.tasks.first { $0.id == id }!.tabs }
        return Fixture(app: app, task: t, other: o, leaves: tabs.map { $0.root.leaves[0] }, tabs: tabs.map(\.id))
    }

    private func event(_ f: Fixture, _ n: Int, _ kind: HookKind, type: String? = nil, message: String? = nil, error: String? = nil) {
        f.app.handle(.event(EventMessage(tab: f.tabs[n], leaf: f.leaves[n].id, kind: kind, notificationType: type,
                                         message: message, error: error)))
    }

    @Test func hookEventBecomesItem() {
        let f = make()
        event(f, 0, .notification, type: "permission_prompt", message: "Claude needs your permission to use Bash")
        let item = f.app.attentionItems.first
        #expect(item?.attention.reason == .permission)
        #expect(item?.attention.text == "Claude needs your permission to use Bash")
        #expect(item?.leafId == f.leaves[0].id)
        #expect(item?.taskId == f.task)
        #expect(item?.projectId == f.app.state.projects[0].id)
        #expect(item?.host == nil)
        #expect(item?.agent == "claude")
    }

    @Test func osctextBecomesQuestionText() {
        let f = make()
        f.app.signal(.desktopNotification(text: "Run tests?"), leaf: f.leaves[1].id)
        let item = f.app.attentionItems.first
        #expect(item?.attention.reason == .question)
        #expect(item?.attention.text == "Run tests?")
        #expect(item?.agent == "codex")
    }

    @Test func hostShellBellOnlyWhenEnabled() throws {
        let f = make()
        let opened = try #require(f.app.openHostShell("box"))
        let leaf = f.app.state.tasks.first { $0.id == opened.task }!.tabs.first { $0.id == opened.tab }!.root.leaves[0]
        f.app.signal(.bell, leaf: leaf.id)
        #expect(f.app.attentionItems.isEmpty)
        // A project's plain shell never counts, the setting or not.
        let g = make({ var c = HangarConfig(); c.sshTerminalBell = true; return c }())
        let shell = try #require(g.app.openHostShell("box"))
        let hostLeaf = g.app.state.tasks.first { $0.id == shell.task }!.tabs.first { $0.id == shell.tab }!.root.leaves[0]
        g.app.signal(.bell, leaf: hostLeaf.id)
        let item = g.app.attentionItems.first
        #expect(item?.attention.reason == .question)
        #expect(item?.host == "box")
        #expect(item?.projectId == g.app.state.hostShells[0].id)
        g.app.perform { s in
            let t = s.tasks.first { $0.id == g.task }!.id
            s.addTab(taskId: t, kind: .shell)
        }
        let projectShell = g.app.state.tasks.first { $0.id == g.task }!.tabs.last!.root.leaves[0]
        g.app.signal(.bell, leaf: projectShell.id)
        #expect(g.app.attentionItems.count == 1)
    }

    @Test func dockCountsUrgentAndFailed() throws {
        let f = make()
        var labels: [String] = []
        f.app.onDockBadge = { labels.append($0) }
        event(f, 0, .notification, type: "permission_prompt", message: "p")
        f.app.signal(.desktopNotification(text: "q"), leaf: f.leaves[1].id)
        event(f, 2, .stopFailure, error: "overloaded")
        event(f, 3, .stop, message: "done")
        #expect(f.app.attentionItems.map(\.attention.reason) == [.permission, .question, .failed, .done])
        #expect(labels.last == "3")
        try f.app.setConfig("dock_badge", flag: false) { $0.dockBadge = false }
        #expect(labels.last == "")
    }

    @Test func droppedLeavesClearAttention() {
        let f = make()
        var cleared: [UUID] = []
        f.app.onAttention = { id, a in if a == nil { cleared.append(id) } }
        for n in 0..<4 { event(f, n, .notification, type: "permission_prompt", message: "p\(n)") }
        f.app.perform { $0.closeTab(taskId: f.task, tabId: f.tabs[0]) }
        #expect(cleared == [f.leaves[0].id])
        f.app.signal(.relaunched, leaf: f.leaves[1].id)
        #expect(cleared == [f.leaves[0].id, f.leaves[1].id])
        f.app.archive(taskId: f.other)
        #expect(Set(cleared) == Set(f.leaves.map(\.id)))
        #expect(cleared.count == 4)
        #expect(f.app.attentionItems.isEmpty)
    }

    @Test func mutedStillCountsButNoBounce() {
        let f = make()
        var labels: [String] = [], bounces = 0
        f.app.onDockBadge = { labels.append($0) }
        f.app.requestAttention = { bounces += 1 }
        f.app.setMuted(taskId: f.task, true)
        #expect(f.app.state.tasks.first { $0.id == f.task }?.muted == true)
        event(f, 0, .notification, type: "permission_prompt", message: "p")
        #expect(f.app.attentionItems.count == 1)
        #expect(labels.last == "1")
        #expect(bounces == 0)
        // Not muted: a new request bounces once, its repeat does not.
        event(f, 2, .notification, type: "permission_prompt", message: "p")
        event(f, 2, .notification, type: "permission_prompt", message: "p")
        #expect(bounces == 1)
        // A project set to «выкл.» does not bounce either.
        f.app.setProjectNotifications(f.app.state.projects[0].id, .off)
        #expect(f.app.state.projects[0].notifications == .off)
        event(f, 3, .notification, type: "elicitation_dialog", message: "q")
        #expect(bounces == 1)
        #expect(labels.last == "3")
    }

    @Test func dismissAndClearDone() {
        let f = make()
        var cleared: [UUID] = []
        f.app.onAttention = { id, a in if a == nil { cleared.append(id) } }
        event(f, 0, .stop, message: "a")
        event(f, 1, .stop, message: "b")
        event(f, 2, .stop, message: "c")
        event(f, 3, .notification, type: "permission_prompt", message: "p")
        f.app.dismissDone(leafId: f.leaves[0].id)
        f.app.dismissDone(leafId: f.leaves[3].id)  // not done: stays
        #expect(cleared == [f.leaves[0].id])
        #expect(f.app.attentionItems.count == 3)
        f.app.clearDone()
        #expect(f.app.attentionItems.map(\.leafId) == [f.leaves[3].id])
        #expect(Set(cleared) == Set(f.leaves[0..<3].map(\.id)))
        #expect(f.leaves[0..<3].allSatisfy { f.app.state(ofLeaf: $0.id) == .done })
    }

    @Test func nextAttentionFromFocusedLeaf() {
        let f = make()
        event(f, 3, .stop, message: "older done")
        event(f, 2, .stop, message: "newer done")
        event(f, 0, .notification, type: "permission_prompt", message: "p")
        // Order: permission, then done newest first.
        let order = [f.leaves[0].id, f.leaves[2].id, f.leaves[3].id]
        f.app.reveal(leafId: order[0])
        #expect(f.app.nextAttentionLeaf() == order[1])
        f.app.reveal(leafId: order[1])
        #expect(f.app.nextAttentionLeaf() == order[2])
        f.app.reveal(leafId: order[2])
        #expect(f.app.nextAttentionLeaf() == order[0])
        // A focused leaf without attention: the first one.
        f.app.reveal(leafId: f.leaves[1].id)
        #expect(f.app.nextAttentionLeaf() == order[0])
    }

    @Test func focusReportsLeafSeen() {
        let f = make()
        var seen: [UUID] = []
        f.app.onLeafSeen = { seen.append($0) }
        f.app.focused(leafId: f.leaves[1].id)
        f.app.focused(leafId: f.leaves[1].id)  // already focused: still seen
        #expect(seen == [f.leaves[1].id, f.leaves[1].id])
    }
}

@Test func oscTextJoinsTitleAndBody() {
    #expect(oscNotificationText(title: "Codex", body: "Run tests?") == "Codex — Run tests?")
    #expect(oscNotificationText(title: "", body: "Run tests?") == "Run tests?")
    #expect(oscNotificationText(title: " ", body: "") == nil)
}
