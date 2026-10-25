import Foundation
import History
import Testing
@testable import HangarUI
import Workspace

/// «Сессии» (⌘Y): closed sessions, conversations by day, search, open markers, routing.
@MainActor @Suite struct SessionsModelTests {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static let iso = ISO8601DateFormatter()
    private func date(_ s: String) -> Date { Self.iso.date(from: s)! }

    // MARK: Fixtures

    /// A claude/codex config dir pair under /tmp with conversations written as the agents do.
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        var claude: URL { root.appendingPathComponent("claude") }
        var codex: URL { root.appendingPathComponent("codex") }

        func claudeConversation(id: String, cwd: String, branch: String?, at: String, prompt: String, replies: Int = 1) throws {
            let dir = claude.appendingPathComponent("projects/" + claudeProjectDirName(cwd))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = [json(["type": "user", "timestamp": at, "cwd": cwd, "gitBranch": branch ?? "", "message": ["content": prompt]])]
            for _ in 0..<replies { lines.append(json(["type": "assistant", "timestamp": at, "cwd": cwd, "message": ["content": "ok"]])) }
            try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }

        func codexConversation(id: String, cwd: String, at: String, prompt: String) throws {
            let dir = codex.appendingPathComponent("sessions/2026/10/24")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lines = [
                json(["timestamp": at, "type": "session_meta", "payload": ["id": id, "cwd": cwd, "git": ["branch": "codex-branch"]]]),
                json(["timestamp": at, "type": "event_msg", "payload": ["type": "user_message", "message": prompt]]),
                json(["timestamp": at, "type": "event_msg", "payload": ["type": "agent_message", "message": "done"]]),
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("rollout-2026-10-24T10-00-00-\(id).jsonl"),
                                                          atomically: true, encoding: .utf8)
        }

