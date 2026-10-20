import AgentStatus
import ControlServer
import CoreServices
import Foundation
import Usage
import Workspace

/// Agent statuses, session ids and limits: control-socket messages and terminal fallbacks land here.
extension AppState {
    /// Leaves of unarchived tasks (tabs + TERMINAL panel).
    var liveLeafIds: Set<UUID> {
        Set(state.tasks.filter { !$0.archived }.flatMap { t in t.tabs.flatMap(\.root.leaves).map(\.id) + [t.drawer.leaf?.id].compactMap { $0 } })
    }

    /// Trust boundary: ids come from any local process, so the leaf must belong to `tab` of a live task.
    public func handle(_ message: ControlMessage) {
        switch message {
        case let .event(e):
            guard let leaf = liveLeaf(e.leaf, tab: e.tab) else { return }
            // Stored before `apply`: onTransition builds the notification body from it, and a stale one must not outlive its event.
            lastNotificationMessage[leaf.id] = e.message
            apply(.hook(e.kind, session: e.session, notificationType: e.notificationType), leaf: leaf.id)
            let agent: LeafKind = e.kind == .codexNotify ? .codex : .claude
            if leaf.kind == agent, let id = validSessionId(e.session), leaf.agentSessionId != id {
                perform { $0.setAgentSessionId(leafId: leaf.id, id) }
            }
            switch e.kind {
            case .stopFailure: alert(usage.markLimitReached(.claude, now: Date()))
            case .codexNotify: onCodexTurn?()
            default: break
            }
        case let .usage(u):
            // shortcut: codex limits come from its app-server (Task 11), not the socket
            guard u.agent == UsageAgent.claude.rawValue else { return }
            let now = Date()
            alert(usage.update(.claude, windows: claudeWindows(u.windows, now: now), plan: nil, now: now))
        }
    }

    /// Terminal-side signals; bell/OSC notifications mean "waiting" only for agent leaves.
    func signal(_ signal: AgentSignal, leaf leafId: UUID) {
        guard let leaf = liveLeaf(leafId, tab: nil) else { return }
        if signal == .bell || signal == .desktopNotification, leaf.kind == .shell || leaf.kind == .editor { return }
        apply(signal, leaf: leafId)
    }

    func state(ofLeaf id: UUID) -> AgentState { statuses.status(id).state }

    func state(of tab: Tab) -> AgentState { taskState(tab.root.leaves.map { state(ofLeaf: $0.id) }) }

    func state(of task: HangarTask) -> AgentState {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        return taskState(leaves.map { state(ofLeaf: $0.id) })
    }

    /// Like `state`, but an agent leaf whose agent is out of limit shows as failed.
    func displayState(ofLeaf id: UUID, kind: LeafKind, now: Date = Date()) -> AgentState {
        let st = state(ofLeaf: id)
        let agent: UsageAgent? = kind == .claude ? .claude : kind == .codex ? .codex : nil
        if let agent, usage.level(agent, now: now) == .full { return .failed }
        return st
    }

    func displayState(of tab: Tab, now: Date = Date()) -> AgentState {
        taskState(tab.root.leaves.map { displayState(ofLeaf: $0.id, kind: $0.kind, now: now) })
    }

    func displayState(of task: HangarTask, now: Date = Date()) -> AgentState {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        return taskState(leaves.map { displayState(ofLeaf: $0.id, kind: $0.kind, now: now) })
    }

    /// Agent tabs always show a dot; other tabs only when something is going on.
    func showsDot(_ tab: Tab, state: AgentState) -> Bool {
        state != .idle || tab.root.leaves.contains { $0.kind == .claude || $0.kind == .codex }
    }

    var workingLeafCount: Int { statuses.workingCount }

    private func apply(_ signal: AgentSignal, leaf: UUID) {
        if let t = statuses.apply(signal, leaf: leaf) { onTransition?(t) }
    }

    private func alert(_ alerts: [UsageAlert]) {
        if !alerts.isEmpty { onUsageAlerts?(alerts) }
    }

    /// The leaf of an unarchived task; with `tab`, it must be in that tab (a panel leaf is its own tab).
    private func liveLeaf(_ id: UUID, tab: UUID?) -> Leaf? {
        for task in state.tasks where !task.archived {
            if let leaf = task.drawer.leaf, leaf.id == id { return tab == nil || tab == id ? leaf : nil }
            for t in task.tabs where tab == nil || t.id == tab {
                if let leaf = t.root.leaf(id: id) { return leaf }
            }
        }
        return nil
    }
}

/// Alert texts for quitting while agents work; nil when none do.
@MainActor func quitConfirmation(working: Int) -> (message: String, info: String)? {
    working > 0 ? (L10n.agentsWorking(working), L10n.agentsWorkingInfo) : nil
}

public enum QuitDecision: Equatable, Sendable {
    case terminateNow, ask(Int), cancelCreating
}

/// Logout / restart / shutdown quit reasons (`kAEQuitReason` of the quit Apple event).
public func isSystemShutdown(reason: OSType?) -> Bool {
    guard let reason else { return false }
    return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        .contains { OSType($0) == reason }
}

/// A system-initiated quit never asks (the user chose it, state is saved anyway); otherwise a worktree being
/// created wins (quitting would leave it half-made); then working agents, unless already confirmed.
public func quitDecision(creating: Bool, working: Int, confirmed: Bool, systemShutdown: Bool) -> QuitDecision {
    if systemShutdown { return .terminateNow }
    if creating { return .cancelCreating }
    return working > 0 && !confirmed ? .ask(working) : .terminateNow
}
