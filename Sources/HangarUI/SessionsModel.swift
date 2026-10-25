import AgentStatus
import Foundation
import History
import Observation
import Workspace

/// «Сессии» (⌘Y, redesign-v1 §5): a project's closed sessions and its agents' past conversations, in place of the session area.
extension AppState {
    var sessionsViewVisible: Bool { sessionsProjectId != nil }

    /// ⌘Y, the sidebar row «Сессии»: the view for `projectId` (default: the selected session's project, else the first one).
    /// It overlays the session area; the selection stays (and is saved), so Esc or a relaunch is back on that session.
    func showSessionsView(projectId: UUID? = nil) {
        guard let id = projectId ?? selectedTask?.projectId ?? sessionsProjectId ?? state.projects.first?.id else { beep(); return }  // no project: nothing to show
        sessionsProjectId = id
        didChange?()
    }

    /// Esc, ⌘Y: back to the selected session.
    func hideSessionsView() {
        guard sessionsProjectId != nil else { return }
        sessionsProjectId = nil
        didChange?()
    }

    func toggleSessionsView() { if sessionsViewVisible { hideSessionsView() } else { showSessionsView() } }

    /// Where the project's conversations were recorded: its folder and every session worktree (closed ones too).
    func sessionFolders(_ projectId: UUID) -> [String] {
        guard let project = project(projectId) else { return [] }
        var out = [project.path]
        for t in state.tasks where t.projectId == projectId {
            if case .worktree(let path, _, _) = t.mode, !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// Session id → the live tab that runs it (agent leaves of open sessions).
    var openConversationTabs: [String: (task: UUID, tab: UUID)] {
        var out: [String: (task: UUID, tab: UUID)] = [:]
        for t in state.tasks where !t.archived {
            for tab in t.tabs {
                for leaf in tab.root.leaves where leaf.kind == .claude || leaf.kind == .codex {
                    if let id = validSessionId(leaf.agentSessionId), out[id] == nil { out[id] = (t.id, tab.id) }
                }
            }
        }
        return out
    }
}

// MARK: Rows

struct ClosedSessionRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let branch: String?
    let closedAt: Date?
    let changes: LineChanges?
    /// Leaves per tab: the layout glyph draws a wider box for a split tab.
    let tabLeaves: [Int]
}

/// The project's closed sessions, last closed first (those closed before the time was recorded go last).
func closedSessionRows(_ tasks: [HangarTask], projectId: UUID) -> [ClosedSessionRow] {
    tasks.filter { $0.projectId == projectId && $0.archived }
        .enumerated()
        .sorted { a, b in
            let x = a.element.archivedAt ?? .distantPast, y = b.element.archivedAt ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }
        .map { _, t in
            ClosedSessionRow(id: t.id, name: t.name, branch: t.branch, closedAt: t.archivedAt, changes: t.archivedChanges,
                             tabLeaves: t.tabs.map { $0.root.leaves.count })
        }
}

/// The session a conversation belongs to.
enum ConversationPlace: Equatable {
    /// Already running in this tab.
    case open(task: UUID, tab: UUID, name: String)
    /// Its folder's open session: opens there as a new tab.
    case session(task: UUID, name: String)
    /// Its folder's session is closed: restoring it resumes its agents.
    case closed(task: UUID, name: String)
    /// The project folder without an open session: opens in a new one.
    case none
}

struct ConversationRow: Identifiable, Equatable {
    let conversation: Conversation
    let place: ConversationPlace
    var id: String { conversation.agent.rawValue + ":" + conversation.id }
    var isOpen: Bool { if case .open = place { true } else { false } }
}

enum HistoryDay: Hashable {
    case today, yesterday
    /// Start of that day.
    case date(Date)
}

func historyDay(_ d: Date, now: Date, calendar: Calendar) -> HistoryDay {
    if calendar.isDate(d, inSameDayAs: now) { return .today }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return .yesterday }
    return .date(calendar.startOfDay(for: d))
}

struct ConversationDay: Identifiable, Equatable {
    let day: HistoryDay
    var rows: [ConversationRow]
    var id: HistoryDay { day }
}

/// Consecutive rows of one day (rows come newest first).
func conversationDays(_ rows: [ConversationRow], now: Date, calendar: Calendar) -> [ConversationDay] {
    var out: [ConversationDay] = []
    for row in rows {
        let day = historyDay(row.conversation.lastActivity, now: now, calendar: calendar)
        if out.last?.day == day { out[out.count - 1].rows.append(row) } else { out.append(ConversationDay(day: day, rows: [row])) }
    }
    return out
}

/// Every word of `query` is in one of `fields` (any case); a blank query matches all.
func sessionsMatch(_ query: String, _ fields: [String?]) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    return words.allSatisfy { w in fields.contains { $0?.localizedCaseInsensitiveContains(w) == true } }
}

enum SessionsAgentFilter: CaseIterable {
    case all, claude, codex

    func admits(_ agent: HistoryAgent) -> Bool {
        switch self {
        case .all: true
        case .claude: agent == .claude
        case .codex: agent == .codex
        }
    }
}

enum SessionsLoad: Equatable {
    case idle, loading, loaded
    /// The remote project's host can't be reached: no conversations («нет связи»).
    case offline(String)
}

