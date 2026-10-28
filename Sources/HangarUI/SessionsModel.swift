import AgentStatus
import Foundation
import History
import Observation
import Workspace

/// What «Сессии» lists: every project (⌘Y), one project (its row menu, the archived hint, a link) or one host's projects.
enum SessionsScope: Hashable {
    case all
    case project(UUID)
    case host(String)
}

/// «Сессии» (⌘Y, redesign-v1 §5): closed sessions and the agents' past conversations of every project (or the scope's),
/// in place of the session area.
extension AppState {
    /// ⌘Y, the sidebar row «Сессии»: all projects; `projectId` — scoped to that project (the chip resets it).
    /// It overlays the session area; the selection stays (and is saved), so Esc or a relaunch is back on that session.
    func showSessionsView(projectId: UUID? = nil) { showSessionsView(scope: projectId.map { .project($0) } ?? .all) }

    func showSessionsView(scope: SessionsScope) {
        guard !state.projects.isEmpty else { beep(); return }  // no project: nothing to show
        sessionsScope = sessionsProjects(scope).isEmpty ? .all : scope
        sessionsViewVisible = true
        didChange?()
    }

    /// Esc, ⌘Y: back to the selected session.
    func hideSessionsView() {
        guard sessionsViewVisible else { return }
        sessionsViewVisible = false
        didChange?()
    }

    func toggleSessionsView() { if sessionsViewVisible { hideSessionsView() } else { showSessionsView() } }

    /// The scope's projects in sidebar order (a host terminal's pseudo-project is never one).
    func sessionsProjects(_ scope: SessionsScope) -> [Project] {
        switch scope {
        case .all: state.projects
        case .project(let id): state.projects.filter { $0.id == id }
        case .host(let host): state.projects.filter { $0.host == host }
        }
    }

    /// Hosts of remote projects, first appearance order: the scope chip offers them.
    var sessionsHosts: [String] {
        var seen = Set<String>()
        return state.projects.compactMap(\.host).filter { seen.insert($0).inserted }
    }

