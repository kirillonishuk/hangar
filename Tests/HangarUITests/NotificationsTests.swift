import AgentStatus
import ControlServer
import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct NotificationsTests {
    struct Fixture {
        var app: AppState
        var task: UUID
        var tab0: Tab
        var tab1: Tab
        var other: UUID  // second task
        var otherTab: Tab
        var drawerLeaf: UUID
    }

    private func make(notifications: Bool = true) -> Fixture {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop-api", path: "/tmp")
        let t = s.addTask(projectId: p, name: "fix-auth")
        s.addTab(taskId: t, kind: .claude)
        s.addTab(taskId: t, kind: .codex)
        s.toggleDrawer(taskId: t)  // creates the shell leaf, visible
        s.toggleDrawer(taskId: t)  // collapsed
        let o = s.addTask(projectId: p, name: "other")
        s.addTab(taskId: o, kind: .claude)
        s.addTab(taskId: o, kind: .claude)
        s.select(taskId: t)
        let task = s.tasks.first { $0.id == t }!
        s.tasks[s.tasks.firstIndex { $0.id == t }!].activeTabId = task.tabs[0].id
        var config = HangarConfig()
        config.notifications = notifications
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-notif-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        let ot = app.state.tasks.first { $0.id == o }!
        return Fixture(app: app, task: t, tab0: task.tabs[0], tab1: task.tabs[1], other: o, otherTab: ot.tabs[1],
                       drawerLeaf: task.drawer.leaf!.id)
    }

    private func tr(_ leaf: Leaf, _ from: AgentState, _ to: AgentState) -> Transition { Transition(leaf: leaf.id, from: from, to: to) }

    @Test func noticeOnlyForWaitingAndDoneWhenHidden() {
        let f = make()
        let leaf = f.tab0.root.leaves[0]
        #expect(notice(for: tr(leaf, .idle, .working), app: f.app, leafVisible: false) == nil)
        #expect(notice(for: tr(leaf, .working, .waiting), app: f.app, leafVisible: false) != nil)
        #expect(notice(for: tr(leaf, .working, .waiting), app: f.app, leafVisible: true) == nil)
        #expect(notice(for: tr(leaf, .working, .done), app: f.app, leafVisible: false) != nil)
        #expect(notice(for: tr(leaf, .working, .failed), app: f.app, leafVisible: false) == nil)
        #expect(notice(for: tr(leaf, .working, .idle), app: f.app, leafVisible: false) == nil)
        #expect(notice(for: tr(Leaf(kind: .claude, cwd: "/"), .working, .done), app: f.app, leafVisible: false) == nil)
        let off = make(notifications: false)
        #expect(notice(for: tr(off.tab0.root.leaves[0], .working, .waiting), app: off.app, leafVisible: false) == nil)
    }

    @Test func noticeText() {
        defer { L10n.language = .system }
        let f = make()
        let leaf = f.tab0.root.leaves[0]
        L10n.language = .ru
        f.app.lastNotificationMessage[leaf.id] = "Needs permission"
        let n = notice(for: tr(leaf, .working, .waiting), app: f.app, leafVisible: false)
        #expect(n == AgentNotice(id: leaf.id.uuidString, title: "claude ждёт ответа", subtitle: "shop-api › fix-auth",
                                 body: "Needs permission", leaf: leaf.id))
        L10n.language = .en
        #expect(notice(for: tr(leaf, .working, .waiting), app: f.app, leafVisible: false)?.title == "claude is waiting for you")
        #expect(notice(for: tr(leaf, .working, .done), app: f.app, leafVisible: false)?.title == "claude finished")
        // No message: the tab label.
        f.app.lastNotificationMessage[leaf.id] = nil
        #expect(notice(for: tr(leaf, .working, .done), app: f.app, leafVisible: false)?.body == f.app.tabLabel(f.tab0))
        // Long message is truncated.
        f.app.lastNotificationMessage[leaf.id] = String(repeating: "x", count: 500)
        #expect(notice(for: tr(leaf, .working, .done), app: f.app, leafVisible: false)!.body.count <= 200)
        // Shell: the leaf title is the "agent".
        let shell = f.app.state.tasks.first { $0.id == f.task }!.drawer.leaf!
        f.app.setTitle("make", leafId: shell.id)
        #expect(notice(for: tr(shell, .working, .done), app: f.app, leafVisible: false)?.title == "make finished")
    }

    @Test func leafVisibleRules() {
        let f = make()
        let a = f.tab0.root.leaves[0].id
        let b = f.tab1.root.leaves[0].id
        #expect(leafVisible(a, app: f.app, windowVisible: true))
        #expect(!leafVisible(a, app: f.app, windowVisible: false))
        #expect(!leafVisible(b, app: f.app, windowVisible: true))
        #expect(!leafVisible(f.otherTab.root.leaves[0].id, app: f.app, windowVisible: true))
        #expect(!leafVisible(f.drawerLeaf, app: f.app, windowVisible: true))
        f.app.perform { $0.toggleDrawer(taskId: f.task) }
        #expect(leafVisible(f.drawerLeaf, app: f.app, windowVisible: true))
        #expect(!leafVisible(UUID(), app: f.app, windowVisible: true))
    }

    @Test func revealSelectsTaskTabAndDrawer() {
        let f = make()
        let leaf = f.otherTab.root.leaves[0].id
        f.app.reveal(leafId: leaf)
        #expect(f.app.state.selectedTaskId == f.other)
        let o = f.app.state.tasks.first { $0.id == f.other }!
        #expect(o.activeTabId == f.otherTab.id)
        #expect(o.tabs.first { $0.id == f.otherTab.id }?.focusedLeafId == leaf)
        f.app.reveal(leafId: f.drawerLeaf)
        #expect(f.app.state.selectedTaskId == f.task)
        #expect(f.app.state.tasks.first { $0.id == f.task }?.drawer.visible == true)
        // Archived task: ignored.
        f.app.archive(taskId: f.other)
        let before = f.app.state
        f.app.reveal(leafId: leaf)
        #expect(f.app.state == before)
    }

    @Test func eventMessageReachesNoticeBody() {
        let f = make()
        let tab = f.tab1  // not the active tab: hidden
        let leaf = tab.root.leaves[0]
        var notices: [AgentNotice] = []
        f.app.onTransition = { if let n = notice(for: $0, app: f.app, leafVisible: false) { notices.append(n) } }
        func send(_ kind: HookKind, type: String? = nil, message: String? = nil) {
            f.app.handle(.event(EventMessage(tab: tab.id, leaf: leaf.id, kind: kind, session: nil, notificationType: type, message: message)))
        }
        send(.prompt)
        send(.notification, type: "permission_prompt", message: "needs permission to run X")
        #expect(notices.last?.body.contains("needs permission to run X") == true)
        send(.prompt)
        send(.stop)
        #expect(notices.count == 2)
        #expect(notices.last?.body.contains("needs permission to run X") == false)
    }
}