enum SessionsAction: Equatable {
    case restore(UUID)
    case focus(task: UUID, tab: UUID)
    case open(Conversation, task: UUID)
    case openInNewSession(Conversation, project: UUID)
}

// MARK: Model

@MainActor @Observable final class SessionsModel {
    @ObservationIgnored let app: AppState
    var query = ""
    var agent: SessionsAgentFilter = .all
    private(set) var load: SessionsLoad = .idle
    /// Scanned conversations with the folder they were found in, newest first.
    private(set) var found: [(conversation: Conversation, folder: String)] = []
    @ObservationIgnored private var foundProject: UUID?
    @ObservationIgnored private var generation = 0
    /// Injectable for tests.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar = Calendar.current

    init(app: AppState) { self.app = app }

    var projectId: UUID? { app.sessionsProjectId }

    /// Rescans when the view opens or switches project (no watchers); a remote project reads through its host.
    func reload() async {
        guard let pid = projectId, let project = app.project(pid) else {
            found = []
            load = .idle
            return
        }
        generation += 1
        let gen = generation
        if foundProject != pid { found = [] }
        foundProject = pid
        if let host = project.host, app.remote.hosts[host]?.state != .connected {
            found = []
            load = .offline(host)
            return
        }
        load = .loading
        var out: [(conversation: Conversation, folder: String)] = []
        var seen = Set<String>()
        do {
            for folder in app.sessionFolders(pid) {
                for c in try await app.conversations(folder: folder, project: project) where seen.insert(c.agent.rawValue + c.id).inserted {
                    out.append((c, folder))
                }
            }
        } catch {
            guard gen == generation else { return }
            found = []
            load = .offline(project.host ?? "")
            return
        }
        guard gen == generation else { return }  // a newer scan (another project) owns the result
        found = out.sorted { ($0.conversation.lastActivity, $0.conversation.id) > ($1.conversation.lastActivity, $1.conversation.id) }
        load = .loaded
    }

    var closedRows: [ClosedSessionRow] {
        guard let pid = projectId else { return [] }
        return closedSessionRows(app.state.tasks, projectId: pid).filter { sessionsMatch(query, [$0.name, $0.branch]) }
    }

    var closedCount: Int { projectId.map { pid in app.state.tasks.filter { $0.projectId == pid && $0.archived }.count } ?? 0 }
    var conversationCount: Int { found.count }

    /// Open markers come from the live tabs now, not from the scan: a tab opened or closed since still shows right.
    var conversationRows: [ConversationRow] {
        guard let pid = projectId, let project = app.project(pid) else { return [] }
        let open = app.openConversationTabs
        let tasks = app.state.tasks.filter { $0.projectId == pid }.sorted { $0.order < $1.order }
        return found.compactMap { c, folder in
            guard agent.admits(c.agent) else { return nil }
            let row = ConversationRow(conversation: c, place: place(c, folder: folder, project: project, tasks: tasks, open: open))
            return sessionsMatch(query, [c.title, c.gitBranch, row.placeName]) ? row : nil
        }
    }

    var days: [ConversationDay] { conversationDays(conversationRows, now: now(), calendar: calendar) }

    private func place(_ c: Conversation, folder: String, project: Project, tasks: [HangarTask],
                       open: [String: (task: UUID, tab: UUID)]) -> ConversationPlace {
        if let o = open[c.id], let t = tasks.first(where: { $0.id == o.task }) { return .open(task: t.id, tab: o.tab, name: t.name) }
        let owners = tasks.filter { t in
            if case .worktree(let path, _, _) = t.mode { return path == folder }
            return folder == project.path
        }
        if let t = owners.first(where: { !$0.archived && !app.isHostShellTask($0.id) }) { return .session(task: t.id, name: t.name) }
        if let t = owners.first(where: \.archived) { return .closed(task: t.id, name: t.name) }
        return .none
    }

    func action(for row: ConversationRow) -> SessionsAction {
        switch row.place {
        case .open(let task, let tab, _): .focus(task: task, tab: tab)
        case .session(let task, _): .open(row.conversation, task: task)
        case .closed(let task, _): .restore(task)
        case .none: .openInNewSession(row.conversation, project: projectId ?? UUID())
        }
    }

    func closedAction(_ id: UUID) -> SessionsAction { .restore(id) }

    /// Every action ends in a selected session, which closes the view; a failed restore keeps it (with the alert).
    func perform(_ action: SessionsAction, ctx: ActionContext) async {
        switch action {
        case .restore(let id): await restoreArchivedTask(id, ctx: ctx, reselect: true)
        case .focus(let task, let tab):
            app.select(taskId: task)
            app.activate(tabId: tab)
        case .open(let c, let task):
            app.select(taskId: task)
            app.openConversation(c)
        case .openInNewSession(let c, let project):
            let name = String((c.title ?? L10n.sessionsUntitled).prefix(40))
            app.perform { s in s.select(taskId: s.addTask(projectId: project, name: name)) }
            app.openConversation(c)
        }
    }

    /// «Удалить навсегда»: the sidebar's flow with its confirmations.
    func delete(_ id: UUID, ctx: ActionContext) { Action.deletePermanently.perform(.task(id), ctx) }
}

extension ConversationRow {
    /// The session's name as the row shows it (also searched).
    var placeName: String? {
        switch place {
        case .open(_, _, let name), .session(_, let name), .closed(_, let name): name
        case .none: nil
        }
    }
}
