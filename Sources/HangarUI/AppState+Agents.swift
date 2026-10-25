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
            guard let leaf = liveLeaf(e.leaf, tab: e.tab),
                  acceptsHook(statuses.status(leaf.id), kind: e.kind, session: e.session, source: e.source, agent: sessionAgent(leaf.kind)) else { return }
            // Stored before `apply`: onTransition builds the notification body from it, and a stale one must not outlive its event.
            if lastNotificationMessage[leaf.id] != e.message { lastNotificationMessage[leaf.id] = e.message }
            apply(.hook(e.kind, session: e.session, notificationType: e.notificationType, source: e.source), leaf: leaf)
            let agent: LeafKind = e.kind == .codexNotify ? .codex : .claude
            if leaf.kind == agent, let id = validSessionId(e.session), leaf.agentSessionId != id {
                perform { $0.setAgentSessionId(leafId: leaf.id, id) }
            }
            switch e.kind {
            case .stopFailure:
                tickUsageClock()
                alert(usage.markLimitReached(.claude, now: usageClock))
            case .codexNotify: onCodexTurn?()
            default: break
            }
        case .request:
            break // served by the request router (stage 5), never reaches the hook handler
        case let .usage(u):
            // shortcut: codex limits come from its app-server (Task 11), not the socket
            guard u.agent == UsageAgent.claude.rawValue else { return }
            tickUsageClock()
            alert(usage.update(.claude, windows: claudeWindows(u.windows, now: usageClock), plan: nil, now: usageClock))
        }
    }

    /// Terminal-side signals; bell/OSC notifications mean "waiting" only for agent leaves.
    func signal(_ signal: AgentSignal, leaf leafId: UUID) {
        guard let leaf = liveLeaf(leafId, tab: nil) else { return }
        if signal == .bell || signal == .desktopNotification, leaf.kind == .shell || leaf.kind == .editor { return }
        apply(signal, leaf: leaf)
    }

    func state(ofLeaf id: UUID) -> AgentState { statuses.status(id).state }

    func state(of tab: Tab) -> AgentState { taskState(tab.root.leaves.map { state(ofLeaf: $0.id) }) }

    func state(of task: HangarTask) -> AgentState {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        return taskState(leaves.map { state(ofLeaf: $0.id) })
    }

    /// Like `state`, but an agent leaf whose agent is out of limit (at `usageClock`) shows «лимит»;
    /// one that stopped on a limit which has since reset is idle again.
    func displayState(ofLeaf id: UUID, kind: LeafKind) -> AgentState {
        let st = state(ofLeaf: id)
        let agent: UsageAgent? = kind == .claude ? .claude : kind == .codex ? .codex : nil
        if let agent, usage.level(agent, now: usageClock) == .full { return .limit }
        return st == .limit ? .idle : st
    }

    /// When the reached limits of these leaves' agents reset (the latest), as «20:20» / «пн 20:20»; nil — unknown.
    func limitClock(of leaves: [Leaf]) -> String? {
        let now = usageClock
        let agents = Set(leaves.compactMap { $0.kind == .claude ? UsageAgent.claude : $0.kind == .codex ? .codex : nil })
        let resets = agents.filter { usage.level($0, now: now) == .full }.compactMap { a -> Date? in
            guard let u = usage.view(a, now: now) else { return nil }
            return u.limitResetsAt ?? u.windows.filter { $0.usedPercent >= UsageThreshold.full }.compactMap(\.resetsAt).max()
        }
        return resets.filter { $0 > now }.max().map { resetClock($0, now: now, calendar: .current) }
    }

    /// The state as a tooltip: «лимит · до 20:20» for a reached limit, else the state word.
    func statusText(_ state: AgentState, leaves: [Leaf]) -> String {
        guard state == .limit, let clock = limitClock(of: leaves) else { return L10n.statusLabel(state) }
        return L10n.limitUntil(clock)
    }

    func displayState(of tab: Tab) -> AgentState {
        taskState(tab.root.leaves.map { displayState(ofLeaf: $0.id, kind: $0.kind) })
    }

    func displayState(of task: HangarTask) -> AgentState {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        return taskState(leaves.map { displayState(ofLeaf: $0.id, kind: $0.kind) })
    }

    /// Agent tabs always show a dot; other tabs only when something is going on.
    func showsDot(_ tab: Tab, state: AgentState) -> Bool {
        state != .idle || tab.root.leaves.contains { $0.kind == .claude || $0.kind == .codex }
    }

    var workingLeafCount: Int { statuses.workingCount }

    private func apply(_ signal: AgentSignal, leaf: Leaf) {
        let agent = sessionAgent(leaf.kind), old = statuses.status(leaf.id)
        // Mutating `statuses` notifies observers even when nothing changes.
        guard fold(old, signal, agent: agent) != old else { return }
        if let t = statuses.apply(signal, leaf: leaf.id, agent: agent) {
            if t.to == .working {
                for (token, w) in workingWaiters where w.leaf == leaf.id { finishWaiter(token, started: true) }
            }
            onTransition?(t)
            if t.to == .done {
                onLeafDone?(t.leaf)
                refreshBadge(ofLeaf: t.leaf)
            }
            if t.to == .waiting, config.dockBadge { requestAttention?() }
        }
    }

    /// `tabs send --wait`: true once the leaf turns `working`, false after `sendWaitTimeout` (no polling: `apply` wakes it).
    func waitForWorking(_ leaf: UUID) async -> Bool {
        if state(ofLeaf: leaf) == .working { return true }
        let token = UUID(), timeout = sendWaitTimeout
        return await withCheckedContinuation { c in
            workingWaiters[token] = (leaf, c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishWaiter(token, started: false)
            }
        }
    }

    /// Main actor: whichever comes first (the status or the timeout) resumes it once.
    private func finishWaiter(_ token: UUID, started: Bool) {
        workingWaiters.removeValue(forKey: token)?.done.resume(returning: started)
    }

    private func sessionAgent(_ kind: LeafKind) -> SessionAgent? {
        kind == .claude ? .claude : kind == .codex ? .codex : nil
    }

    // MARK: Limits

    /// Agents with data, in order; Codex only while codex is installed.
    var limitRows: [(agent: UsageAgent, usage: AgentUsage)] {
        UsageAgent.allCases.compactMap { agent in
            if agent == .codex, codexRead == nil { return nil }
            return usage.view(agent, now: usageClock).map { (agent, $0) }
        }
    }

    /// Stale windows (reset passed) drop to 0 and «обновлено …» moves on, computed now rather than by a timer.
    func refreshUsageClock() { tickUsageClock() }

    /// Writes only on change: every write re-renders the observers.
    private func tickUsageClock() {
        let now = clock()
        if usageClock != now { usageClock = now }
    }

    /// ⌘⇧L / click. Nothing to show → beep. Opening refreshes codex; the returned task is that refresh (tests await it).
    @discardableResult func toggleLimitsPopover() -> Task<Void, Never>? {
        if limitsPopoverShown { setLimitsPopoverShown(false); return nil }
        refreshUsageClock()
        if codexRead == nil, codexNotFound {
            codexNotFound = false
            codexRead = lazyCodexRead()
        }
        guard !limitRows.isEmpty else { beep(); return nil }
        limitsPopoverShown = true
        return Task { await refreshCodexUsage(afterTurn: false) }
    }

    /// Popover binding: a transient close (outside click) is remembered for `limitsClicked`.
    func setLimitsPopoverShown(_ shown: Bool) {
        if limitsPopoverShown, !shown { limitsPopoverClosedAt = uptime() }
        limitsPopoverShown = shown
    }

    /// Click on the block or rail tile. NSPopover closes on mouse-down and the button fires on mouse-up:
    /// that same click must not reopen it.
    func limitsClicked() {
        if !limitsPopoverShown, let closed = limitsPopoverClosedAt, uptime() - closed < 0.3 { return }
        toggleLimitsPopover()
    }

    /// After a turn at most once a minute; never two reads at once. A failed read keeps the old data.
    func refreshCodexUsage(afterTurn: Bool) async {
        guard let read = codexRead, codexGate.begin(afterTurn: afterTurn, now: clock()) else { return }
        defer { codexGate.end(now: clock()) }
        do {
            let u = try await read()
            tickUsageClock()
            alert(usage.update(.codex, windows: u.windows, plan: u.plan, now: usageClock))
        } catch {
            uiLog.error("codex limits read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The first call looks codex up; not found → `codexRead` is nil (no Codex row) until the next popover open.
    func lazyCodexRead() -> () async throws -> AgentUsage {
        { [weak self] in
            guard let self else { throw CancellationError() }
            guard let exe = await findCodex() else {
                codexRead = nil
                codexNotFound = true
                throw CodexReadError(reason: "codex not found")
            }
            let reader = CodexUsageReader(executable: exe)
            let read: () async throws -> AgentUsage = { [weak self] in try await reader.read(now: self?.clock() ?? Date()) }
            codexRead = read
            return try await read()
        }
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
    case terminateNow, ask(Int), cancelCreating, alreadyAsking
}

/// Logout / restart / shutdown quit reasons (`kAEQuitReason` of the quit Apple event).
public func isSystemShutdown(reason: OSType?) -> Bool {
    guard let reason else { return false }
    return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        .contains { OSType($0) == reason }
}

/// Logout/restart/shutdown or SIGTERM: the quit must go through without a sheet nobody would answer.
public func isForcedQuit(sigterm: Bool, reason: OSType?) -> Bool {
    sigterm || isSystemShutdown(reason: reason)
}

/// A forced quit (`isForcedQuit`) never asks (state is saved anyway); otherwise a worktree being
/// created wins (quitting would leave it half-made); then working agents, unless already confirmed.
/// `asking`: the confirm sheet is already up, so a repeated ⌘Q/close is refused (no second sheet, no pending reply).
public func quitDecision(creating: Bool, working: Int, confirmed: Bool, asking: Bool, forced: Bool) -> QuitDecision {
    if forced { return .terminateNow }
    if creating { return .cancelCreating }
    guard working > 0, !confirmed else { return .terminateNow }
    return asking ? .alreadyAsking : .ask(working)
}
