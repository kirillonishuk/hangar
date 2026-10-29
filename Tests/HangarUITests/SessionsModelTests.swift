import Exec
import Foundation
import History
import Testing
import TestSupport
@testable import HangarUI
import Workspace

/// «Сессии» (⌘Y, #107): one list by project, archived sessions as rows, scope, chips, search, state words, routing.
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

    // MARK: Groups

    /// One group per project; conversations and the archived session without conversations mixed, newest first.
    @Test func groupsByProjectNewestFirst() async throws {
        let (w, m) = try await loaded()
        #expect(m.load == .loaded)
        let groups = m.groups
        #expect(groups.map(\.id) == [w.project] && groups[0].name == "shop" && groups[0].note == nil)
        #expect(groups[0].items.map(\.id) == ["claude:" + idA, "codex:" + idX, "session:" + w.closed.uuidString, "claude:" + idB, "claude:" + idC])
        #expect(groups[0].items.map(\.state) == [.history, .history, .archived, .history, .history])
        #expect(m.conversationRows.first?.conversation.messageCount == 4)
        #expect(m.conversationRows.count == 4)
    }

    /// The «где» column: ⎇ for a worktree's conversation, the folder for the project's main folder.
    @Test func rowsKnowWhereTheyWereFound() async throws {
        let (_, m) = try await loaded()
        func row(_ id: String) throws -> ConversationRow { try #require(m.conversationRows.first { $0.conversation.id == id }) }
        #expect(try row(idA).inWorktree && row(idB).inWorktree)
        #expect(try !row(idC).inWorktree && !row(idX).inWorktree)
    }

    /// More than five rows fold to five and «Показать ещё N»; a folded group shows none; ↑↓ walk the rows on screen.
    @Test func longGroupsFoldAndTheKeyboardWalksVisibleRows() async throws {
        let w = world()
        for i in 0..<7 {
            try w.fixture.claudeConversation(id: "7777777\(i)-7777-4777-8777-777777777777", cwd: "/work/shop", branch: "main",
                                             at: "2026-10-2\(i)T10:00:00Z", prompt: "задача \(i)")
        }
        w.app.showSessionsView()
        let m = SessionsModel(app: w.app)
        await m.reload()
        let g = try #require(m.groups.first)
        #expect(g.items.count == 8)  // 7 conversations and the archived session
        #expect(m.visibleItems(g).count == Theme.sessionsGroupLimit && m.hiddenCount(g) == 3)
        m.step(by: -1)
        #expect(m.selection == m.visibleItems(g).last?.id)  // up with nothing chosen: the last row
        m.step(by: 1)
        #expect(m.selection == m.visibleItems(g).last?.id)  // stays on the last visible one
        m.selection = nil
        m.step(by: 1)
        #expect(m.selection == g.items[0].id)
        #expect(m.activateSelection() == m.primaryAction(g.items[0]))
        m.expanded.insert(g.id)
        #expect(m.visibleItems(g).count == 8 && m.hiddenCount(g) == 0)
        m.toggleCollapsed(g.id)
        #expect(m.visibleItems(g).isEmpty && m.hiddenCount(g) == 0 && m.visibleList.isEmpty)
        #expect(m.activateSelection() == nil)
        m.toggleCollapsed(g.id)
        #expect(m.visibleItems(g).count == 8)
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
        #expect(row.id == w.closed && row.name == "fix-ci-cache" && row.branch == "fix/ci-cache" && row.project == w.project)
        #expect(row.archivedAt == date("2026-10-24T18:20:00Z"))
        #expect(row.tabs == 2)
        #expect(m.primaryAction(.session(row)) == .restore(w.closed) && SessionsItem.session(row).archivedTask == w.closed)
    }

    /// An archived session whose conversation is listed shows through it («в архиве», «Восстановить»), not as a second row.
    @Test func archivedSessionWithAListedConversationIsNotRepeated() async throws {
        let (w, m) = try await loaded()
        w.app.perform { s in
            let leaf = s.tasks.first { $0.id == w.closed }!.tabs[0].root.leaves[0].id
            s.setAgentSessionId(leafId: leaf, self.idB)
        }
        #expect(m.closedRows.isEmpty)
        let row = try #require(m.conversationRows.first { $0.conversation.id == idB })
        #expect(row.state == .archived && SessionsItem.conversation(row).archivedTask == w.closed)
        #expect(m.primaryAction(.conversation(row)) == .restore(w.closed))
        #expect(m.groups[0].items.count == 4)
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
        #expect(closedSessionRows(s.tasks, projects: s.projects.filter { $0.id == p }).map(\.name) == ["new", "old", "legacy"])
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

    @Test func searchFiltersEveryRow() async throws {
        let (_, m) = try await loaded()
        m.query = "кэш"
        #expect(m.closedRows.isEmpty)
        #expect(m.conversationRows.map(\.conversation.id) == [idA, idB])  // by title
        m.query = "ci-cache"
        #expect(m.closedRows.map(\.name) == ["fix-ci-cache"])  // by name
        #expect(m.conversationRows.map(\.conversation.id) == [idB])  // by branch
        m.query = "STORE объясни"  // every word, any case
        #expect(m.closedRows.isEmpty)
        #expect(m.conversationRows.map(\.conversation.id) == [idC])
        m.query = "SHOP"  // by project
        #expect(m.conversationRows.count == 4 && m.closedRows.count == 1)
        m.query = "  "
        #expect(m.conversationRows.count == 4 && !m.isFiltering)
    }

    /// Chips: multi-select, none = all; an archived session row has no agent (a chosen agent hides it) and is «в архиве».
    @Test func chipsFilterByAgentAndState() async throws {
        let (w, m) = try await loaded()
        m.toggle(HistoryAgent.codex)
        #expect(m.conversationRows.map(\.conversation.id) == [idX] && m.closedRows.isEmpty && m.isFiltering)
        m.toggle(HistoryAgent.claude)
        #expect(m.conversationRows.count == 4 && m.closedRows.isEmpty)
        m.resetChips()
        m.toggle(SessionsRowState.archived)
        #expect(m.conversationRows.isEmpty && m.closedRows.map(\.id) == [w.closed])
        m.toggle(SessionsRowState.history)
        #expect(m.conversationRows.count == 4 && m.closedRows.count == 1)
        m.toggle(SessionsRowState.archived)
        #expect(m.closedRows.isEmpty)
        m.query = "кэш"
        m.resetFilters()
        #expect(!m.isFiltering && m.query.isEmpty && m.conversationRows.count == 4 && m.closedRows.count == 1)
    }

    // MARK: Open markers and routing

    @Test func placesAndRouting() async throws {
        let (w, m) = try await loaded()
        func row(_ id: String) throws -> ConversationRow { try #require(m.conversationRows.first { $0.conversation.id == id }) }
        #expect(try row(idA).place == .session(task: w.feature, name: "api-cache"))
        #expect(try row(idB).place == .none)  // the closed session in its folder never held it
        #expect(try row(idC).place == .none)  // the main folder's session holds other conversations: a session of its own
        #expect(m.action(for: try row(idA)) == .open(try row(idA).conversation, task: w.feature))
        #expect(m.action(for: try row(idB)) == .openInNewSession(try row(idB).conversation, project: w.project))
        #expect(m.primaryAction(.conversation(try row(idA))) == m.action(for: try row(idA)))
    }

    @Test func rootConversationWithoutMainSessionOpensANewOne() async throws {
        let (w, m) = try await loaded(mainSession: false)
        let row = try #require(m.conversationRows.first { $0.conversation.id == idC })
        #expect(row.place == .none)
        #expect(m.action(for: row) == .openInNewSession(row.conversation, project: w.project))
        await m.perform(m.action(for: row), ctx: ActionContext(app: w.app))
        let task = try #require(w.app.selectedTask)
        #expect(task.mode == .mainFolder && task.projectId == w.project && task.name == "объясни структуру store")
        #expect(task.tabs.last?.root.leaves.first?.agentSessionId == idC)
        #expect(!w.app.sessionsViewVisible)
    }

    /// The launch context each leaf's surface gets when it first appears (as `TerminalArea.sync` asks, inside `perform`).
    private func recordFirstLaunches(_ app: AppState) -> () -> [UUID: LaunchContext] {
        final class Box { var contexts: [UUID: LaunchContext] = [:] }
        let box = Box()
        app.didChange = {
            for l in app.state.tasks.filter({ !$0.archived }).flatMap(\.tabs).flatMap(\.root.leaves) where box.contexts[l.id] == nil {
                box.contexts[l.id] = app.launchContext(for: l.id)
            }
        }
        return { box.contexts }
    }

    /// The owner's case: every session of the project is closed, and conversations started outside Hangar live in the
    /// main folder (on a feature branch). A click resumes exactly that conversation, on its first launch; a second
    /// conversation of the same folder gets its own resumed tab, the first one untouched. No closed session is restored.
    @Test func externalConversationsResumeThemselvesOnFirstLaunch() async throws {
        let w = world()
        w.app.perform { s in
            s.archiveTask(id: w.main, at: Date())  // a closed session of the main folder, with a fresh claude of its own
            s.addTab(taskId: w.main, kind: .claude)
            s.archiveTask(id: w.feature, at: Date())
        }
        try w.fixture.claudeConversation(id: idA, cwd: "/work/shop", branch: "fix/JS-14684", at: "2026-10-25T10:00:00Z", prompt: "JS-14684", replies: 5)
        try w.fixture.claudeConversation(id: idB, cwd: "/work/shop", branch: "feat/JS-14485", at: "2026-10-25T09:00:00Z", prompt: "JS-14485")
        let launches = recordFirstLaunches(w.app)
        w.app.showSessionsView()
        let m = SessionsModel(app: w.app)
        await m.reload()
        func row(_ id: String) throws -> ConversationRow { try #require(m.conversationRows.first { $0.conversation.id == id }) }
        func firstCommand(_ id: String) throws -> String {
            let (task, tab, leaf) = try #require(w.app.state.tasks.lazy.compactMap { t in
                t.tabs.lazy.compactMap { tab in tab.root.leaves.first { $0.agentSessionId == id }.map { (t, tab, $0) } }.first
            }.first)
            #expect(!task.archived && tab.root.leaves.count == 1)
            let mode = launchMode(for: leaf, try #require(launches()[leaf.id]))
            return agentCommand(for: leaf, agent: { $0.rawValue }, shell: "/bin/zsh", restoring: mode.restoring, initialPrompt: mode.initialPrompt)
        }
        #expect(try row(idA).place == .none)  // its folder's sessions are closed, but none of them holds it
        await m.perform(m.action(for: try row(idA)), ctx: ActionContext(app: w.app))
        #expect(try firstCommand(idA).contains("--resume \(idA)"))
        #expect(w.app.state.tasks.filter(\.archived).count == 3)  // nothing restored

        w.app.showSessionsView()
        let a = try #require(w.app.selectedTask)
        let aLeaf = try #require(a.tabs.first { $0.id == a.activeTabId }?.focusedLeafId)
        #expect(try row(idA).place == .open(task: a.id, leaf: aLeaf, name: a.name))
        #expect(m.action(for: try row(idA)) == .focus(leaf: aLeaf))
        #expect(try row(idB).place == .none)  // not into A's session: one of its own
        await m.perform(m.action(for: try row(idB)), ctx: ActionContext(app: w.app))
        #expect(try firstCommand(idB).contains("--resume \(idB)"))
        #expect(w.app.selectedTask?.id != a.id && w.app.selectedTask?.name == "JS-14485")
        #expect(w.app.state.tasks.first { $0.id == a.id }?.tabs.count == 1)  // A untouched
        let leaves = w.app.state.tasks.flatMap(\.tabs).flatMap(\.root.leaves).compactMap(\.agentSessionId)
        #expect(leaves.filter { $0 == idA }.count == 1 && leaves.filter { $0 == idB }.count == 1)
    }

    /// A closed session whose TERMINAL panel held the conversation restores it too («Восстановить»).
    @Test func closedSessionPanelOwnsItsConversation() async throws {
        let (w, m) = try await loaded()
        w.app.perform { s in
            let i = s.tasks.firstIndex { $0.id == w.closed }!
            s.tasks[i].drawer.leaf = Leaf(kind: .claude, cwd: "/work/wt/fix-ci", agentSessionId: self.idB)
        }
        let row = try #require(m.conversationRows.first { $0.conversation.id == idB })
        #expect(row.place == .closed(task: w.closed, name: "fix-ci-cache") && m.action(for: row) == .restore(w.closed))
    }

    /// A closed session is restored for a conversation only when one of its agents holds that conversation.
    @Test func closedSessionOwnsOnlyItsOwnConversations() async throws {
        let (w, m) = try await loaded()
        #expect(m.conversationRows.first { $0.conversation.id == idB }?.place == ConversationPlace.none)
        w.app.perform { s in
            let leaf = s.tasks.first { $0.id == w.closed }!.tabs[0].root.leaves[0].id
            s.setAgentSessionId(leafId: leaf, self.idB)
        }
        #expect(m.conversationRows.first { $0.conversation.id == idB }?.place == .closed(task: w.closed, name: "fix-ci-cache"))
    }

    @Test func openMarkersFollowLiveTabs() async throws {
        let (w, m) = try await loaded()
        let before = try #require(m.conversationRows.first { $0.conversation.id == idA })
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
        let after = try #require(m.conversationRows.first { $0.conversation.id == idA })
        #expect(after.isOpen && after.state == .open && after.place == .open(task: w.feature, leaf: tab.focusedLeafId, name: "api-cache"))
        #expect(m.action(for: after) == .focus(leaf: tab.focusedLeafId))
        // Closing that tab drops the marker even though the scan said open.
        w.app.perform { $0.closeTab(taskId: w.feature, tabId: tab.id) }
        await m.reload()
        let closedTab = try #require(m.conversationRows.first { $0.conversation.id == idA })
        #expect(!closedTab.isOpen)
    }

    @Test func focusSelectsTheTab() async throws {
        let (w, m) = try await loaded()
        let first = try #require(w.app.state.tasks.first { $0.id == w.main }?.tabs.first)
        w.app.select(taskId: w.feature)
        w.app.showSessionsView()
        await m.perform(.focus(leaf: first.focusedLeafId), ctx: ActionContext(app: w.app))
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
        await m.perform(.restore(t), ctx: ActionContext(app: app))
        let task = try #require(app.selectedTask)
        #expect(task.id == t && !task.archived && task.tabs.count == 2)
        #expect(!app.sessionsViewVisible)
        #expect(m.closedRows.isEmpty)
    }

    // MARK: Showing, loading

    @Test func showAndEscReturnToTheSession() {
        let w = world()
        w.app.showSessionsView()
        #expect(w.app.sessionsViewVisible && w.app.sessionsScope == .all)
        #expect(w.app.selectedTask?.id == w.feature)  // the view only overlays the session area
        w.app.hideSessionsView()
        #expect(!w.app.sessionsViewVisible && w.app.selectedTask?.id == w.feature)
        w.app.toggleSessionsView()
        #expect(w.app.sessionsViewVisible)
        w.app.select(taskId: w.main)  // picking a session in the sidebar leaves the view
        #expect(!w.app.sessionsViewVisible)
    }

    /// ⌘Y / the «Сессии» row with no project: nothing to show, so a beep instead of a silent no-op.
    @Test func noProjectBeeps() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        var beeps = 0
        app.beep = { beeps += 1 }
        app.toggleSessionsView()
        #expect(!app.sessionsViewVisible && beeps == 1)
    }

    /// The view overlays the selected session: the selection stays in state.json, so a relaunch keeps it.
    @Test func selectionSurvivesTheViewAndARelaunch() throws {
        let w = world()
        let dir = w.fixture.root.appendingPathComponent("relaunch")
        let store = StateStore(directory: dir)
        let app = AppState(state: w.app.state, store: store, config: HangarConfig(), configURL: w.fixture.root.appendingPathComponent("c.toml"))
        app.showSessionsView()
        #expect(app.sessionsViewVisible && app.state.selectedTaskId == w.feature)
        // Unrelated edits while the view is open neither close it nor drop the selection.
        app.perform { $0.renameTask(id: w.main, name: "main-2") }
        #expect(app.sessionsViewVisible && app.state.selectedTaskId == w.feature)
        try store.saveNow(app.state)
        guard case .loaded(let relaunched) = StateStore(directory: dir).load() else { Issue.record("no state"); return }
        #expect(relaunched.selectedTaskId == w.feature)
        // Picking the session that is already selected leaves the view too.
        app.select(taskId: w.feature)
        #expect(!app.sessionsViewVisible && app.selectedTask?.id == w.feature)
    }

    @Test func showsWithoutAnySession() {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/p")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.toggleSessionsView()
        #expect(app.sessionsViewVisible && app.sessionsScope == .all && app.state.projects.map(\.id) == [p])
        app.toggleSessionsView()
        #expect(!app.sessionsViewVisible && app.selectedTask == nil)
    }

    @Test func emptyHistoryLoadsEmpty() async {
        let w = world()
        w.app.showSessionsView()
        let m = SessionsModel(app: w.app)
        #expect(m.load == .idle)
        await m.reload()
        #expect(m.load == .loaded && m.conversationRows.isEmpty)
        #expect(m.placeholder == nil && m.groups.map(\.items.count) == [1])  // the archived session still shows
    }

    /// Nothing to list: loading, then «пусто»; with a search or a chip — «ничего не найдено».
    @Test func placeholders() async {
        var s = WorkspaceState()
        _ = s.addProject(name: "p", path: "/work/p")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.claudeSettingsURL = dir.appendingPathComponent("claude/settings.json")
        app.codexConfigURL = dir.appendingPathComponent("codex/config.toml")
        app.showSessionsView()
        let m = SessionsModel(app: app)
        #expect(m.placeholder == .loading)
        await m.reload()
        #expect(m.placeholder == .empty)
        m.query = "stripe"
        #expect(m.placeholder == .noMatch)
        m.query = ""
        m.toggle(SessionsRowState.open)
        #expect(m.placeholder == .noMatch)
    }

    @Test func offlineRemoteProjectSkipsTheScan() async {
        var s = WorkspaceState()
        s.projects.append(Project(name: "srv", location: .ssh(host: "devbox", path: "/srv/app")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.showSessionsView()
        let m = SessionsModel(app: app)
        await m.reload()
        #expect(m.load == .loaded && m.offlineHosts == ["devbox"] && m.conversationRows.isEmpty)
        #expect(m.groups.map(\.note) == [.offline] && m.placeholder == nil)  // «Все»: a note in the host's group
        m.query = "stripe"
        #expect(m.placeholder == .noMatch)  // a search that found nothing says so over the host's note
        m.query = ""
        app.showSessionsView(scope: .host("devbox"))
        await m.reload()
        #expect(m.placeholder == .offline("devbox"))  // the host chosen: centered, with «Подключиться»
    }

    /// An offline host's archived sessions still show (they are in state.json); «Восстановить» waits for the connection.
    @Test func offlineHostArchivedSessionsShowButWait() async throws {
        var s = WorkspaceState()
        s.projects.append(Project(name: "srv", location: .ssh(host: "devbox", path: "/srv/app")))
        let t = s.addTask(projectId: s.projects[0].id, name: "deploy-logs")
        s.addTab(taskId: t, kind: .shell)
        s.archiveTask(id: t, at: date("2026-10-23T10:00:00Z"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.showSessionsView(scope: .host("devbox"))
        let m = SessionsModel(app: app)
        await m.reload()
        let item = try #require(m.groups.first?.items.first)
        #expect(item == .session(ClosedSessionRow(id: t, name: "deploy-logs", project: s.projects[0].id, branch: nil,
                                                  archivedAt: date("2026-10-23T10:00:00Z"), tabs: 1)))
        #expect(m.offlineHost(item) == "devbox" && !m.canRun(item) && m.placeholder == nil)
        m.selection = item.id
        #expect(m.activateSelection() == nil)
    }

    /// «Все» / «Этот Mac» / a host; a scope with no projects (a host's last project removed) falls back to «Все».
    @Test func scopeAllLocalAndHost() {
        var s = WorkspaceState()
        let local = s.addProject(name: "shop", path: "/work/shop")
        s.projects.append(Project(name: "srv", location: .ssh(host: "devbox", path: "/srv/app")))
        let remote = s.projects[1].id
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        let m = SessionsModel(app: app)
        app.showSessionsView(scope: .local)
        #expect(m.scope == .local && m.projects.map(\.id) == [local])
        app.showSessionsView(scope: .host("devbox"))
        #expect(m.scope == .host("devbox") && m.projects.map(\.id) == [remote] && app.sessionsHosts == ["devbox"])
        app.showSessionsView(scope: .host("gpu-box"))
        #expect(app.sessionsScope == .all)
        app.showSessionsView(scope: .host("devbox"))
        app.perform { $0.projects.removeAll { $0.id == remote } }
        #expect(m.scope == .all && m.projects.map(\.id) == [local])
    }

    /// ⌘Y lists every project (a host terminal selected too, #64); a project's menu or link scopes it, «Все» resets.
    @Test func allProjectsByDefaultAndScopedFromAProject() async throws {
        let w = world()
        var other = UUID(), shell = UUID(), otherClosed = UUID()
        w.app.perform { s in
            other = s.addProject(name: "blog", path: "/work/blog")
            otherClosed = s.addTask(projectId: other, name: "draft")
            s.archiveTask(id: otherClosed, at: Date(timeIntervalSince1970: 1_000))
            shell = s.openHostShell(host: "devbox").task
        }
        try w.fixture.claudeConversation(id: idA, cwd: "/work/wt/api-cache", branch: "api-cache", at: "2026-10-25T10:00:00Z", prompt: "кэш")
        try w.fixture.claudeConversation(id: idC, cwd: "/work/blog", branch: "main", at: "2026-10-24T10:00:00Z", prompt: "пост")
        #expect(w.app.selectedTask?.id == shell)
        w.app.showSessionsView()
        #expect(w.app.sessionsScope == .all)
        let m = SessionsModel(app: w.app)
        await m.reload()
        #expect(m.load == .loaded && m.closedRows.map(\.project) == [w.project, other])
        #expect(m.conversationRows.map(\.project) == [w.project, other])
        #expect(m.groups.map(\.id) == [w.project, other])
        #expect(m.action(for: m.conversationRows[1]) == .openInNewSession(m.conversationRows[1].conversation, project: other))

        w.app.hideSessionsView()
        // A project with a similar name and a conversation mentioning «blog» must not leak into «blog»'s list.
        var similar = UUID()
        w.app.perform { similar = $0.addProject(name: "blog-old", path: "/work/blog-old") }
        try w.fixture.claudeConversation(id: idX, cwd: "/work/blog-old", branch: "blog", at: "2026-10-24T11:00:00Z", prompt: "blog пост")
        Action.projectSessions.perform(.project(other), ActionContext(app: w.app))
        // «Сессии проекта»: that project by id (a removable chip), the search stays empty.
        #expect(w.app.sessionsViewVisible && w.app.sessionsScope == .all && w.app.sessionsProject == other)
        #expect(m.query.isEmpty && m.project?.id == other && m.projects.map(\.id) == [other] && m.isFiltering)
        await m.reload()
        #expect(m.closedRows.map(\.name) == ["draft"] && m.conversationRows.map(\.conversation.id) == [idC])
        #expect(m.groups.map(\.id) == [other])
        m.clearProject()  // the chip's «×»
        await m.reload()
        let listed: Set<UUID> = Set(m.conversationRows.map(\.project))
        #expect(listed == [w.project, other, similar])
        Action.projectSessions.perform(.project(other), ActionContext(app: w.app))
        w.app.showSessionsView(scope: .local)  // a scope from the segment drops the chip
        #expect(w.app.sessionsProject == nil)
        Action.projectSessions.perform(.project(other), ActionContext(app: w.app))
        m.resetFilters()
        #expect(w.app.sessionsProject == nil && !m.isFiltering)
        w.app.showSessionsView(projectId: w.app.state.hostShells[0].id)  // a host terminal's pseudo-project is no project
        #expect(w.app.sessionsScope == .all && w.app.sessionsProject == nil)
    }

    /// A host still connecting reads «Читаю…» in its group, not «Нет связи»; that comes only once it gave up or dropped.
    @Test func connectingHostIsLoadingNotOffline() async {
        var s = WorkspaceState()
        s.projects.append(Project(name: "srv", location: .ssh(host: "devbox", path: "/srv/app")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sessions-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        app.showSessionsView(scope: .host("devbox"))
        let m = SessionsModel(app: app)
        m.hostLink = { _ in .connecting }
        await m.reload()
        #expect(m.offlineHosts.isEmpty && m.connectingHosts == ["devbox"])
        #expect(m.groups.map(\.note) == [.loading] && m.placeholder == nil)
        m.hostLink = { _ in .offline }
        await m.reload()
        #expect(m.connectingHosts.isEmpty && m.placeholder == .offline("devbox"))
    }

    @Test func hostLinkStates() {
        var info = HostInfo()
        #expect(sessionsHostLink(nil) == .offline && sessionsHostLink(info) == .offline)  // never connected
        info.state = .connecting
        #expect(sessionsHostLink(info) == .connecting)
        info.state = .reconnecting(attempt: 2)
        #expect(sessionsHostLink(info) == .connecting)
        info.retryPaused = true  // nothing retrying until the app is active again
        #expect(sessionsHostLink(info) == .offline)
        info.state = .unreachable("ssh: timed out")
        #expect(sessionsHostLink(info) == .offline)
        info.state = .connected
        #expect(sessionsHostLink(info) == .connected)
    }

    /// One source failing keeps the others' conversations and says why, with a retry; the load always finishes.
    @Test func failingSourceIsShownInlineAndRetried() async throws {
        let (w, m) = try await loaded()
        var broken = true
        m.scan = { folder, project in
            if broken && folder == "/work/wt/api-cache" { throw HistoryError.remote("ssh: connect to host devbox port 22: Operation timed out") }
            return try await w.app.conversations(folder: folder, project: project)
        }
        await m.reload()
        #expect(m.load == .loaded)
        #expect(m.failures.first?.message == "ssh: connect to host devbox port 22: Operation timed out")
        #expect(m.conversationRows.map(\.conversation.id).sorted() == [idB, idC, idX].sorted())
        #expect(m.localFailure?.timedOut == false)
        broken = false
        await m.reload()
        #expect(m.load == .loaded && m.failures.isEmpty && m.conversationRows.count == 4)
    }

    /// A source that never answers is cut at its timeout; rows already found show while it is pending.
    @Test func hangingSourceTimesOutAndEarlierRowsShowMeanwhile() async throws {
        let (w, _) = try await loaded()
        let fresh = SessionsModel(app: w.app)
        fresh.localTimeout = .seconds(600)
        // The root folder answers only when cancelled, with what it had read (as a local scan cut by its timeout does).
        fresh.scan = { folder, project in
            let list = try await w.app.conversations(folder: folder, project: project)
            if folder == "/work/shop" { try? await Task.sleep(for: .seconds(3600)) }
            return list
        }
        let run = Task { await fresh.reload() }
        #expect(await waitUntil { fresh.conversationRows.count == 2 })  // both worktrees' conversations, before the root answers
        #expect(fresh.load == .loading)
        run.cancel()
        _ = await run.value
        fresh.localTimeout = .milliseconds(200)
        await fresh.reload()
        // Cut by the timeout: said so, and the root's rows read so far are kept.
        #expect(fresh.load == .loaded && fresh.failures.first?.timedOut == true && fresh.conversationRows.count == 4)
    }

    /// A new scan (scope change, retry) cancels the one still running: it stops, the newer result stands.
    @Test func newReloadCancelsTheRunningOne() async throws {
        let (w, _) = try await loaded()
        let m = SessionsModel(app: w.app)
        final class Flag: @unchecked Sendable { var hang = true; var stopped = false }
        let flag = Flag()
        m.scan = { folder, project in
            if flag.hang {
                do { try await Task.sleep(for: .seconds(3600)) } catch { flag.stopped = true; throw error }
            }
            return try await w.app.conversations(folder: folder, project: project)
        }
        let first = Task { await m.reload() }
        #expect(await waitUntil { m.load == .loading })
        flag.hang = false
        await m.reload()
        await first.value
        #expect(flag.stopped && m.load == .loaded && m.failures.isEmpty && m.conversationRows.count == 4)
    }

    /// «Открыт» is any live agent leaf with that id — a TERMINAL panel too, in another project too; never a leaf on
    /// another machine with the same id.
    @Test func openAnywhereIsFocusedNotResumedAgain() async throws {
        let (w, m) = try await loaded()
        var other = UUID(), remote = UUID()
        w.app.perform { s in
            let p = s.addProject(name: "elsewhere", path: "/work/elsewhere")
            other = s.addTask(projectId: p, name: "other")
            s.toggleDrawer(taskId: other)
            let r = s.addRemoteProject(name: "srv", host: "devbox", path: "/work/shop")
            remote = s.addTask(projectId: r, name: "remote")
            s.addTab(taskId: remote, kind: .claude)
        }
        let remoteLeaf = try #require(w.app.state.tasks.first { $0.id == remote }?.tabs.last?.focusedLeafId)
        w.app.perform { $0.setAgentSessionId(leafId: remoteLeaf, self.idC) }
        func row(_ id: String) -> ConversationRow? { m.conversationRows.first { $0.conversation.id == id && $0.project == w.project } }
        #expect(row(idC)?.isOpen == false)  // the same id on devbox is another conversation
        // A claude in another project's TERMINAL panel (state.json allows it) holds it: «Перейти» goes there.
        let held = Leaf(kind: .claude, cwd: "/work/shop", agentSessionId: idC)
        w.app.perform { s in
            let i = s.tasks.firstIndex { $0.id == other }!
            s.tasks[i].drawer.leaf = held
        }
        #expect(row(idC)?.place == .open(task: other, leaf: held.id, name: "other"))
        let r = try #require(row(idC))
        #expect(m.action(for: r) == .focus(leaf: held.id))
        await m.perform(m.action(for: r), ctx: ActionContext(app: w.app))
        #expect(w.app.selectedTask?.id == other && !w.app.sessionsViewVisible)
        #expect(w.app.state.tasks.flatMap(\.tabs).flatMap(\.root.leaves).filter { $0.agentSessionId == idC }.count == 1)  // no second resume
    }

    /// A conversation id from a file that is not a valid session id opens nothing — no empty session either;
    /// its title becomes a safe one-line session name.
    @Test func invalidIdOpensNoSessionAndTitlesAreSanitized() async throws {
        let (w, m) = try await loaded()
        let before = w.app.state.tasks.count
        let bad = Conversation(id: "--evil", agent: .claude, cwd: "/work/shop", started: nil, lastActivity: Date(), messageCount: 1,
                               messageCountIsEstimate: false, gitBranch: nil, title: "x", isOpen: false)
        await m.perform(.openInNewSession(bad, project: w.project), ctx: ActionContext(app: w.app))
        #expect(w.app.state.tasks.count == before)
        let name = sessionName("\nfix\u{202E} the\u{1B}[31m bug " + String(repeating: "x", count: 80))
        #expect(!name.contains("\n") && !name.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x1B })
        #expect(name.count <= 40 && name.hasPrefix("fix the"))
    }

    /// The sidebar's «Все сессии в архиве» hint: only when the project has closed sessions and no open one.
    @Test func allSessionsArchivedHint() {
        let w = world()
        #expect(!w.app.allSessionsArchived(w.project))
        w.app.perform { s in
            s.archiveTask(id: w.main, at: Date())
            s.archiveTask(id: w.feature, at: Date())
        }
        #expect(w.app.allSessionsArchived(w.project))
        var empty = UUID()
        w.app.perform { empty = $0.addProject(name: "new", path: "/work/new") }
        #expect(!w.app.allSessionsArchived(empty))  // never had a session: nothing to point at
    }

    @Test func nestedProjectOwnsItsConversations() async throws {
        let (w, m) = try await loaded()
        let inner = "66666666-6666-4666-8666-666666666666"
        try w.fixture.claudeConversation(id: inner, cwd: "/work/shop/admin", branch: nil, at: "2026-10-25T09:00:00Z", prompt: "админка")
        await m.reload()
        #expect(m.conversationRows.contains { $0.conversation.id == inner })  // a subfolder of the project

        var nested = UUID()
        w.app.perform { nested = $0.addProject(name: "admin", path: "/work/shop/admin") }
        await m.reload()
        // All projects: listed once, under the deeper project.
        #expect(m.conversationRows.filter { $0.conversation.id == inner }.map(\.project) == [nested])
        w.app.showSessionsView(projectId: w.project)
        await m.reload()
        #expect(!m.conversationRows.contains { $0.conversation.id == inner })  // listed under the deeper project only
        w.app.showSessionsView(projectId: nested)
        await m.reload()
        #expect(m.conversationRows.map(\.conversation.id) == [inner])
    }

    @Test func remoteHistoryBatchFitsTheHostOutputCap() {
        // One fetch: a header and at most head + tail bytes per file; half the cap leaves room for escaping and headers.
        let batch = ConversationHistory.remoteBatch * (ConversationHistory.defaultHeadBytes + ConversationHistory.defaultTailBytes + 4096)
        #expect(batch < RemoteHosts.maxOutput / 2)
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
