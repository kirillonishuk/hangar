import AgentStatus
import Foundation
import Workspace

/// Russian plural category (en uses one/other: its few and many strings are the same).
enum PluralForm: Equatable { case one, few, many }

func pluralForm(_ n: Int) -> PluralForm {
    let n10 = abs(n) % 10, n100 = abs(n) % 100
    if n10 == 1 && n100 != 11 { return .one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return .few }
    return .many
}

/// A chat row's tooltip: «ждёт · 1 агент», «работает · 2 субагента», «нет агентов · 1 вкладка».
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
    /// `limitUntil`: the reset time of a reached limit («лимит · до 20:20»), when known.
    init(state: AgentState, agents: Int, subagents: Int, tabs: Int, limitUntil: String? = nil) {
        guard agents > 0 else {
            self.init(head: L10n.noAgents, tail: L10n.tabCount(tabs), tone: .normal)
            return
        }
        let tone: Tone = state == .waiting || state == .limit ? .waiting : state == .failed ? .failed : .normal
        let head = state == .limit ? limitUntil.map(L10n.limitUntil) ?? L10n.statusLabel(.limit) : L10n.rowStatus(state)
        self.init(head: head, tail: subagents > 0 ? L10n.subagentCount(subagents) : L10n.agentCount(agents), tone: tone)
    }

    var text: String { "\(head) · \(tail)" }
}

/// A folded project's row: the most urgent state among its sessions and how many sessions are in it.
struct FoldedProjectBadge: Equatable {
    var state: AgentState
    var count: Int
}

/// waiting > limit > error > working; nil when no session is in any of them.
func foldedProjectBadge(_ states: [AgentState]) -> FoldedProjectBadge? {
    for p in [AgentState.waiting, .limit, .failed, .working] {
        let n = states.filter { $0 == p }.count
        if n > 0 { return FoldedProjectBadge(state: p, count: n) }
    }
    return nil
}

extension AppState {
    /// The row's status line from the task's agent leaves (tabs and the TERMINAL drawer).
    func sessionStatus(of task: HangarTask) -> SessionStatus {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        let agents = leaves.filter { $0.kind == .claude || $0.kind == .codex }
        let subagents = agents.reduce(0) { $0 + statusSummary(ofLeaf: $1.id).subagents }
        let state = displayState(of: task)
        return SessionStatus(state: state, agents: agents.count, subagents: subagents, tabs: task.tabs.count,
                             limitUntil: state == .limit ? limitClock(of: agents) : nil)
    }

    func foldedBadge(of projectId: UUID) -> FoldedProjectBadge? {
        foldedProjectBadge(state.tasks(in: projectId).map { displayState(of: $0) })
    }
}
