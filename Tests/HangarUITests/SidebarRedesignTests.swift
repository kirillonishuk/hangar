import AgentStatus
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// Redesign track B: the two-line session row (status text, diff badge) and the custom popover menu.
@MainActor @Suite struct SidebarRedesignTests {
    // MARK: Plurals and status text

    @Test func russianPluralForms() {
        let cases: [(Int, PluralForm)] = [(0, .many), (1, .one), (2, .few), (4, .few), (5, .many), (11, .many), (12, .many),
                                          (14, .many), (21, .one), (22, .few), (25, .many), (101, .one), (111, .many), (112, .many)]
        for (n, form) in cases { #expect(pluralForm(n) == form, "\(n)") }
    }

    @Test func agentSubagentAndTabCounts() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.agentCount(1) == "1 агент")
        #expect(L10n.agentCount(3) == "3 агента")
        #expect(L10n.agentCount(5) == "5 агентов")
        #expect(L10n.agentCount(21) == "21 агент")
        #expect(L10n.subagentCount(1) == "1 субагент")
        #expect(L10n.subagentCount(2) == "2 субагента")
        #expect(L10n.subagentCount(11) == "11 субагентов")
        #expect(L10n.tabCount(1) == "1 вкладка")
        #expect(L10n.tabCount(3) == "3 вкладки")
        #expect(L10n.tabCount(7) == "7 вкладок")
        L10n.language = .en
        #expect(L10n.agentCount(1) == "1 agent")
        #expect(L10n.agentCount(2) == "2 agents")
        #expect(L10n.subagentCount(1) == "1 subagent")
        #expect(L10n.subagentCount(3) == "3 subagents")
        #expect(L10n.tabCount(2) == "2 tabs")
    }

    @Test func sessionStatusText() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(SessionStatus(state: .waiting, agents: 1, subagents: 0, tabs: 1) == SessionStatus(head: "ждёт", tail: "1 агент", tone: .waiting))
        // Running subagents replace the agent count.
        #expect(SessionStatus(state: .working, agents: 1, subagents: 2, tabs: 2) == SessionStatus(head: "работает", tail: "2 субагента", tone: .normal))
        #expect(SessionStatus(state: .done, agents: 2, subagents: 0, tabs: 2).text == "готово · 2 агента")
        #expect(SessionStatus(state: .failed, agents: 1, subagents: 0, tabs: 1).tone == .failed)
        #expect(SessionStatus(state: .failed, agents: 1, subagents: 0, tabs: 1).head == "ошибка")
        // The limit: amber, with the reset time when known.
        #expect(SessionStatus(state: .limit, agents: 1, subagents: 0, tabs: 1, limitUntil: "20:20")
                == SessionStatus(head: "лимит · до 20:20", tail: "1 агент", tone: .waiting))
        #expect(SessionStatus(state: .limit, agents: 2, subagents: 0, tabs: 2).text == "на лимите · 2 агента")
        #expect(SessionStatus(state: .idle, agents: 5, subagents: 0, tabs: 5).text == "простой · 5 агентов")
        // No agent tabs: the tab count instead.
        #expect(SessionStatus(state: .idle, agents: 0, subagents: 0, tabs: 1).text == "нет агентов · 1 вкладка")
        #expect(SessionStatus(state: .idle, agents: 0, subagents: 0, tabs: 0).text == "нет агентов · 0 вкладок")
        L10n.language = .en
        #expect(SessionStatus(state: .waiting, agents: 1, subagents: 0, tabs: 1).text == "waiting · 1 agent")
        #expect(SessionStatus(state: .idle, agents: 0, subagents: 0, tabs: 2).text == "no agents · 2 tabs")
        #expect(SessionStatus(state: .limit, agents: 1, subagents: 0, tabs: 1, limitUntil: "20:20").text == "limit · until 20:20 · 1 agent")
    }

    /// A folded project's row: the most urgent session state (waiting > limit > error > working) and how many sessions are in it.
    @Test func foldedProjectShowsTheMostUrgentState() {
        #expect(foldedProjectBadge([.waiting, .working, .waiting]) == FoldedProjectBadge(state: .waiting, count: 2))
        #expect(foldedProjectBadge([.failed, .limit, .working]) == FoldedProjectBadge(state: .limit, count: 1))
        #expect(foldedProjectBadge([.working, .failed, .failed]) == FoldedProjectBadge(state: .failed, count: 2))
        #expect(foldedProjectBadge([.working, .done]) == FoldedProjectBadge(state: .working, count: 1))
        #expect(foldedProjectBadge([.done, .idle]) == nil)
        #expect(foldedProjectBadge([]) == nil)
    }

    @Test func sessionStatusOfTaskCountsAgentsAndSubagents() throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.app.perform { s in
            _ = s.addTab(taskId: h.task, kind: .claude)
            _ = s.addTab(taskId: h.task, kind: .codex)
            _ = s.addTab(taskId: h.task, kind: .shell)
        }
        defer { L10n.language = .system }
        L10n.language = .ru
        let status = h.app.sessionStatus(of: try #require(h.app.state.tasks.first { $0.id == h.task }))
        #expect(status == SessionStatus(head: "простой", tail: "2 агента", tone: .normal))
    }

    // MARK: Diff badge

    @Test func diffBadgeFormatting() {
        #expect(DiffBadge(DiffStat(files: 3, added: 541, deleted: 88)) == DiffBadge(added: "+541", deleted: "−88"))
        #expect(DiffBadge(DiffStat(files: 1, added: 12, deleted: 0)) == DiffBadge(added: "+12", deleted: "−0"))
        // No changes, or not loaded: no badge.
        #expect(DiffBadge(DiffStat(files: 0, added: 0, deleted: 0)) == nil)
        #expect(DiffBadge(nil) == nil)
        // A binary-only change still shows (0 lines but a file).
        #expect(DiffBadge(DiffStat(files: 1, added: 0, deleted: 0)) == DiffBadge(added: "+0", deleted: "−0"))
    }

    @Test func badgeCacheLoadsOnceAndReloadsOnRefresh() async {
        let cache = SessionBadges()
        let id = UUID()
        var calls = 0
        let load: SessionBadges.Load = { calls += 1; return DiffStat(files: 1, added: calls, deleted: 0) }
        cache.request(id, load: load)
        cache.request(id, load: load)
        await cache.idle(id)
        #expect(calls == 1)
        #expect(cache.stats[id]?.added == 1)
        // A refresh of a never-shown session loads nothing.
        cache.refresh(UUID(), load: load)
        cache.refresh(id, load: load)
        await cache.idle(id)
        #expect(calls == 2)
        #expect(cache.stats[id]?.added == 2)
    }

    // MARK: Menu model

    @Test func sessionMenuEntries() throws {
        let h = try Harness()
        defer { h.cleanup() }
        defer { L10n.language = .system }
        L10n.language = .ru
        let entries = actionMenu(for: .task(h.task), ctx: ActionContext(app: h.app))
        let items = entries.compactMap(\.item)
        #expect(items.map(\.title).contains("В архив"))
        #expect(!items.map(\.title).contains("Архивировать"))
        let close = try #require(items.last)
        #expect(close.title == "В архив")
        #expect(close.destructive)
        #expect(close.shortcut == "⇧⌘W")
        #expect(items.first { $0.title == L10n.rename }?.shortcut == "F2")
        #expect(items.first { $0.title == L10n.copyPath }?.shortcut == "⌥⌘C")
        #expect(items.filter(\.destructive).count == 1)
        // The destructive item is its own last group; the menu opens with a header (name) and has no doubled separators.
        #expect(entries.first == .header("a"))
        #expect(entries[entries.count - 2] == .separator)
        for (x, y) in zip(entries, entries.dropFirst()) { #expect(!(x == .separator && y == .separator)) }
    }

    @Test func projectMenuEntries() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let items = actionMenu(for: .project(h.project), ctx: ActionContext(app: h.app)).compactMap(\.item)
        #expect(items.first?.title == L10n.newTask)
        #expect(items.last?.title == L10n.removeFromHangar)
        #expect(items.last?.destructive == true)
        #expect(items.filter(\.destructive).count == 1)
    }

    @Test func plainEntriesBecomeItems() {
        var fired = false
        let entries = popoverEntries([MenuEntry(title: "x", icon: .shell) { fired = true },
                                      MenuEntry(title: "y", icon: .close, enabled: false) {}])
        #expect(entries.count == 2)
        #expect(entries[1].item?.enabled == false)
        entries[0].item?.action()
        #expect(fired)
    }

    @Test func keyboardSkipsSeparatorsHeadersAndDisabled() {
        let item = { (on: Bool) in PopoverMenuEntry.item(PopoverMenuItem(title: "", enabled: on) {}) }
        let entries: [PopoverMenuEntry] = [.header("h"), item(true), .separator, item(false), item(true), .separator, item(true)]
        #expect(menuStep(entries, from: nil, by: 1) == 1)
        #expect(menuStep(entries, from: nil, by: -1) == 6)
        #expect(menuStep(entries, from: 1, by: 1) == 4)
        #expect(menuStep(entries, from: 4, by: -1) == 1)
        // Wraps around.
        #expect(menuStep(entries, from: 6, by: 1) == 1)
        #expect(menuStep(entries, from: 1, by: -1) == 6)
        #expect(menuStep([.separator, item(false)], from: nil, by: 1) == nil)
    }

    // MARK: Sessions entry

    @Test func sessionsEntryShowsTheSessionsView() throws {
        let h = try Harness()
        defer { h.cleanup() }
        #expect(!h.app.sessionsViewVisible)
        h.app.showSessionsView()
        #expect(h.app.sessionsViewVisible)
    }
}

/// Project "app" at a temp folder with session "a".
@MainActor private struct Harness {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-sidebar-\(UUID())")
    let app: AppState
    let project: UUID
    let task: UUID

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        task = s.addTask(projectId: p, name: "a")
        project = p
        app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                       config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