    /// Where the project's conversations were recorded: its folder and every session worktree (closed ones too).
    func sessionFolders(_ projectId: UUID) -> [String] {
        guard let project = project(projectId) else { return [] }
        var out = [project.path]
        for t in state.tasks where t.projectId == projectId {
            if case .worktree(let path, _, _) = t.mode, !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// `conversationKey` → the live agent leaf holding that conversation (tabs and TERMINAL panels of open sessions,
    /// any project): «Перейти» goes there instead of resuming it a second time.
    var openConversationLeaves: [String: (task: UUID, leaf: UUID)] {
        var out: [String: (task: UUID, leaf: UUID)] = [:]
        for t in state.tasks where !t.archived {
            let host = project(t.projectId)?.host
            for leaf in t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap({ $0 }) {
                guard let agent: HistoryAgent = leaf.kind == .claude ? .claude : leaf.kind == .codex ? .codex : nil,
                      let id = validSessionId(leaf.agentSessionId) else { continue }
                let key = conversationKey(host: host, agent: agent, id: id)
                if out[key] == nil { out[key] = (t.id, leaf.id) }
            }
        }
        return out
    }
}

/// A conversation is the same one only on the same machine and agent.
func conversationKey(host: String?, agent: HistoryAgent, id: String) -> String { (host ?? "") + "\0" + agent.rawValue + "\0" + id }

/// `cwd` lies in a project nested deeper inside `project` on the same machine: the conversation is listed there only.
/// One line of a scan error for the inline note: ssh's stderr, a host that is not connected, or the timeout.
@MainActor func sessionsErrorText(_ error: Error) -> String {
    let raw: String
    switch error {
    case is SessionsTimeout: return L10n.sessionsTimedOut
    case HistoryError.remote(let text): raw = text
    default: raw = "\(error)"
    }
    let line = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    return line.isEmpty ? L10n.sessionsUnknownError : String(line.prefix(160))
}

func inDeeperProject(_ cwd: String, of project: Project, among projects: [Project]) -> Bool {
    projects.contains { p in
        p.id != project.id && p.host == project.host && p.path.count > project.path.count
            && (cwd == p.path || cwd.hasPrefix(p.path.hasSuffix("/") ? p.path : p.path + "/"))
    }
}

// MARK: Rows

struct ClosedSessionRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// «project» or «project · host»: where it is from.
    var origin = ""
    let branch: String?
    let closedAt: Date?
    let changes: LineChanges?
    /// Leaves per tab: the layout glyph draws a wider box for a split tab.
    let tabLeaves: [Int]
}

/// «shop» or «api · devbox».
func sessionsOrigin(_ project: Project) -> String { project.host.map { project.name + " · " + $0 } ?? project.name }

/// The projects' closed sessions, last closed first (those closed before the time was recorded go last).
func closedSessionRows(_ tasks: [HangarTask], projects: [Project]) -> [ClosedSessionRow] {
    let origin = Dictionary(projects.map { ($0.id, sessionsOrigin($0)) }, uniquingKeysWith: { a, _ in a })
    return tasks.filter { origin[$0.projectId] != nil && $0.archived }
        .enumerated()
        .sorted { a, b in
            let x = a.element.archivedAt ?? .distantPast, y = b.element.archivedAt ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }
        .map { _, t in
            ClosedSessionRow(id: t.id, name: t.name, origin: origin[t.projectId] ?? "", branch: t.branch, closedAt: t.archivedAt,
                             changes: t.archivedChanges, tabLeaves: t.tabs.map { $0.root.leaves.count })
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
    /// «project» or «project · host».
    var origin = ""
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
    case idle, loading
    /// Finished, also when a source failed or was offline (`SessionsModel.failures`, `offlineHosts`).
    case loaded
}

/// A source (this Mac or the project's host) that failed or did not answer in time; the others' rows still show.
struct SessionsFailure: Hashable {
    /// The host; nil — this Mac.
    let host: String?
    let message: String
    let timedOut: Bool
}

/// The scan did not answer within its source's time.
struct SessionsTimeout: Error {}

/// `op`'s result; after `limit` `op` is cancelled (a remote scan's ssh is killed, a local one stops between files) and
/// whatever it returns then is kept, flagged `timedOut` (nil if it threw). Throws `op`'s own error, or on cancellation.
func withSessionsTimeout<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> T) async throws
    -> (value: T?, timedOut: Bool) {
    try await withThrowingTaskGroup(of: (value: T?, timedOut: Bool).self) { group in
        group.addTask { (try await op(), false) }
        group.addTask { try await Task.sleep(for: limit); return (nil, true) }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { return (nil, true) }
        guard first.timedOut else { return first }
        group.cancelAll()
        let partial = try? await group.next()
        return (partial?.value, true)
    }
}

enum SessionsAction: Equatable {
    case restore(UUID)
    case focus(leaf: UUID)
    case open(Conversation, task: UUID)
    case openInNewSession(Conversation, project: UUID)
}

// MARK: Model

@MainActor @Observable final class SessionsModel {
    @ObservationIgnored let app: AppState
    var query = ""
    var agent: SessionsAgentFilter = .all
    private(set) var load: SessionsLoad = .idle
    /// Sources that failed or did not answer in time; the others' rows still show.
    private(set) var failures: [SessionsFailure] = []
    /// Hosts of scoped projects that are not connected: their conversations are not read («нет связи»).
    private(set) var offlineHosts: [String] = []
    /// Scanned conversations with the folder and project they were found in, newest first.
    private(set) var found: [Found] = []
    @ObservationIgnored private var foundScope: SessionsScope?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Injectable for tests.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar = Calendar.current
    /// Per call: a host that stops answering must not keep «Загрузка…» forever; the local scan only reads samples.
    @ObservationIgnored var remoteTimeout: Duration = .seconds(20)
    @ObservationIgnored var localTimeout: Duration = .seconds(60)
    /// The conversations of one folder; tests replace it.
    @ObservationIgnored var scan: (@MainActor @Sendable (String, Project) async throws -> [Conversation])?

