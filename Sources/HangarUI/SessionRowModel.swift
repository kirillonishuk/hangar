import AgentStatus
import Foundation
import Git
import Observation
import Workspace

/// Russian plural category (en uses one/other: its few and many strings are the same).
enum PluralForm: Equatable { case one, few, many }

func pluralForm(_ n: Int) -> PluralForm {
    let n10 = abs(n) % 10, n100 = abs(n) % 100
    if n10 == 1 && n100 != 11 { return .one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return .few }
    return .many
}

/// Second line of a session row: «ждёт · 1 агент», «работает · 2 субагента», «нет агентов · 1 вкладка».
/// `head` is coloured by `tone` (waiting / failed), the rest is `text2`.
@MainActor struct SessionStatus: Equatable {
    enum Tone: Equatable { case normal, waiting, failed }

    var head: String
    var tail: String
    var tone: Tone

    init(head: String, tail: String, tone: Tone) {
        self.head = head
        self.tail = tail
        self.tone = tone
    }

    /// Running subagents replace the agent count; without agent tabs the tab count is shown.
    init(state: AgentState, agents: Int, subagents: Int, tabs: Int) {
        guard agents > 0 else {
            self.init(head: L10n.noAgents, tail: L10n.tabCount(tabs), tone: .normal)
            return
        }
        let tone: Tone = state == .waiting ? .waiting : state == .failed ? .failed : .normal
        self.init(head: L10n.rowStatus(state), tail: subagents > 0 ? L10n.subagentCount(subagents) : L10n.agentCount(agents), tone: tone)
    }

    var text: String { "\(head) · \(tail)" }
}

/// `+N −M` of a session's worktree; nil when nothing changed (no badge) or not loaded yet.
struct DiffBadge: Equatable {
    var added: String
    var deleted: String

    init(added: String, deleted: String) {
        self.added = added
        self.deleted = deleted
    }

    init?(_ stat: DiffStat?) {
        guard let stat, stat.files > 0 || stat.added > 0 || stat.deleted > 0 else { return nil }
        self.init(added: "+\(stat.added)", deleted: "−\(stat.deleted)")
    }
}

/// Per-session `diffStat` cache: loaded when a row first shows, reloaded only on the inspector's refreshes and
/// `done` events (no polling). One load per session at a time; a refresh during it reruns once. A failed load keeps the last value.
@MainActor @Observable final class SessionBadges {
    typealias Load = @MainActor () async -> DiffStat?

    private(set) var stats: [UUID: DiffStat] = [:]
    @ObservationIgnored private var requested: Set<UUID> = []
    @ObservationIgnored private var loads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<UUID> = []

    /// First show of the row: loads once.
    func request(_ id: UUID, load: @escaping Load) {
        guard requested.insert(id).inserted else { return }
        start(id, load)
    }

    /// Reloads a session whose row was shown; others load when they show.
    func refresh(_ id: UUID, load: @escaping Load) {
        guard requested.contains(id) else { return }
        if loads[id] != nil { again.insert(id) } else { start(id, load) }
    }

    /// Tests: waits for the session's load (and its rerun).
    func idle(_ id: UUID) async {
        while let task = loads[id] { await task.value }
    }

    private func start(_ id: UUID, _ load: @escaping Load) {
        loads[id] = Task { [weak self] in
            let stat = await load()
            guard let self else { return }
            if let stat, self.stats[id] != stat { self.stats[id] = stat }
            self.loads[id] = nil
            if self.again.remove(id) != nil { self.start(id, load) }
        }
    }
}

extension AppState {
    /// The row's status line from the task's agent leaves (tabs and the TERMINAL drawer).
    func sessionStatus(of task: HangarTask) -> SessionStatus {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        let agents = leaves.filter { $0.kind == .claude || $0.kind == .codex }
        let subagents = agents.reduce(0) { $0 + statusSummary(ofLeaf: $1.id).subagents }
        return SessionStatus(state: displayState(of: task), agents: agents.count, subagents: subagents, tabs: task.tabs.count)
    }

    func diffBadge(of task: HangarTask) -> DiffBadge? { DiffBadge(sessionBadges.stats[task.id]) }

    /// A worktree session's row appeared: its `+N −M` loads once.
    func requestBadge(_ task: HangarTask) {
        guard case .worktree = task.mode else { return }
        sessionBadges.request(task.id, load: badgeLoad(task.id))
    }

    /// The inspector reloaded this session's changes, or one of its agents is done.
    func refreshBadge(taskId: UUID) { sessionBadges.refresh(taskId, load: badgeLoad(taskId)) }

    func refreshBadge(ofLeaf leaf: UUID) {
        let task = state.tasks.first { t in t.tabs.contains { $0.root.leaf(id: leaf) != nil } || t.drawer.leaf?.id == leaf }
        if let task { refreshBadge(taskId: task.id) }
    }

    /// As the inspector's Changes: the worktree (a local subfolder project: that subfolder) against the base branch.
    private func badgeLoad(_ id: UUID) -> SessionBadges.Load {
        { [weak self] in
            guard let self, let task = self.state.tasks.first(where: { $0.id == id }), !task.archived,
                  case .worktree(let path, _, _) = task.mode, let project = self.project(task.projectId),
                  self.isAvailable(project) else { return nil }
            var root = path
            if project.host == nil, let sub = subfolderInRepository(project.path), FileManager.default.fileExists(atPath: path + "/" + sub) {
                root = path + "/" + sub
            }
            let base = await self.baseBranch(of: task) ?? ""
            return try? await self.git(for: project, repo: root).diffStat(base: base)
        }
    }
}
