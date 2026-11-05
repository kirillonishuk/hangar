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

/// `tabs_wait` (MCP/CLI): until a tab's agent ends its turn or asks for input. No polling: the leaf's hooks, status
/// changes, exit and close wake the waiter; the only timer is the deadline.
extension AppState {
    /// A hook of `leaf`: the last message (questions and failures carry the text the caller needs too) and the count of
    /// turn ends that `next` waits for. Codex reports only its turn end (no start), so ends are counted, not starts.
    func noteAgentTurn(leaf: UUID, kind: HookKind, message: String?) {
        let st = state(ofLeaf: leaf)
        if kind == .prompt {
            lastAgentMessage[leaf] = nil
        } else if let message, !message.isEmpty, kind == .stop || kind == .codexNotify || [.waiting, .failed, .limit].contains(st) {
            lastAgentMessage[leaf] = message
        }
        if [.stop, .codexNotify, .stopFailure].contains(kind) || kind == .notification && st == .waiting {
            turnEnds[leaf, default: 0] += 1
        }
        wakeTabWaiters(leaf)
    }

    /// Wakes the waiters of `leaf`, or (nil) those whose leaf is gone (tab closed, chat archived).
    func wakeTabWaiters(_ leaf: UUID?) {
        guard !tabWaiters.isEmpty else { return }
        let live = leaf == nil ? liveLeafIds : []
        for (token, w) in tabWaiters where leaf.map({ w.leaf == $0 }) ?? !live.contains(w.leaf) {
            tabWaiters.removeValue(forKey: token)?.wake.resume()
        }
    }

    /// The end status, or nil while the wait goes on. `next`: only after a turn end newer than `since`.
    private func tabWaitEnd(_ leaf: UUID, for f: TabWaitFor, since: Int?) -> String? {
        guard liveLeafIds.contains(leaf) else { return "closed" }
        switch terminals?.state(leaf) {
        case .exited?: return "exited"
        case .failed?: return AgentState.failed.rawValue
        default: break
        }
        if let since, turnEnds[leaf, default: 0] <= since { return nil }
        let st = state(ofLeaf: leaf)
        return tabWaitOver(st, for: f) ? st.rawValue : nil
    }

    /// `next`: the current settled state does not count; waits for the next turn to end (or the timeout).
    func waitForTab(_ target: (tab: UUID, leaf: UUID), for f: TabWaitFor, next: Bool = false, timeout: Duration) async -> TabWaitResult {
        // Real time, not `clock`: the caller's MCP timeout runs on the wall clock.
        let deadline = ContinuousClock.now + timeout
        let since = next ? turnEnds[target.leaf, default: 0] : nil
        while true {
            if let status = tabWaitEnd(target.leaf, for: f, since: since) {
                let cut = compactResult(lastAgentMessage[target.leaf], max: SubSessionInfo.maxMessage)
                return TabWaitResult(tab: target.tab, leaf: target.leaf, status: status, message: cut.text, truncated: cut.truncated ? true : nil)
            }
            let left = deadline - ContinuousClock.now
            if left <= .zero || Task.isCancelled { return TabWaitResult(tab: target.tab, leaf: target.leaf, status: "still-running") }
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
