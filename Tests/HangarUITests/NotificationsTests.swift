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
        var tab0: Tab  // claude
        var tab1: Tab  // codex
        var other: UUID  // second task
        var otherTab: Tab
        var drawerLeaf: UUID
    }

    private func make(_ config: HangarConfig = HangarConfig(), host: String? = nil) -> Fixture {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop-api", path: "/tmp")
        if let host { s.projects[0].location = .ssh(host: host, path: "/srv/shop") }
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-notif-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        app.codexRead = nil
        app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running }, send: { _, _, _ in }, read: { _ in nil })
        let ot = app.state.tasks.first { $0.id == o }!
        return Fixture(app: app, task: t, tab0: task.tabs[0], tab1: task.tabs[1], other: o, otherTab: ot.tabs[1],
                       drawerLeaf: task.drawer.leaf!.id)
    }

    private func config(_ edit: (inout HangarConfig) -> Void) -> HangarConfig {
        var c = HangarConfig()
        edit(&c)
        return c
    }

    private func send(_ f: Fixture, _ tab: Tab, _ kind: HookKind, type: String? = nil, message: String? = nil,
                      tool: String? = nil, command: String? = nil, error: String? = nil) {
        f.app.handle(.event(EventMessage(tab: tab.id, leaf: tab.root.leaves[0].id, kind: kind, notificationType: type,
                                         message: message, tool: tool, command: command, error: error)))
    }

    private func permission(_ f: Fixture, tool: String? = "Bash", command: String? = "ls") {
        send(f, f.tab0, .permissionRequest, tool: tool, command: command)
        send(f, f.tab0, .notification, type: "permission_prompt", message: "Claude needs your permission to use Bash")
    }

    private func item(_ f: Fixture, _ leaf: UUID) throws -> AttentionItem {
        try #require(f.app.attentionItems.first { $0.leafId == leaf })
    }

    @Test func titlesByReason() throws {
        defer { L10n.language = .system }
        let f = make()
        permission(f)
        let leaf = f.tab0.root.leaves[0].id
        L10n.language = .ru
        #expect(notice(for: try item(f, leaf), app: f.app).title == "Claude просит разрешение")
        L10n.language = .en
        #expect(notice(for: try item(f, leaf), app: f.app).title == "Claude asks for permission")
        L10n.language = .ru
        send(f, f.tab1, .codexNotify, message: "All done")
        let done = notice(for: try item(f, f.tab1.root.leaves[0].id), app: f.app)
        #expect(done.title == L10n.agentDone("Codex"))
        #expect(done.title == "Codex закончил")
        #expect(done.id == f.tab1.root.leaves[0].id.uuidString)
        #expect(done.thread == f.task.uuidString)
        #expect(done.category == .open)
        send(f, f.tab0, .stopFailure, error: "server_error")
        #expect(notice(for: try item(f, leaf), app: f.app).title == "Claude: ошибка")
        #expect(notice(for: try item(f, leaf), app: f.app).category == .open)
        send(f, f.tab0, .stopFailure, error: "rate_limit")
        #expect(notice(for: try item(f, leaf), app: f.app).title == "Claude упёрся в лимит")
        #expect(notice(for: try item(f, leaf), app: f.app).category == .limit)
        // A question from codex (OSC): Reply; Claude's own question: only Open (S5).
        f.app.signal(.desktopNotification(text: "Run tests?"), leaf: f.tab1.root.leaves[0].id)
        let q = notice(for: try item(f, f.tab1.root.leaves[0].id), app: f.app)
        #expect(q.title == "Codex спрашивает")
        #expect(q.category == .questionReply)
        #expect(q.body == "Run tests?")
        send(f, f.tab0, .notification, type: "elicitation_dialog", message: "Pick one")
        #expect(notice(for: try item(f, leaf), app: f.app).category == .open)
    }

    @Test func subtitleHasHostForRemote() throws {
        let f = make(host: "devbox")
        permission(f)
        #expect(notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app).subtitle == "shop-api › fix-auth · devbox")
        let local = make()
        permission(local)
        #expect(notice(for: try item(local, local.tab0.root.leaves[0].id), app: local.app).subtitle == "shop-api › fix-auth")
    }

    @Test func permissionBodyAndCategory() throws {
        let f = make()
        permission(f)
        let n = notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app)
        #expect(n.body == "Bash: ls")
        #expect(n.category == .permission)
        #expect(n.urgent)
        let g = make(config { $0.allowFromNotification = true })
        permission(g)
        #expect(notice(for: try item(g, g.tab0.root.leaves[0].id), app: g.app).category == .permissionAllow)
        // No command known: nothing to allow blindly.
        let h = make(config { $0.allowFromNotification = true })
        permission(h, command: nil)
        let n2 = notice(for: try item(h, h.tab0.root.leaves[0].id), app: h.app)
        #expect(n2.category == .permission)
        #expect(n2.body == "Claude needs your permission to use Bash")
    }

    @Test func noticeBodyStripsControls() throws {
        let f = make()
        send(f, f.tab0, .stop, message: "a\u{1b}[31mb\nc")
        let body = notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app).body
        #expect(!body.contains("\u{1b}"))
        #expect(!body.contains("\n"))
        #expect(body == "a [31mb c")
        send(f, f.tab0, .prompt)
        send(f, f.tab0, .stop, message: String(repeating: "x", count: 300))
        let long = notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app).body
        #expect(long.count == 160)
        #expect(long.hasSuffix("…"))
        // No text: the tab label.
        send(f, f.tab0, .prompt)
        send(f, f.tab0, .stop)
        #expect(notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app).body == f.app.tabLabel(f.tab0))
    }

    @Test func soundAndUrgency() throws {
        let f = make()
        send(f, f.tab0, .stop, message: "ok")
        let done = notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app)
        #expect(done.sound == nil)
        #expect(!done.urgent)
        permission(f)
        let p = notice(for: try item(f, f.tab0.root.leaves[0].id), app: f.app)
        #expect(p.urgent)
        #expect(p.sound == "default")
        let g = make(config { $0.sounds["permission"] = "" ; $0.sounds["done"] = "Glass" })
        permission(g)
        #expect(notice(for: try item(g, g.tab0.root.leaves[0].id), app: g.app).sound == nil)
        send(g, g.tab0, .stop, message: "ok")
        #expect(notice(for: try item(g, g.tab0.root.leaves[0].id), app: g.app).sound == "Glass")
    }

    @Test func staleRequestKeyOnlyOpens() throws {
        let f = make(config { $0.allowFromNotification = true })
        permission(f)
        let leaf = f.tab0.root.leaves[0].id
        let key = try item(f, leaf).attention.requestKey
        #expect(f.app.notificationAction(leaf: leaf, requestKey: UUID(), .allow) == .reveal)
        #expect(f.app.notificationAction(leaf: leaf, requestKey: nil, .allow) == .reveal)
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .allow) == .send(text: nil, keys: [.enter]))
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .open) == .reveal)
        #expect(f.app.notificationAction(leaf: nil, requestKey: nil, .limits) == .showLimits)
        // Leaf not running: nothing typed.
        f.app.terminals = TerminalAccess(start: { _ in }, state: { _ in .exited }, send: { _, _, _ in }, read: { _ in nil })
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .allow) == .reveal)
        // Setting off: only Open.
        let g = make()
        permission(g)
        let gLeaf = g.tab0.root.leaves[0].id
        #expect(g.app.notificationAction(leaf: gLeaf, requestKey: try item(g, gLeaf).attention.requestKey, .allow) == .reveal)
        // The request moved on: the old key opens.
        let h = make(config { $0.allowFromNotification = true })
        permission(h)
        let hLeaf = h.tab0.root.leaves[0].id
        let old = try item(h, hLeaf).attention.requestKey
        send(h, h.tab0, .prompt)
        permission(h, command: "rm -rf build")
        #expect(h.app.notificationAction(leaf: hLeaf, requestKey: old, .allow) == .reveal)
        // Permission without a known command: nothing approved blindly.
        let k = make(config { $0.allowFromNotification = true })
        permission(k, command: nil)
        let kLeaf = k.tab0.root.leaves[0].id
        #expect(k.app.notificationAction(leaf: kLeaf, requestKey: try item(k, kLeaf).attention.requestKey, .allow) == .reveal)
    }

    @Test func replySanitizes() throws {
        let f = make()
        let leaf = f.tab1.root.leaves[0].id
        f.app.signal(.desktopNotification(text: "Run tests?"), leaf: leaf)
        let key = try item(f, leaf).attention.requestKey
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .reply("да\nну")) == .send(text: "да ну", keys: [.enter]))
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .reply("a\u{1b}[2Jb")) == .send(text: "a[2Jb", keys: [.enter]))
        #expect(f.app.notificationAction(leaf: leaf, requestKey: key, .reply("  ")) == .reveal)
        #expect(f.app.notificationAction(leaf: leaf, requestKey: UUID(), .reply("yes")) == .reveal)
        let long = f.app.notificationAction(leaf: leaf, requestKey: key, .reply(String(repeating: "y", count: 3000)))
        #expect(long == .send(text: String(repeating: "y", count: 2000), keys: [.enter]))
        // A host terminal's shell: never typed into.
        let g = make(config { $0.sshTerminalBell = true })
        let opened = try #require(g.app.openHostShell("box"))
        let hostLeaf = g.app.state.tasks.first { $0.id == opened.task }!.tabs.first { $0.id == opened.tab }!.root.leaves[0].id
        g.app.signal(.bell, leaf: hostLeaf)
        let hostItem = try item(g, hostLeaf)
        #expect(notice(for: hostItem, app: g.app).category == .open)
        #expect(g.app.notificationAction(leaf: hostLeaf, requestKey: hostItem.attention.requestKey, .reply("ls")) == .reveal)
    }

    @Test func bannerAllowedUsesPolicy() throws {
        let f = make()
        send(f, f.tab1, .codexNotify, message: "done")
        let done = try item(f, f.tab1.root.leaves[0].id)
        #expect(bannerAllowed(done, app: f.app, leafVisible: false, appActive: false))
        #expect(!bannerAllowed(done, app: f.app, leafVisible: true, appActive: false))
        f.app.setProjectNotifications(f.app.state.projects[0].id, .urgent)
        #expect(!bannerAllowed(done, app: f.app, leafVisible: false, appActive: false))
        let g = make(config { $0.notifyWhenActive = false })
        permission(g)
        let p = try item(g, g.tab0.root.leaves[0].id)
        #expect(bannerAllowed(p, app: g.app, leafVisible: false, appActive: false))
        #expect(!bannerAllowed(p, app: g.app, leafVisible: false, appActive: true))
    }

    /// A recording center: what is on screen, plus every add.
    final class Shown {
        var notices: [AgentNotice] = []
        var added: [AgentNotice] = []
    }

    private func notifier(_ shown: Shown) -> Notifier {
        var center = NoticeCenter.recorder { shown.notices = $0(shown.notices) }
        let add = center.add
        center.add = { shown.added.append($0); try await add($0) }
        // Authorization takes a turn, as the real lookup does.
        center.authorization = { await Task.yield(); return .authorized }
        return Notifier(center: center)
    }

    private func sample(_ leaf: UUID, _ title: String) -> AgentNotice {
        AgentNotice(id: leaf.uuidString, title: title, subtitle: "", body: "", leaf: leaf, category: .open, thread: nil, sound: nil,
                    urgent: false, requestKey: UUID())
    }

    @Test func removeBeforePendingPostAddsNothing() async {
        let shown = Shown()
        let n = notifier(shown)
        let leaf = UUID()
        let post = n.post(sample(leaf, "a"))
        n.remove(leaf: leaf)
        await post.value
        #expect(shown.added.isEmpty)
        #expect(shown.notices.isEmpty)
        // Two quick posts for one leaf: only the newest lands.
        let first = n.post(sample(leaf, "old"))
        let second = n.post(sample(leaf, "new"))
        await first.value
        await second.value
        #expect(shown.added.map(\.title) == ["new"])
    }

    @Test func attachPostsAndWithdraws() async throws {
        let f = make()
        let shown = Shown()
        let n = notifier(shown)
        var visible = false
        n.attach(to: f.app, leafVisible: { _ in visible }, appActive: { false })
        let leaf = f.tab1.root.leaves[0].id  // codex
        // New request out of sight: posted.
        f.app.signal(.desktopNotification(text: "Run tests?"), leaf: leaf)
        await n.lastPost?.value
        #expect(shown.notices.map(\.id) == [leaf.uuidString])
        #expect(shown.notices.first?.category == .questionReply)
        // A new request that may not be shown (leaf visible): the stale banner goes too.
        visible = true
        send(f, f.tab1, .codexNotify, message: "done")
        #expect(shown.notices.isEmpty)
        // Seen (focus): withdrawn.
        visible = false
        f.app.signal(.desktopNotification(text: "Again?"), leaf: leaf)
        await n.lastPost?.value
        #expect(shown.notices.count == 1)
        f.app.focused(leafId: leaf)
        #expect(shown.notices.isEmpty)
        // Attention gone (done dismissed): withdrawn.
        send(f, f.tab1, .codexNotify, message: "done again")
        await n.lastPost?.value
        #expect(shown.notices.first?.category == .open)
        f.app.dismissDone(leafId: leaf)
        #expect(shown.notices.isEmpty)
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
}