        private func json(_ o: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self)
        }
    }

    private struct World {
        let app: AppState
        let project: UUID
        let main: UUID        // live main-folder session
        let feature: UUID     // live worktree session
        let closed: UUID      // archived worktree session
        let fixture: Fixture
    }

    private func world(mainSession: Bool = true) -> World {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop", path: "/work/shop")
        let main = s.addTask(projectId: p, name: "main")
        s.addTab(taskId: main, kind: .shell)
        if !mainSession { s.tasks.removeAll { $0.id == main } }
        let feature = s.addTask(projectId: p, name: "api-cache", mode: .worktree(path: "/work/wt/api-cache", branch: "api-cache", base: "main"))
        s.addTab(taskId: feature, kind: .shell)
        let closed = s.addTask(projectId: p, name: "fix-ci-cache", mode: .worktree(path: "/work/wt/fix-ci", branch: "fix/ci-cache", base: "main"))
        s.addTab(taskId: closed, kind: .claude)
        s.addTab(taskId: closed, kind: .shell)
        s.archiveTask(id: closed, at: date("2026-10-24T18:20:00Z"))
        s.setArchivedChanges(id: closed, LineChanges(added: 12, deleted: 3))
        s.selectedTaskId = feature
        let fixture = Fixture()
        let app = AppState(state: s, store: StateStore(directory: fixture.root.appendingPathComponent("state")), config: HangarConfig(),
                           configURL: fixture.root.appendingPathComponent("c.toml"))
        app.claudeSettingsURL = fixture.claude.appendingPathComponent("settings.json")
        app.codexConfigURL = fixture.codex.appendingPathComponent("config.toml")
        return World(app: app, project: p, main: main, feature: feature, closed: closed, fixture: fixture)
    }

    private let idA = "11111111-1111-4111-8111-111111111111"
    private let idB = "22222222-2222-4222-8222-222222222222"
    private let idC = "33333333-3333-4333-8333-333333333333"
    private let idX = "44444444-4444-4444-8444-444444444444"

    /// A: feature worktree today; B: closed worktree yesterday; C: project root 3 days ago; X: codex in the root today.
    private func loaded(mainSession: Bool = true) async throws -> (World, SessionsModel) {
        let w = world(mainSession: mainSession)
        try w.fixture.claudeConversation(id: idA, cwd: "/work/wt/api-cache", branch: "api-cache", at: "2026-10-25T10:00:00Z",
                                         prompt: "добавь кэширование ответов /api/catalog", replies: 3)
        try w.fixture.claudeConversation(id: idB, cwd: "/work/wt/fix-ci", branch: "fix/ci-cache", at: "2026-10-24T18:02:00Z",
                                         prompt: "кэш зависимостей в CI падает")
        try w.fixture.claudeConversation(id: idC, cwd: "/work/shop", branch: "main", at: "2026-10-22T09:00:00Z",
                                         prompt: "объясни структуру store")
        try w.fixture.codexConversation(id: idX, cwd: "/work/shop", at: "2026-10-25T08:00:00Z", prompt: "почему редирект теряет query")
        // Another project's conversation never shows.
        try w.fixture.claudeConversation(id: "55555555-5555-4555-8555-555555555555", cwd: "/elsewhere", branch: nil,
                                         at: "2026-10-25T11:00:00Z", prompt: "чужой")
        w.app.showSessionsView()
        let m = SessionsModel(app: w.app)
        m.now = { self.date("2026-10-25T12:00:00Z") }
        m.calendar = Self.utc
        await m.reload()
        return (w, m)
    }

    // MARK: Day grouping

    @Test func groupsConversationsByDayNewestFirst() async throws {
        let (_, m) = try await loaded()
        #expect(m.load == .loaded)
        let days = m.days
        #expect(days.map(\.day) == [.today, .yesterday, .date(date("2026-10-22T00:00:00Z"))])
        #expect(days[0].rows.map(\.conversation.id) == [idA, idX])
        #expect(days[1].rows.map(\.conversation.id) == [idB])
        #expect(days[2].rows.map(\.conversation.id) == [idC])
        #expect(days[0].rows[0].conversation.messageCount == 4)
        #expect(m.conversationCount == 4)
    }

    @Test func historyDayBoundaries() {
        let now = date("2026-10-25T00:30:00Z")
        #expect(historyDay(date("2026-10-25T00:00:00Z"), now: now, calendar: Self.utc) == .today)
        #expect(historyDay(date("2026-10-24T23:59:00Z"), now: now, calendar: Self.utc) == .yesterday)
        #expect(historyDay(date("2026-10-23T23:59:00Z"), now: now, calendar: Self.utc) == .date(date("2026-10-23T00:00:00Z")))
    }

    // MARK: Closed sessions

    @Test func closedSessionsCarryTheirDetails() async throws {
        let (w, m) = try await loaded()
        let row = try #require(m.closedRows.first)
        #expect(m.closedRows.count == 1)
        #expect(row.id == w.closed && row.name == "fix-ci-cache" && row.branch == "fix/ci-cache")
        #expect(row.closedAt == date("2026-10-24T18:20:00Z"))
        #expect(row.changes == LineChanges(added: 12, deleted: 3))
        #expect(row.tabLeaves == [1, 1])
    }

    @Test func closedSessionsNewestFirst() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/p")
        let old = s.addTask(projectId: p, name: "old")
        let new = s.addTask(projectId: p, name: "new")
        let legacy = s.addTask(projectId: p, name: "legacy")
        s.archiveTask(id: old, at: date("2026-10-01T00:00:00Z"))
        s.archiveTask(id: new, at: date("2026-10-20T00:00:00Z"))
        s.archiveTask(id: legacy)
        if let i = s.tasks.firstIndex(where: { $0.id == legacy }) { s.tasks[i].archivedAt = nil }  // closed before this was recorded
        #expect(closedSessionRows(s.tasks, projectId: p).map(\.name) == ["new", "old", "legacy"])
    }

    @Test func archiveTimeIsKeptUntilRestoreAndOldStateDecodes() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/p")
        let t = s.addTask(projectId: p, name: "t")
        s.archiveTask(id: t, at: date("2026-10-20T00:00:00Z"))
        s.setArchivedChanges(id: t, LineChanges(added: 1, deleted: 2))
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(back.tasks[0].archivedAt == date("2026-10-20T00:00:00Z") && back.tasks[0].archivedChanges == LineChanges(added: 1, deleted: 2))
        s.restoreTask(id: t)
        #expect(s.tasks[0].archivedAt == nil && s.tasks[0].archivedChanges == nil)
        s.setArchivedChanges(id: t, LineChanges(added: 1, deleted: 1))  // only a closed session takes it
        #expect(s.tasks[0].archivedChanges == nil)
    }

    // MARK: Search

    @Test func searchFiltersBothGroups() async throws {
        let (_, m) = try await loaded()
        m.query = "кэш"
        #expect(m.closedRows.isEmpty)
        #expect(m.days.flatMap(\.rows).map(\.conversation.id) == [idA, idB])  // by title
        m.query = "ci-cache"
        #expect(m.closedRows.map(\.name) == ["fix-ci-cache"])  // by name
        #expect(m.days.flatMap(\.rows).map(\.conversation.id) == [idB])  // by branch
        m.query = "STORE объясни"  // every word, any case
        #expect(m.closedRows.isEmpty)
        #expect(m.days.flatMap(\.rows).map(\.conversation.id) == [idC])
        m.query = "  "
        #expect(m.days.flatMap(\.rows).count == 4)
    }

    @Test func agentFilterKeepsClosedSessions() async throws {
        let (_, m) = try await loaded()
        m.agent = .codex
        #expect(m.days.flatMap(\.rows).map(\.conversation.id) == [idX])
        #expect(m.closedRows.count == 1)
    }

    // MARK: Open markers and routing

    @Test func placesAndRouting() async throws {
        let (w, m) = try await loaded()
        func row(_ id: String) throws -> ConversationRow { try #require(m.days.flatMap(\.rows).first { $0.conversation.id == id }) }
        #expect(try row(idA).place == .session(task: w.feature, name: "api-cache"))
        #expect(try row(idB).place == .closed(task: w.closed, name: "fix-ci-cache"))
        #expect(try row(idC).place == .session(task: w.main, name: "main"))
        #expect(m.action(for: try row(idA)) == .open(try row(idA).conversation, task: w.feature))
        #expect(m.action(for: try row(idB)) == .restore(w.closed))
        #expect(m.closedAction(w.closed) == .restore(w.closed))
    }

    @Test func rootConversationWithoutMainSessionOpensANewOne() async throws {
        let (w, m) = try await loaded(mainSession: false)
        let row = try #require(m.days.flatMap(\.rows).first { $0.conversation.id == idC })
        #expect(row.place == .none)
        #expect(m.action(for: row) == .openInNewSession(row.conversation, project: w.project))
        await m.perform(m.action(for: row), ctx: ActionContext(app: w.app))
        let task = try #require(w.app.selectedTask)
        #expect(task.mode == .mainFolder && task.projectId == w.project && task.name == "объясни структуру store")
        #expect(task.tabs.last?.root.leaves.first?.agentSessionId == idC)
        #expect(!w.app.sessionsViewVisible)
    }

    @Test func openMarkersFollowLiveTabs() async throws {
        let (w, m) = try await loaded()
        let before = try #require(m.days.flatMap(\.rows).first { $0.conversation.id == idA })
        #expect(!before.isOpen)
        await m.perform(m.action(for: before), ctx: ActionContext(app: w.app))
        // Opened in its own session, as a resumed tab; the view gives way to it.
        let task = try #require(w.app.selectedTask)
        #expect(task.id == w.feature && task.tabs.count == 2)
        let tab = try #require(task.tabs.last)
        #expect(tab.root.leaves.first?.agentSessionId == idA && task.activeTabId == tab.id)
        #expect(!w.app.sessionsViewVisible)
        // Back in «Сессии» without a rescan: the marker is merged from the live tabs.
        w.app.showSessionsView()
        let after = try #require(m.days.flatMap(\.rows).first { $0.conversation.id == idA })
        #expect(after.isOpen && after.place == .open(task: w.feature, tab: tab.id, name: "api-cache"))
        #expect(m.action(for: after) == .focus(task: w.feature, tab: tab.id))
        // Closing that tab drops the marker even though the scan said open.
        w.app.perform { $0.closeTab(taskId: w.feature, tabId: tab.id) }
        await m.reload()
        let closedTab = try #require(m.days.flatMap(\.rows).first { $0.conversation.id == idA })
        #expect(!closedTab.isOpen)
    }

    @Test func focusSelectsTheTab() async throws {
        let (w, m) = try await loaded()
        let first = try #require(w.app.state.tasks.first { $0.id == w.main }?.tabs.first)
        await m.perform(.focus(task: w.main, tab: first.id), ctx: ActionContext(app: w.app))
        #expect(w.app.selectedTask?.id == w.main && w.app.selectedTask?.activeTabId == first.id)
        #expect(!w.app.sessionsViewVisible)
    }

    @Test func restoreBringsTheClosedSessionBackWithItsTabs() async throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/p")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .claude)
        s.addTab(taskId: t, kind: .shell)
        s.archiveTask(id: t)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.showSessionsView(projectId: p)
        let m = SessionsModel(app: app)
        await m.perform(m.closedAction(t), ctx: ActionContext(app: app))
        let task = try #require(app.selectedTask)
        #expect(task.id == t && !task.archived && task.tabs.count == 2)
        #expect(!app.sessionsViewVisible)
        #expect(m.closedRows.isEmpty)
    }

    // MARK: Showing, loading

    @Test func showAndEscReturnToTheSession() {
        let w = world()
        w.app.showSessionsView()
        #expect(w.app.sessionsViewVisible && w.app.sessionsProjectId == w.project)
        #expect(w.app.selectedTask == nil)  // the session area is the view's
        w.app.hideSessionsView()
        #expect(!w.app.sessionsViewVisible && w.app.selectedTask?.id == w.feature)
        w.app.toggleSessionsView()
        #expect(w.app.sessionsViewVisible)
        w.app.select(taskId: w.main)  // picking a session in the sidebar leaves the view
        #expect(!w.app.sessionsViewVisible)
    }

    @Test func showsWithoutAnySession() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/p")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.toggleSessionsView()
        #expect(app.sessionsProjectId == p)
        app.toggleSessionsView()
        #expect(!app.sessionsViewVisible && app.selectedTask == nil)
    }

    @Test func emptyHistoryLoadsEmpty() async {
        let w = world()
        w.app.showSessionsView()
        let m = SessionsModel(app: w.app)
        #expect(m.load == .idle)
        await m.reload()
        #expect(m.load == .loaded && m.days.isEmpty && m.conversationCount == 0)
    }

    @Test func offlineRemoteProjectSkipsTheScan() async {
        var s = WorkspaceState()
        s.projects.append(Project(name: "srv", location: .ssh(host: "devbox", path: "/srv/app")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.showSessionsView()
        let m = SessionsModel(app: app)
        await m.reload()
        #expect(m.load == .offline("devbox") && m.days.isEmpty)
    }

    @Test func foldersAreTheProjectAndItsWorktrees() {
        let w = world()
        #expect(w.app.sessionFolders(w.project) == ["/work/shop", "/work/wt/api-cache", "/work/wt/fix-ci"])
    }

    @Test func sessionsIsACommandOnCommandY() {
        #expect(shortcut(keyCode: 16, modifiers: .command) == .sessions)  // Y by keyCode: works in the ru layout (Н)
        #expect(Shortcut.sessions.label == "⌘Y")
        #expect(paletteCommands.contains(.sessions))
    }
}
