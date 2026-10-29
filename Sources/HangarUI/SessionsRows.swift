import Foundation
import History
import Workspace

// «Сессии» v2 (#107, sessions-v2.html variant A): one list grouped by project; a row is a conversation or an archived
// session without conversations; its state is a word.

/// What «Сессии» lists: every project (⌘Y), this Mac's or one host's. A project's «Сессии проекта» is «Все» plus its
/// name in the search (no project scope).
enum SessionsScope: Hashable {
    case all
    case local
    case host(String)
}

/// Whether a host's conversations can be read now: connected, on its way (a spinner, not «нет связи»), or not.
enum SessionsHostLink: Equatable {
    case connected, connecting, offline
}

/// Connecting, or reconnecting with a retry under way, is not «нет связи» yet; given up, paused or never connected is.
func sessionsHostLink(_ info: HostInfo?) -> SessionsHostLink {
    switch info?.state {
    case .connected: .connected
    case .connecting: .connecting
    case .reconnecting: info?.retryPaused == true ? .offline : .connecting
    case .disconnected, .unreachable, nil: .offline
    }
}

/// A row's state word: «открыт» (a live leaf holds it), «в архиве» (an archived session holds it, or is the row),
/// «в истории» (only in the agent's files).
enum SessionsRowState: Hashable, CaseIterable {
    case open, archived, history
}

/// An archived session that holds no listed conversation: its own row with «Восстановить».
struct ClosedSessionRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let project: UUID
    /// A worktree session's branch; nil in the main folder.
    let branch: String?
    let archivedAt: Date?
    let tabs: Int
}

/// The projects' archived sessions, last archived first (those archived before the time was recorded go last).
func closedSessionRows(_ tasks: [HangarTask], projects: [Project]) -> [ClosedSessionRow] {
    let ids = Set(projects.map(\.id))
    return tasks.filter { ids.contains($0.projectId) && $0.archived }
        .enumerated()
        .sorted { a, b in
            let x = a.element.archivedAt ?? .distantPast, y = b.element.archivedAt ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }
        .map { _, t in
            let branch: String? = if case .worktree(_, let b, _) = t.mode { b } else { nil }
            return ClosedSessionRow(id: t.id, name: t.name, project: t.projectId, branch: branch, archivedAt: t.archivedAt, tabs: t.tabs.count)
        }
}

/// The session a conversation belongs to.
enum ConversationPlace: Equatable {
    /// Already running in this leaf (a tab's pane or a TERMINAL panel).
    case open(task: UUID, leaf: UUID, name: String)
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
    var project = UUID()
    /// The folder it was found in: the project's main folder or a session worktree.
    var folder = ""
    /// The project's main folder: a row found elsewhere was in a worktree (⎇).
    var projectPath = ""
    var id: String { conversation.agent.rawValue + ":" + conversation.id }
    var isOpen: Bool { if case .open = place { true } else { false } }
    var inWorktree: Bool { folder != projectPath }

    var state: SessionsRowState {
        switch place {
        case .open: .open
        case .closed: .archived
        case .session, .none: .history
        }
    }

    /// The session's name (tooltip, also searched).
    var placeName: String? {
        switch place {
        case .open(_, _, let name), .session(_, let name), .closed(_, let name): name
        case .none: nil
        }
    }
}

/// One row of a group.
enum SessionsItem: Identifiable, Equatable {
    case conversation(ConversationRow)
    case session(ClosedSessionRow)

    var id: String {
        switch self {
        case .conversation(let r): r.id
        case .session(let r): "session:" + r.id.uuidString
        }
    }

    /// Last activity, or when the session was archived.
    var date: Date {
        switch self {
        case .conversation(let r): r.conversation.lastActivity
        case .session(let r): r.archivedAt ?? .distantPast
        }
    }

    var state: SessionsRowState {
        switch self {
        case .conversation(let r): r.state
        case .session: .archived
        }
    }

    /// The archived session «Восстановить» and the trash act on.
    var archivedTask: UUID? {
        switch self {
        case .conversation(let r): if case .closed(let t, _) = r.place { t } else { nil }
        case .session(let r): r.id
        }
    }
}

/// What a group says under its rows about its host: still reading, failed or not connected.
enum SessionsNote: Equatable {
    case loading
    case failed(SessionsFailure)
    case offline
}

/// A project's rows, newest first; the host is named in the heading only for the scope «Все» (no repeats, #106).
struct SessionsGroup: Identifiable, Equatable {
    let id: UUID
    let name: String
    let host: String?
    var items: [SessionsItem]
    var note: SessionsNote?
}

/// The list area's centered state instead of rows.
enum SessionsPlaceholder: Equatable {
    case loading
    case offline(String)
    case empty
    case noMatch
}

/// Every word of `query` is in one of `fields` (any case); a blank query matches all.
func sessionsMatch(_ query: String, _ fields: [String?]) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    return words.allSatisfy { w in fields.contains { $0?.localizedCaseInsensitiveContains(w) == true } }
}

/// The chips: no agent and no state chosen admit everything. An archived session row has no agent, so a chosen agent hides it.
func sessionsAdmits(_ item: SessionsItem, agents: Set<HistoryAgent>, states: Set<SessionsRowState>) -> Bool {
    guard states.isEmpty || states.contains(item.state) else { return false }
    switch item {
    case .conversation(let r): return agents.isEmpty || agents.contains(r.conversation.agent)
    case .session: return agents.isEmpty
    }
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

/// A project nested deeper inside `project` on the same machine holds `cwd`: the conversation is listed there only.
func inDeeperProject(_ cwd: String, of project: Project, among projects: [Project]) -> Bool {
    projects.contains { p in
        p.id != project.id && p.host == project.host && p.path.count > project.path.count
            && (cwd == p.path || cwd.hasPrefix(p.path.hasSuffix("/") ? p.path : p.path + "/"))
    }
}

/// A conversation is the same one only on the same machine and agent.
func conversationKey(host: String?, agent: HistoryAgent, id: String) -> String { (host ?? "") + "\0" + agent.rawValue + "\0" + id }
