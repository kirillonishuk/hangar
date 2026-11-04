import AgentStatus
import ControlServer
import Foundation

/// Whether `tabs_wait --for f` is over at `state`: failed and limit always end it (nothing more comes by itself).
func tabWaitOver(_ state: AgentState, for f: TabWaitFor) -> Bool {
    switch state {
    case .failed, .limit: true
    case .working: false
    case .waiting: f != .idle
    case .done, .idle: f != .waiting
    }
}

/// `tabs_wait` (MCP/CLI): until a tab's agent ends its turn or asks for input. No polling: `apply` wakes the waiter on
/// every status change of its leaf; the only timer is the deadline.
extension AppState {
    /// Questions and failures carry the text the caller needs too, not only a turn's final answer.
    func noteAgentMessage(leaf: UUID, kind: HookKind, message: String?) {
        if kind == .prompt { lastAgentMessage[leaf] = nil; return }
        guard let message, !message.isEmpty else { return }
        if kind == .stop || kind == .codexNotify || [.waiting, .failed, .limit].contains(state(ofLeaf: leaf)) {
            lastAgentMessage[leaf] = message
        }
    }

    /// The end status, or nil while the wait goes on.
    private func tabWaitEnd(_ leaf: UUID, for f: TabWaitFor) -> String? {
        guard liveLeafIds.contains(leaf) else { return "closed" }
        switch terminals?.state(leaf) {
        case .exited?: return "exited"
        case .failed?: return AgentState.failed.rawValue
        default: break
        }
        let st = state(ofLeaf: leaf)
        return tabWaitOver(st, for: f) ? st.rawValue : nil
    }

    func waitForTab(_ target: (tab: UUID, leaf: UUID), for f: TabWaitFor, timeout: Duration) async -> TabWaitResult {
        // Real time, not `clock`: the caller's MCP timeout runs on the wall clock.
        let deadline = ContinuousClock.now + timeout
        while true {
            if let status = tabWaitEnd(target.leaf, for: f) {
                let cut = compactResult(lastAgentMessage[target.leaf], max: SubSessionInfo.maxMessage)
                return TabWaitResult(tab: target.tab, leaf: target.leaf, status: status, message: cut.text, truncated: cut.truncated ? true : nil)
            }
            let left = deadline - ContinuousClock.now
            if left <= .zero || Task.isCancelled { return TabWaitResult(tab: target.tab, leaf: target.leaf, status: "still-running") }
            // shortcut: closing the tab does not wake the waiter; it answers «closed» at its deadline. Wake from close if it matters.
            let token = UUID()
            var sleeper: Task<Void, Never>?
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                tabWaiters[token] = (target.leaf, c)
                sleeper = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: left)
                    self?.tabWaiters.removeValue(forKey: token)?.wake.resume()
                }
            }
            sleeper?.cancel()
        }
    }
}
