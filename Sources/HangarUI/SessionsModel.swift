import AgentStatus
import Foundation
import History
import Observation
import Workspace

/// «Сессии» (⌘Y, #107): the agents' past conversations and archived sessions of every project (or the scope's), by project,
/// in place of the session area.
extension AppState {
    /// ⌘Y, the sidebar row «Сессии»: all projects; `projectId` (its menu, the archived hint, a link) — all projects with
    /// its name in the search. It overlays the session area; the selection stays (and is saved), so Esc or a relaunch is
    /// back on that session.
    func showSessionsView(projectId: UUID? = nil) {
        showSessionsView(scope: .all)
        // A host terminal's pseudo-project is no project: all of them.
        if sessionsViewVisible, state.projects.contains(where: { $0.id == projectId }) {
            // Only that project: no stale search or chips hiding its rows.
            sessionsProject = projectId
            sessionsQuery = ""
            sessionsAgents = []
            sessionsStates = []
        }
    }

    /// A scope from ⌘Y or the segment: every project of it (the project chip goes).
    func showSessionsView(scope: SessionsScope) {
        guard !state.projects.isEmpty else { beep(); return }  // no project: nothing to show
        sessionsProject = nil
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
        case .local: state.projects.filter { $0.host == nil }
        case .host(let host): state.projects.filter { $0.host == host }
        }
    }

    /// Hosts of remote projects, first appearance order: the scope segment offers them.
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
    /// The search text lives in `AppState` (the debug channel sets it too).
    var query: String {
        get { app.sessionsQuery }
        set { app.sessionsQuery = newValue }
    }
    /// The chips (multi-select; none chosen admits all); in `AppState`, so «Сессии проекта» clears them.
    var agents: Set<HistoryAgent> {
        get { app.sessionsAgents }
        set { app.sessionsAgents = newValue }
    }
    var states: Set<SessionsRowState> {
        get { app.sessionsStates }
        set { app.sessionsStates = newValue }
    }
    /// Collapsed groups, and groups showing all rows instead of the first `Theme.sessionsGroupLimit`.
    var collapsed: Set<UUID> = []
    var expanded: Set<UUID> = []
    /// The keyboard's row (↑↓, ↩) and the pointer's: their actions show. In `AppState`, cleared whenever the view hides.
    var selection: String? {
        get { app.sessionsPointer?.selection }
        set { app.sessionsPointer = SessionsPointer(selection: newValue, hovered: app.sessionsPointer?.hovered) }
    }
    var hovered: String? {
        get { app.sessionsPointer?.hovered }
        set { app.sessionsPointer = SessionsPointer(selection: app.sessionsPointer?.selection, hovered: newValue) }
    }
    private(set) var load: SessionsLoad = .idle
    /// Sources that failed or did not answer in time; the others' rows still show.
    private(set) var failures: [SessionsFailure] = []
    /// Hosts of scoped projects that are not connected: their conversations are not read («нет связи»).
    private(set) var offlineHosts: [String] = []
    /// Hosts still connecting: their groups show the spinner until they connect (then a rescan) or give up.
    private(set) var connectingHosts: [String] = []
    /// Hosts still being read on a first load (its groups say so); a rescan swaps the list in at the end instead.
    private(set) var pendingHosts: Set<String> = []
    /// Scanned conversations with the folder and project they were found in, newest first.
    private(set) var found: [Found] = [] {
        didSet { foundVersion &+= 1 }
    }
    @ObservationIgnored private var foundVersion = 0
    /// The rows and groups of the last inputs: a body asks for them many times, a hover or selection changes none.
    @ObservationIgnored private var cache: (key: ListKey, list: List)?
    @ObservationIgnored private var foundKey: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Injectable for tests.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar = Calendar.current
    /// Per call: a host that stops answering must not keep «Загрузка…» forever; the local scan only reads samples.
    @ObservationIgnored var remoteTimeout: Duration = .seconds(20)
    @ObservationIgnored var localTimeout: Duration = .seconds(60)
    /// A host's link; tests replace it.
    @ObservationIgnored lazy var hostLink: (String) -> SessionsHostLink = { [app] in sessionsHostLink(app.remote.hosts[$0]) }
    /// The conversations of one folder; tests replace it.
    @ObservationIgnored var scan: (@MainActor @Sendable (String, Project) async throws -> [Conversation])?

    struct Found {
        var conversation: Conversation
        var folder: String
        var project: UUID
    }

    init(app: AppState) { self.app = app }

    /// The chosen scope while it has projects; «Все» once a host's last project is gone.
    var scope: SessionsScope { app.sessionsProjects(app.sessionsScope).isEmpty ? .all : app.sessionsScope }
    /// The project chip's project while it exists.
    var project: Project? { app.sessionsProject.flatMap { id in app.state.projects.first { $0.id == id } } }
    /// The scope's projects, or only the chip's.
    var projects: [Project] { project.map { [$0] } ?? app.sessionsProjects(scope) }

    /// Shown or hidden: no row stays drawn hovered or chosen from the last visit.
    func clearPointer() { app.sessionsPointer = nil }

    /// The chip's «×»: every project of the scope again.
    func clearProject() { app.sessionsProject = nil }

    /// What the list was read for: a different one starts empty and fills in as it is read.
    var loadKey: String { "\(scope)|\(project?.id.uuidString ?? "")" }

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
        let key = loadKey
        if foundKey != key { found = [] }
        foundKey = key
        failures = []
        offlineHosts = []
        connectingHosts = []
        load = .loading
        let progressive = found.isEmpty
        let all = app.state.projects
        let scoped = projects
        let scan = self.scan ?? { [app] folder, project in try await app.conversations(folder: folder, project: project) }
        var out: [Found] = []
        var seen = Set<String>()
        let sources: [String?] = [nil] + app.sessionsHosts.filter { h in scoped.contains { $0.host == h } }
        pendingHosts = progressive ? Set(sources.compactMap { $0 }.filter { hostLink($0) == .connected }) : []
        for host in sources {
            let inSource = scoped.filter { $0.host == host }
            guard !inSource.isEmpty else { continue }
            if let host {
                switch hostLink(host) {
                case .connected: break
                case .connecting: connectingHosts.append(host); continue
                case .offline: offlineHosts.append(host); continue
                }
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
            if let host { pendingHosts.remove(host) }
        }
        found = newestFirst(out)
        pendingHosts = []
        load = .loaded
    }

    private func newestFirst(_ list: [Found]) -> [Found] {
        list.sorted { ($0.conversation.lastActivity, $0.conversation.id) > ($1.conversation.lastActivity, $1.conversation.id) }
    }

    // MARK: Rows and groups

    /// Everything the rows depend on; reading it also registers the view's observation of each part.
    private struct ListKey: Equatable {
        var found: Int
        var state: WorkspaceState
        var agents: Set<HistoryAgent>
        var states: Set<SessionsRowState>
        var query: String
        var projects: [UUID]
        var offline: [String], connecting: [String], pending: Set<String>, failures: [SessionsFailure]
    }

    private struct List {
        var conversations: [ConversationRow]
        var closed: [ClosedSessionRow]
        var groups: [SessionsGroup]
    }

    private var list: List {
        let key = ListKey(found: foundVersion, state: app.state, agents: agents, states: states, query: query,
                          projects: projects.map(\.id), offline: offlineHosts, connecting: connectingHosts, pending: pendingHosts,
                          failures: failures)
        _ = found.count  // observed: a rescan's rows redraw the list
        if let cache, cache.key == key { return cache.list }
        let list = makeList()
        cache = (key, list)
        return list
    }

    private func makeList() -> List {
        let all = allConversationRows()
        let conversations = all.filter { admits(.conversation($0)) }
        // A session shows through its listed conversations; when the chips or the search hide them, it is its own row again.
        let held = Set(conversations.compactMap { r -> UUID? in if case .closed(let t, _) = r.place { t } else { nil } })
        let closed = closedSessionRows(app.state.tasks, projects: projects).filter { !held.contains($0.id) && admits(.session($0)) }
        let items = conversations.map(SessionsItem.conversation) + closed.map(SessionsItem.session)
        let byProject = Dictionary(grouping: items, by: projectOf)
        let groups = projects.compactMap { p -> SessionsGroup? in
            let rows = (byProject[p.id] ?? []).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            let note = p.host.flatMap(note(host:))
            guard !rows.isEmpty || note != nil else { return nil }
            return SessionsGroup(id: p.id, name: p.name, host: p.host, items: rows, note: note)
        }
        return List(conversations: conversations, closed: closed, groups: groups)
    }

    /// Every scanned conversation with its place; open markers come from the live tabs now, not from the scan.
    private func allConversationRows() -> [ConversationRow] {
        let open = app.openConversationLeaves
        let byId = Dictionary(app.state.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(app.state.tasks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let ordered = app.state.tasks.sorted { $0.order < $1.order }
        // Archived sessions by the conversations their agents hold (project, agent, id), first in sidebar order: one pass.
        var archived: [String: HangarTask] = [:]
        for t in ordered where t.archived {
            for leaf in t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap({ $0 }) {
                guard let agent: HistoryAgent = leaf.kind == .claude ? .claude : leaf.kind == .codex ? .codex : nil,
                      let id = validSessionId(leaf.agentSessionId) else { continue }
                let key = t.projectId.uuidString + "\0" + agent.rawValue + "\0" + id
                if archived[key] == nil { archived[key] = t }
            }
        }
        // Open worktree sessions by folder: a worktree's conversation resumes in a new tab there.
        var worktrees: [String: HangarTask] = [:]
        for t in ordered where !t.archived {
            if case .worktree(let path, _, _) = t.mode, worktrees[t.projectId.uuidString + "\0" + path] == nil {
                worktrees[t.projectId.uuidString + "\0" + path] = t
            }
        }
        return found.compactMap { f in
            guard let project = byId[f.project] else { return nil }
            let c = f.conversation
            // Only a leaf holding this very conversation makes it open (or archived): a session of the same folder holds
            // others, and restoring one of those would bring back its agents, not this one. Open in any project counts.
            let place: ConversationPlace
            if let o = open[conversationKey(host: project.host, agent: c.agent, id: c.id)] {
                place = .open(task: o.task, leaf: o.leaf, name: names[o.task] ?? "")
            } else if let t = archived[project.id.uuidString + "\0" + c.agent.rawValue + "\0" + c.id] {
                place = .closed(task: t.id, name: t.name)
            } else if let t = worktrees[project.id.uuidString + "\0" + f.folder] {
                place = .session(task: t.id, name: t.name)
            } else {
                // Not held anywhere, main folder: a session of its own, named after it.
                place = .none
            }
            return ConversationRow(conversation: c, place: place, project: project.id, folder: f.folder, projectPath: project.path)
        }
    }

    /// Conversations past the chips and the search, newest first.
    var conversationRows: [ConversationRow] { list.conversations }

    /// Archived sessions none of whose listed conversations shows them: their own rows.
    var closedRows: [ClosedSessionRow] { list.closed }

    /// The scope's projects in sidebar order, each with its rows (newest first) and its host's note; a project with
    /// neither is left out.
    var groups: [SessionsGroup] { list.groups }

    var isFiltering: Bool {
        !agents.isEmpty || !states.isEmpty || project != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func admits(_ item: SessionsItem) -> Bool {
        guard sessionsAdmits(item, agents: agents, states: states), let p = app.project(projectOf(item)) else { return false }
        switch item {
        case .conversation(let r):
            let c = r.conversation
            return sessionsMatch(query, [c.title, c.gitBranch, r.placeName, p.name, p.host])
        case .session(let r):
            return sessionsMatch(query, [r.name, r.branch, p.name, p.host])
        }
    }

    private func projectOf(_ item: SessionsItem) -> UUID {
        switch item {
        case .conversation(let r): r.project
        case .session(let r): r.project
        }
    }

    private func note(host: String) -> SessionsNote? {
        if offlineHosts.contains(host) { return .offline }
        if let f = failures.first(where: { $0.host == host }) { return .failed(f) }
        return pendingHosts.contains(host) || connectingHosts.contains(host) ? .loading : nil
    }

    /// This Mac's scan failed or timed out: one note above the groups.
    var localFailure: SessionsFailure? { failures.first { $0.host == nil } }

    /// Nothing to list: why, centered. A chosen host without connection says so unless it has archived sessions to list.
    var placeholder: SessionsPlaceholder? {
        let g = groups
        let noRows = g.allSatisfy { $0.items.isEmpty }
        if case .host(let h) = scope, offlineHosts.contains(h), noRows { return .offline(h) }
        guard noRows, localFailure == nil else { return nil }
        // A search that found nothing says so even if a host's note is pending; without one, the notes say why it is empty.
        if isFiltering, load == .loaded { return .noMatch }
        guard g.isEmpty else { return nil }
        if load != .loaded { return .loading }
        return isFiltering ? .noMatch : .empty
    }

    /// The rows a group shows: none when collapsed, the first `Theme.sessionsGroupLimit` until «Показать ещё N».
    func visibleItems(_ g: SessionsGroup) -> [SessionsItem] {
        if collapsed.contains(g.id) { return [] }
        return expanded.contains(g.id) ? g.items : Array(g.items.prefix(Theme.sessionsGroupLimit))
    }

    func hiddenCount(_ g: SessionsGroup) -> Int { collapsed.contains(g.id) ? 0 : g.items.count - visibleItems(g).count }

    func toggleCollapsed(_ id: UUID) { if collapsed.remove(id) == nil { collapsed.insert(id) } }

    func toggle(_ agent: HistoryAgent) { if agents.remove(agent) == nil { agents.insert(agent) } }

    func toggle(_ state: SessionsRowState) { if states.remove(state) == nil { states.insert(state) } }

    /// «Сбросить» resets the agent and state chips; «Сбросить фильтры» (nothing found) the project chip and the search too.
    func resetChips() {
        agents = []
        states = []
    }

    func resetFilters() {
        resetChips()
        clearProject()
        query = ""
    }

    // MARK: Keyboard

    /// The rows on screen, top to bottom.
    var visibleList: [SessionsItem] { groups.flatMap(visibleItems) }

    /// ↑↓: the next row (the first one when none is chosen).
    func step(by delta: Int) {
        let ids = visibleList.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap(ids.firstIndex) else { selection = delta > 0 ? ids.first : ids.last; return }
        selection = ids[max(0, min(ids.count - 1, current + delta))]
    }

    /// ↩: the chosen row's main action.
    func activateSelection() -> SessionsAction? {
        guard let item = visibleList.first(where: { $0.id == selection }), canRun(item) else { return nil }
        return primaryAction(item)
    }

    // MARK: Actions

    func action(for row: ConversationRow) -> SessionsAction {
        switch row.place {
        case .open(_, let leaf, _): .focus(leaf: leaf)
        case .session(let task, _): .open(row.conversation, task: task)
        case .closed(let task, _): .restore(task)
        case .none: .openInNewSession(row.conversation, project: row.project)
        }
    }

    /// The row's one main action: «Перейти», «Восстановить» or «Продолжить».
    func primaryAction(_ item: SessionsItem) -> SessionsAction {
        switch item {
        case .conversation(let r): action(for: r)
        case .session(let r): .restore(r.id)
        }
    }

    /// The host an archived session restores on is not connected: «Восстановить» waits (`offlineHost` says why).
    func offlineHost(_ item: SessionsItem) -> String? {
        guard item.archivedTask != nil, let host = app.project(projectOf(item))?.host,
              app.remote.hosts[host]?.state != .connected else { return nil }
        return host
    }

    func canRun(_ item: SessionsItem) -> Bool { offlineHost(item) == nil }

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
