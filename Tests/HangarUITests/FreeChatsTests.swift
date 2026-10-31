import AgentStatus
import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Chats without a project in the app: the shared folder next to the state, the default agent, asleep instead of closed.
@MainActor @Suite struct FreeChatsTests {
    private func makeApp(agent: LeafKind = .claude, _ build: (inout WorkspaceState) -> Void = { _ in }) -> (AppState, URL) {
        var s = WorkspaceState()
        build(&s)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-free-\(UUID())")
        var config = HangarConfig()
        config.defaultAgent = agent
        let app = AppState(state: s, store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.codexRead = nil
        app.keepAwake = .inert()
        return (app, dir)
    }

    private func firstLeaf(_ app: AppState, _ task: UUID) throws -> (tab: UUID, leaf: Leaf) {
        let t = try #require(app.state.tasks.first { $0.id == task })
        let tab = try #require(t.tabs.first)
        return (tab.id, try #require(tab.root.leaves.first))
    }

    @Test(arguments: [LeafKind.claude, .codex])
    func newChatRunsDefaultAgentInChatsFolder(agent: LeafKind) throws {
        let (app, dir) = makeApp(agent: agent)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Chats").path
        #expect(app.state.chatsFolder == folder)
        let task = app.newFreeChat()
        #expect(app.state.selectedTaskId == task)
        #expect(app.state.tasks.first { $0.id == task }?.name == L10n.chatNumbered(1))
        #expect(folderExists(folder))
        let (tab, leaf) = try firstLeaf(app, task)
        #expect(leaf.kind == agent && leaf.cwd == folder)
        // A deleted folder comes back before the agent starts.
        try FileManager.default.removeItem(atPath: folder)
        _ = try app.spec(for: leaf, tabId: tab, context: .created(prompt: nil))
        #expect(folderExists(folder))
        // «Чат N» counts only chats without a project, asleep ones too.
        app.sleepFreeChat(task)
        let second = app.newFreeChat()
        #expect(app.state.tasks.first { $0.id == second }?.name == L10n.chatNumbered(2))
    }

    @Test func ownPromptMovesUpSelectionAndWakeDoNot() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = app.newFreeChat()
        let b = app.newFreeChat()
        app.perform { s in
            s.touchFreeChat(taskId: a, at: Date(timeIntervalSince1970: 1))
            s.touchFreeChat(taskId: b, at: Date(timeIntervalSince1970: 2))
        }
        #expect(app.state.freeChatTasks.map(\.id) == [b, a])
        app.select(taskId: a)
        app.sleepFreeChat(a)
        app.wakeFreeChat(a)
        #expect(app.state.freeChatTasks.map(\.id) == [b, a])
        let (tab, leaf) = try firstLeaf(app, a)
        app.handle(.event(EventMessage(tab: tab, leaf: leaf.id, kind: .sessionStart, session: "s", source: "startup", agentPid: 7)))
        app.handle(.event(EventMessage(tab: tab, leaf: leaf.id, kind: .prompt, session: "s", message: "hi", agentPid: 7)))
        #expect(app.state.freeChatTasks.map(\.id) == [a, b])
    }

    @Test func launchRestoresOnlyOpenChats() throws {
        var open: (task: UUID, tab: UUID)!
        var asleep: (task: UUID, tab: UUID)!
        let (app, dir) = makeApp { s in
            open = s.addFreeChat(name: "open", kind: .claude, autoNamed: false)
            asleep = s.addFreeChat(name: "asleep", kind: .claude, autoNamed: false)
            s.sleepFreeChat(taskId: asleep.task)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(app.isRestored(leafId: try firstLeaf(app, open.task).leaf.id))
        #expect(!app.isRestored(leafId: try firstLeaf(app, asleep.task).leaf.id))
        app.wakeFreeChat(asleep.task)
        #expect(app.isRestored(leafId: try firstLeaf(app, asleep.task).leaf.id))
        #expect(app.state.selectedTaskId == asleep.task)
    }

    @Test func sidebarShowsPinnedOpenAndSelectedThenRecent() {
        var ids: [UUID] = []
        let (app, dir) = makeApp { s in
            for i in 0..<10 {
                let c = s.addFreeChat(name: "c\(i)", kind: .claude, autoNamed: false, at: Date(timeIntervalSince1970: Double(i)))
                ids.append(c.task)
                s.sleepFreeChat(taskId: c.task)
            }
            s.wakeFreeChat(taskId: ids[0])  // the oldest, open
            s.setPinned(taskId: ids[1], true)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = app.sidebarFreeChats(limit: 4).map(\.name)
        #expect(rows == ["c1", "c9", "c8", "c0"])
        // Open ones lead ⇧⌘[ / ⇧⌘], asleep ones are skipped.
        #expect(app.orderedTasks.map(\.name) == ["c0"])
    }

    @Test func titleMenusAndControlStayOutsideProjects() throws {
        let (app, dir) = makeApp { s in
            let p = s.addProject(name: "app", path: "/tmp")
            s.addTask(projectId: p, name: "work")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = app.newFreeChat()
        #expect(windowTitle(app.state) == WindowTitle(title: L10n.chatNumbered(1), subtitle: L10n.noProject))
        #expect(app.placeName(of: try #require(app.state.tasks.first { $0.id == task })) == L10n.noProject)
        #expect(Action.list(for: .task(task), app: app) == [.rename, .togglePin, .toggleMute, .removeFreeChat])
        // CLI and MCP never see chats without a project; a project's chat still resolves.
        if case .success = app.resolveTask(L10n.chatNumbered(1)) { Issue.record("free chat resolved") }
        if case .failure = app.resolveTask("work") { Issue.record("project chat not resolved") }
        app.sleepFreeChat(task)
        #expect(Action.list(for: .task(task), app: app) == [.rename, .togglePin, .removeFreeChat])
        #expect(app.isOutsideProjects(try #require(app.state.tasks.first { $0.id == task })))
        if case .success = app.resolveTask(L10n.chatNumbered(1), archived: true) { Issue.record("asleep free chat resolved") }
    }

    @Test func archiveKeySleepsAndRemoveConfirmsWithoutTouchingTranscript() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: transcript)
        var confirmed: (() -> Void)?
        var toast = false
        var ctx = ActionContext(app: app)
        ctx.confirm = { _, _, _, ok in confirmed = ok }
        ctx.didArchive = { _ in toast = true }
        let task = app.newFreeChat()
        Action.archive.perform(.task(task), ctx)
        #expect(app.state.tasks.first { $0.id == task }?.archived == true && !toast)
        Action.removeFreeChat.perform(.task(task), ctx)
        #expect(app.state.tasks.contains { $0.id == task })
        let ok = try #require(confirmed)
        ok()
        #expect(!app.state.tasks.contains { $0.id == task } && app.state.freeChats.isEmpty)
        #expect(FileManager.default.fileExists(atPath: transcript.path))
    }

    @Test func relativeTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 15))!  // Saturday
        let ago = { (s: Double) in freeChatTime(now.addingTimeInterval(-s), now: now, calendar: cal) }
        #expect(ago(10) == L10n.freeTimeNow)
        #expect(ago(120) == L10n.freeTimeMinutes(2))
        #expect(ago(3 * 3600) == L10n.freeTimeHours(3))
        #expect(ago(20 * 3600) == L10n.sessionsYesterday)
        #expect(!ago(3 * 86400).isEmpty && ago(3 * 86400) != ago(4 * 86400))  // weekdays
        #expect(ago(30 * 86400) != ago(31 * 86400))  // dates
    }
}
