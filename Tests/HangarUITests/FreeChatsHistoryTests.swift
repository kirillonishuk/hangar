import Foundation
import History
import Testing
@testable import HangarUI
import Workspace

/// History «Чаты»: the chats folder only, by day, waking asleep chats, new chats for conversations nobody holds,
/// search by conversation text; «Все» lists «Чаты» first; a project around the folder does not list them.
@MainActor @Suite struct FreeChatsHistoryTests {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private let idOpen = "aaaaaaaa-1111-4111-8111-111111111111"
    private let idAsleep = "bbbbbbbb-2222-4222-8222-222222222222"
    private let idLoose = "cccccccc-3333-4333-8333-333333333333"
    private let idProject = "dddddddd-4444-4444-8444-444444444444"

    private struct World {
        let app: AppState
        let root: URL
        let open: UUID
        let asleep: UUID
        let empty: UUID
    }

    private func write(_ root: URL, id: String, cwd: String, at: String, prompt: String, reply: String) throws {
        let dir = root.appendingPathComponent("claude/projects/" + claudeProjectDirName(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func json(_ o: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self)
        }
        let lines = [
            json(["type": "user", "timestamp": at, "cwd": cwd, "message": ["content": prompt]]),
            json(["type": "assistant", "timestamp": at, "cwd": cwd, "message": ["content": [["type": "text", "text": reply],
                                                                                              ["type": "tool_use", "name": "Bash", "input": ["command": "secret-tool"]]]]]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-free-history-\(UUID())")
        let stateDir = root.appendingPathComponent("state")
        let chats = stateDir.appendingPathComponent("Chats").path
        var s = WorkspaceState()
        s.chatsFolder = chats
        let p = s.addProject(name: "home", path: root.path)  // around the chats folder
        s.addTask(projectId: p, name: "home chat")
        let open = s.addFreeChat(name: "PKCE", kind: .claude, autoNamed: false).task
        let asleep = s.addFreeChat(name: "Регулярка", kind: .claude, autoNamed: false).task
        let empty = s.addFreeChat(name: "Пустой", kind: .claude, autoNamed: false).task
        for (task, id) in [(open, idOpen), (asleep, idAsleep)] {
            let leaf = s.tasks.first { $0.id == task }!.tabs[0].root.leaves[0].id
            s.setAgentSessionId(leafId: leaf, id)
        }
        s.sleepFreeChat(taskId: asleep, at: Date(timeIntervalSince1970: 0))
        s.sleepFreeChat(taskId: empty, at: ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!)
        try FileManager.default.createDirectory(atPath: chats, withIntermediateDirectories: true)
        try write(root, id: idOpen, cwd: chats, at: "2026-10-31T10:00:00Z", prompt: "как работает PKCE", reply: "code_verifier и challenge")
        try write(root, id: idAsleep, cwd: chats, at: "2026-10-30T20:00:00Z", prompt: "регулярка для дат", reply: "смотри redirect_uri в логах")
        try write(root, id: idLoose, cwd: chats, at: "2026-10-27T08:00:00Z", prompt: "план поездки", reply: "Тбилиси")
        try write(root, id: idProject, cwd: root.path, at: "2026-10-31T11:00:00Z", prompt: "проект", reply: "ok")
        let app = AppState(state: s, store: StateStore(directory: stateDir), config: HangarConfig(),
                           configURL: root.appendingPathComponent("c.toml"))
        app.claudeSettingsURL = root.appendingPathComponent("claude/settings.json")
        app.codexConfigURL = root.appendingPathComponent("codex/config.toml")
        app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running }, send: { _, _, _ in }, read: { _ in nil })
        return World(app: app, root: root, open: open, asleep: asleep, empty: empty)
    }

    private func model(_ w: World, scope: SessionsScope) async -> SessionsModel {
        w.app.showSessionsView(scope: scope)
        let m = SessionsModel(app: w.app)
        m.now = { ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")! }
        m.calendar = Self.utc
        await m.reload()
        return m
    }

    @Test func chatsScopeGroupsByDayAndActs() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let m = await model(w, scope: .chats)
        #expect(m.scope == .chats)
        let g = m.groups
        #expect(g.map(\.name).prefix(2) == [L10n.today, "Вчера"] || g.map(\.name).prefix(2) == [L10n.today, "Yesterday"])
        #expect(g.count == 3)
        let ids = g.flatMap(\.items).map(\.id)
        #expect(ids == ["claude:" + idOpen, "claude:" + idAsleep, "session:" + w.empty.uuidString, "claude:" + idLoose])
        #expect(!ids.contains("claude:" + idProject))
        let rows = Dictionary(uniqueKeysWithValues: m.conversationRows.map { ($0.conversation.id, $0) })
        #expect(m.action(for: try #require(rows[idAsleep])) == .restore(w.asleep))
        if case .openInNewFreeChat = m.action(for: try #require(rows[idLoose])) {} else { Issue.record("loose conversation") }
        // Waking from History: the chat is open and selected.
        await m.perform(.restore(w.asleep), ctx: ActionContext(app: w.app))
        #expect(w.app.state.tasks.first { $0.id == w.asleep }?.archived == false)
        #expect(w.app.state.selectedTaskId == w.asleep && !w.app.sessionsViewVisible)
        // A conversation nobody holds: a new chat without a project resuming it.
        let before = w.app.state.freeChats.count
        await m.perform(m.action(for: try #require(rows[idLoose])), ctx: ActionContext(app: w.app))
        #expect(w.app.state.freeChats.count == before + 1)
        let leaf = try #require(w.app.selectedTask?.tabs.first?.root.leaves.first)
        #expect(leaf.agentSessionId == idLoose && leaf.cwd == w.app.state.chatsFolder && w.app.isRestored(leafId: leaf.id))
    }

    @Test func allScopeListsChatsFirstAndProjectsWithoutThem() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let m = await model(w, scope: .all)
        #expect(m.groups.map(\.name) == [L10n.freeChatsScope, "home"])
        #expect(m.groups[1].items.map(\.id) == ["claude:" + idProject])
    }

    @Test func searchByConversationText() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let m = await model(w, scope: .chats)
        m.query = "REDIRECT_URI"
        await m.searchText()
        #expect(m.conversationRows.map(\.conversation.id) == [idAsleep])
        m.query = "secret-tool"  // tools are not the conversation's words
        await m.searchText()
        #expect(m.conversationRows.isEmpty)
        m.query = "PKCE"  // by title too
        await m.searchText()
        #expect(m.conversationRows.map(\.conversation.id) == [idOpen])
    }

    @Test func dropCopiesIntoFolderAndTypesMention() throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        var sent: [String] = []
        w.app.terminals = TerminalAccess(start: { _ in }, state: { _ in .running }, send: { _, t, _ in sent.append(t ?? "") }, read: { _ in nil })
        w.app.select(taskId: w.open)
        let src = w.root.appendingPathComponent("rfc 7636.pdf")
        try Data("pdf".utf8).write(to: src)
        #expect(w.app.dropIntoChats([src]) == ["rfc 7636.pdf"])
        #expect(w.app.dropIntoChats([src]) == ["rfc 7636 2.pdf"])
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(FileManager.default.fileExists(atPath: w.app.state.chatsFolder + "/rfc 7636 2.pdf"))
        #expect(sent == ["@rfc 7636.pdf ", "@rfc 7636 2.pdf "])
        #expect(freeChatCopyName("notes", taken: { $0 == "notes" || $0 == "notes 2" }) == "notes 3")
    }
}