    struct Found {
        var conversation: Conversation
        var folder: String
        var project: UUID
    }

    init(app: AppState) { self.app = app }

    var scope: SessionsScope { app.sessionsScope }
    var projects: [Project] { app.sessionsProjects(scope) }

    /// Rescans when the view opens or the scope changes (no watchers); remote projects read through their host.
    /// This Mac's projects go first, then each host; a host that fails or is silent past its timeout is skipped with a
    /// note (`failures`, retry), the load always finishes. Rows show as each folder is read on a first load; a rescan
    /// swaps them in at the end, so the list does not shrink and regrow.
    func reload() async {
        // One scan at a time: a new one (scope change, retry) cancels the previous, whose parsing stops between files.
        running?.cancel()
        let task = Task { await load() }
        running = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func load() async {
        generation += 1
        let gen = generation
        let scope = self.scope
        if foundScope != scope { found = [] }
        foundScope = scope
        failures = []
        offlineHosts = []
        load = .loading
        let progressive = found.isEmpty
        let all = app.state.projects
        let scoped = projects
        let scan = self.scan ?? { [app] folder, project in try await app.conversations(folder: folder, project: project) }
        var out: [Found] = []
        var seen = Set<String>()
        let sources: [String?] = [nil] + app.sessionsHosts.filter { h in scoped.contains { $0.host == h } }
        for host in sources {
            let inSource = scoped.filter { $0.host == host }
            guard !inSource.isEmpty else { continue }
            if let host, app.remote.hosts[host]?.state != .connected {
                offlineHosts.append(host)
                continue
            }
            let limit = host == nil ? localTimeout : remoteTimeout
            source: for project in inSource {
                // A scan also lists folders inside its folder: the deepest goes first, so a worktree inside the project keeps its session.
                for folder in app.sessionFolders(project.id).sorted(by: { $0.count > $1.count }) {
                    var list: [Conversation] = []
                    var failed = false
                    do {
                        let r = try await withSessionsTimeout(limit) { try await scan(folder, project) }
                        guard gen == generation, !Task.isCancelled else { return }  // a newer scan or a closed view
                        list = r.value ?? []  // a local scan cut by its timeout keeps the files it had read
                        if r.timedOut {
                            failures.append(SessionsFailure(host: host, message: sessionsErrorText(SessionsTimeout()), timedOut: true))
                            failed = true
                        }
                    } catch {
                        guard gen == generation, !Task.isCancelled else { return }
                        failures.append(SessionsFailure(host: host, message: sessionsErrorText(error), timedOut: false))
                        failed = true
                    }
                    for c in list where !inDeeperProject(c.cwd, of: project, among: all)
                        && seen.insert((host ?? "") + "\0" + c.agent.rawValue + c.id).inserted {
                        out.append(Found(conversation: c, folder: folder, project: project.id))
                    }
                    if progressive { found = newestFirst(out) }
                    // A host's other folders would fail or wait the same way; this Mac's are read independently.
                    if failed, host != nil { break source }
                }
            }
        }
        found = newestFirst(out)
        load = .loaded
    }

    private func newestFirst(_ list: [Found]) -> [Found] {
        list.sorted { ($0.conversation.lastActivity, $0.conversation.id) > ($1.conversation.lastActivity, $1.conversation.id) }
    }

    var closedRows: [ClosedSessionRow] {
        closedSessionRows(app.state.tasks, projects: projects).filter { sessionsMatch(query, [$0.name, $0.branch, $0.origin]) }
    }

    var closedCount: Int {
        let ids = Set(projects.map(\.id))
        return app.state.tasks.filter { ids.contains($0.projectId) && $0.archived }.count
    }
    var conversationCount: Int { found.count }

    /// Open markers come from the live tabs now, not from the scan: a tab opened or closed since still shows right.
    var conversationRows: [ConversationRow] {
        let open = app.openConversationLeaves
        let byId = Dictionary(app.state.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tasks = Dictionary(grouping: app.state.tasks, by: \.projectId).mapValues { $0.sorted { $0.order < $1.order } }
        return found.compactMap { f in
            guard agent.admits(f.conversation.agent), let project = byId[f.project] else { return nil }
            let row = ConversationRow(conversation: f.conversation,
                                      place: place(f.conversation, folder: f.folder, project: project, tasks: tasks[project.id] ?? [], open: open),
                                      project: project.id, origin: sessionsOrigin(project))
            return sessionsMatch(query, [f.conversation.title, f.conversation.gitBranch, row.placeName, row.origin]) ? row : nil
        }
    }

    var days: [ConversationDay] { conversationDays(conversationRows, now: now(), calendar: calendar) }

    private func place(_ c: Conversation, folder: String, project: Project, tasks: [HangarTask],
                       open: [String: (task: UUID, leaf: UUID)]) -> ConversationPlace {
        // Only a leaf holding this very conversation makes it open (or closed): a session of the same folder holds others,
        // and restoring one of those would bring back its agents, not this conversation. Open in any project counts.
        let kind: LeafKind = c.agent == .claude ? .claude : .codex
        if let o = open[conversationKey(host: project.host, agent: c.agent, id: c.id)] {
            return .open(task: o.task, leaf: o.leaf, name: app.state.tasks.first { $0.id == o.task }?.name ?? "")
        }
        if let t = tasks.first(where: { t in
            t.archived && (t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap { $0 })
                .contains { $0.kind == kind && validSessionId($0.agentSessionId) == c.id }
        }) {
            return .closed(task: t.id, name: t.name)
        }
        // Not held anywhere: a worktree's conversation resumes in a new tab of that worktree's open session; one of the
        // main folder gets a session of its own, named after it (a main-folder session holds unrelated conversations).
        let owner = tasks.first { t in
            guard !t.archived, case .worktree(let path, _, _) = t.mode else { return false }
            return path == folder
        }
        return owner.map { .session(task: $0.id, name: $0.name) } ?? .none
    }

    func action(for row: ConversationRow) -> SessionsAction {
        switch row.place {
        case .open(_, let leaf, _): .focus(leaf: leaf)
        case .session(let task, _): .open(row.conversation, task: task)
        case .closed(let task, _): .restore(task)
        case .none: .openInNewSession(row.conversation, project: row.project)
        }
    }

    func closedAction(_ id: UUID) -> SessionsAction { .restore(id) }

    /// Every action ends in a selected session, which closes the view; a failed restore keeps it (with the alert).
    func perform(_ action: SessionsAction, ctx: ActionContext) async {
        switch action {
        case .restore(let id): await restoreArchivedTask(id, ctx: ctx, reselect: true)
        case .focus(let leaf):
            app.reveal(leafId: leaf)  // its tab, or the TERMINAL panel it is in
            app.hideSessionsView()
        case .open(let c, let task):
            app.select(taskId: task)
            app.openConversation(c)
        case .openInNewSession(let c, let project):
            // The id comes from a file: an invalid one opens nothing (not an empty session).
            guard validSessionId(c.id) != nil else { app.beep(); return }
            let name = sessionName(c.title)
            app.perform { s in s.select(taskId: s.addTask(projectId: project, name: name)) }
            app.openConversation(c)
        }
    }

    /// «Удалить навсегда»: the sidebar's flow with its confirmations.
    func delete(_ id: UUID, ctx: ActionContext) { Action.deletePermanently.perform(.task(id), ctx) }
}

/// A new session's name from a conversation title (file content): one safe line, at most 40 characters.
@MainActor func sessionName(_ title: String?) -> String {
    let clean = title.flatMap(conversationTitle) ?? L10n.sessionsUntitled
    return clean.count > 40 ? String(clean.prefix(39)) + "…" : clean
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
