import Foundation

/// A sub-session's outcome (spec sub-sessions §6) for `sessions_wait` and the user's notification; `still-running` is never
/// reported, only waited out.
public enum SubSessionStatus: String, Codable, Sendable, CaseIterable {
    case running = "still-running", done, needsInput = "needs-input", error
}

/// One sub-session's agent leaf, as seen by the done detection. All times are the app clock.
public struct SubSessionWatch: Equatable, Sendable {
    /// No hook for this long after a turn ended → the agent is quiet (a background task's wake-up turn would have started).
    public static let quiet: TimeInterval = 5
    /// Stop said background work runs, but the agent's tool shells are gone and no hook came for this long: Claude did not wake.
    public static let backgroundQuiet: TimeInterval = 30

    /// The agent ran a turn in this episode (a fresh sub-session waits for its first one).
    public var started = false
    /// Last hook of the leaf (any kind), or the creation.
    public var lastEvent: Date
    /// Running background tasks from the last Stop; nil — unknown (codex, an older Claude, no Stop yet).
    public var background: Int?
    /// What this episode already reported; nil — nothing yet.
    public var reported: SubSessionStatus?
    /// The agent's last message (Stop / codex notify), bounded at the trust boundary.
    public var lastMessage: String?

    public init(created: Date) { lastEvent = created }

    /// A hook of the agent leaf. `state` is the leaf's state after it; working starts a new episode.
    public mutating func hook(state: AgentState, background: Int?, message: String?, isStop: Bool, now: Date) {
        lastEvent = now
        if state == .working {
            if reported != nil { reported = nil }
            started = true
            self.background = nil
        }
        if isStop {
            started = true
            self.background = background
        }
        // The Stop's answer, or what the agent asks / failed with.
        if let message, !message.isEmpty, isStop || [.waiting, .failed, .limit].contains(state) { lastMessage = message }
        if state == .waiting || state == .failed || state == .limit { started = true }
    }
}

/// `detached`: tool shells still running under the agent (own process group); nil — not probed / no pid.
/// `screenBusy`: the agent's screen shows «esc to interrupt».
public func subSessionStatus(_ w: SubSessionWatch, state: AgentState, detached: Int?, screenBusy: Bool, now: Date) -> SubSessionStatus {
    switch state {
    case .waiting: return .needsInput
    case .failed, .limit: return .error
    case .working: return .running
    case .done, .idle: break
    }
    guard w.started else { return .running }
    let quietFor = now.timeIntervalSince(w.lastEvent)
    if let bg = w.background, bg > 0 {
        // Claude normally wakes up and stops again with a fresh list; this only catches a wake-up that never came.
        return detached == 0 && quietFor >= SubSessionWatch.backgroundQuiet && !screenBusy ? .done : .running
    }
    if let detached, detached > 0 { return .running }
    if screenBusy || quietFor < SubSessionWatch.quiet { return .running }
    return .done
}

/// `sessions_wait` returns once every sub-session settled, or as soon as one needs the caller (input or an error).
public func waitIsOver(_ statuses: [SubSessionStatus]) -> Bool {
    statuses.allSatisfy { $0 != .running } || statuses.contains { $0 == .needsInput || $0 == .error }
}

/// Stop's `background_tasks` (Claude Code hooks): entries still going. An entry without a status counts as going.
public func runningBackgroundTasks(_ raw: Any?) -> Int? {
    guard let list = raw as? [Any] else { return nil }
    let going = list.filter { item in
        guard let status = (item as? [String: Any])?["status"] as? String else { return true }
        return ["running", "pending", "in_progress", "started"].contains(status.lowercased())
    }
    return min(going.count, 99)
}

/// Cuts a sub-session's result for the caller's context (HD-128): at most `max` characters, the cut marked.
public func compactResult(_ text: String?, max: Int) -> (text: String?, truncated: Bool) {
    guard let text, !text.isEmpty else { return (nil, false) }
    guard text.count > max else { return (text, false) }
    let marker = " … [truncated; full output: tabs_read]"
    return (String(text.prefix(max - marker.count)) + marker, true)
}
