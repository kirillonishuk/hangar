import Foundation

/// `limit`: the agent stopped on its usage limit (StopFailure rate_limit), not an error.
public enum AgentState: String, Sendable, CaseIterable { case working, waiting, done, failed, idle, limit }

/// Also the `<kind>` in `hangar event <kind>`.
public enum HookKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session-start", prompt, tool, notification, stop
    case stopFailure = "stop-failure", codexNotify = "codex-notify"
    /// PreToolUse of the Task/Agent tool / SubagentStop.
    case subagentStart = "subagent-start", subagentStop = "subagent-stop"
}

public enum AgentSignal: Equatable, Sendable {
    /// `source`: SessionStart's `source` (startup / resume / clear / compact).
    case hook(HookKind, session: String?, notificationType: String?, source: String? = nil)
    case bell
    case desktopNotification
    case exited(code: Int32)
    case relaunched
    case focused
}

public struct LeafStatus: Equatable, Sendable {
    public var state: AgentState = .idle
    public var claudeHooks = false
    public var sessionId: String?
    /// Subagents (Task/Agent tool) running now; never below 0, reset whenever the turn starts or ends.
    public var activeSubagents = 0
    public init() {}
}

/// Session ids come from hook stdin (trust boundary): `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
/// The first character is alphanumeric so `--resume <id>` can never read the id as a flag.
public func validSessionId(_ s: String?) -> String? {
    func alnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    guard let s, (1...128).contains(s.utf8.count), let first = s.utf8.first, alnum(first),
          s.utf8.allSatisfy({ alnum($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
    else { return nil }
    return s
}

/// The agent whose session ids a leaf keeps (claude / codex leaf); nil — no session ids (shell, editor).
public enum SessionAgent: Sendable { case claude, codex }

/// Session ids are kept per leaf agent: a codex hook in a claude leaf (or vice versa) neither sets nor is filtered by it.
func ownsSessionId(_ kind: HookKind, agent: SessionAgent?) -> Bool {
    agent == (kind == .codexNotify ? .codex : .claude)
}

/// A nested agent (e.g. `claude -p` run by the leaf's agent) reports into the same leaf with its own session id.
/// The first id after a launch is the leaf's; another one is taken only from SessionStart of /clear, compact or resume.
/// Events without an id, of another agent than the leaf's, and codex-notify are always accepted.
public func acceptsHook(_ status: LeafStatus, kind: HookKind, session: String?, source: String?, agent: SessionAgent?) -> Bool {
    guard kind != .codexNotify, ownsSessionId(kind, agent: agent),
          let id = validSessionId(session), let current = status.sessionId, id != current else { return true }
    return kind == .sessionStart && ["clear", "compact", "resume"].contains(source)
}

/// Out-of-order events are deliberately not sequenced: Esc/late events leave the last state (#43).
public func fold(_ status: LeafStatus, _ signal: AgentSignal, agent: SessionAgent?) -> LeafStatus {
    var s = status
    switch signal {
    case let .hook(kind, session, type, source):
        guard acceptsHook(status, kind: kind, session: session, source: source, agent: agent) else { return status }
        if kind != .codexNotify { s.claudeHooks = true }
        if ownsSessionId(kind, agent: agent), let id = validSessionId(session) { s.sessionId = id }
        // A missed SubagentStop must not leave a count for good: every turn boundary starts from zero.
        if [.sessionStart, .prompt, .stop, .stopFailure].contains(kind) { s.activeSubagents = 0 }
        switch kind {
        case .sessionStart: break
        case .prompt, .tool: s.state = .working
        case .subagentStart:
            s.state = .working
            s.activeSubagents = min(s.activeSubagents + 1, 99)
        case .subagentStop: s.activeSubagents = max(s.activeSubagents - 1, 0)
        case .notification:
            if type == nil || type == "permission_prompt" || type == "elicitation_dialog" { s.state = .waiting }
        case .stop, .codexNotify: s.state = .done
        case .stopFailure: s.state = .limit  // the hook is installed with matcher rate_limit only
        }
    case .bell, .desktopNotification:
        if !s.claudeHooks { s.state = .waiting }
    case .focused:
        if s.state == .waiting && !s.claudeHooks { s.state = .idle }
    case let .exited(code):
        s.state = code > 0 ? .failed : .idle
        s.activeSubagents = 0
    case .relaunched:
        s.state = .idle
        s.claudeHooks = false
        s.sessionId = nil
        s.activeSubagents = 0
    }
    return s
}

/// waiting > limit > failed > working > done > idle
public func taskState(_ states: [AgentState]) -> AgentState {
    for p in [AgentState.waiting, .limit, .failed, .working, .done] where states.contains(p) { return p }
    return .idle
}

public struct Transition: Equatable, Sendable {
    public var leaf: UUID
    public var from: AgentState
    public var to: AgentState

    public init(leaf: UUID, from: AgentState, to: AgentState) {
        self.leaf = leaf
        self.from = from
        self.to = to
    }
}

public struct StatusBoard: Equatable, Sendable {
    public private(set) var leaves: [UUID: LeafStatus] = [:]
    public init() {}

    public func status(_ leaf: UUID) -> LeafStatus { leaves[leaf] ?? LeafStatus() }

    /// What a leaf's status line shows: «работает · 2 агента».
    public func statusSummary(_ leaf: UUID) -> (state: AgentState, subagents: Int) {
        let s = status(leaf)
        return (s.state, s.activeSubagents)
    }

    /// nil — the state did not change (session id / flags may still have).
    public mutating func apply(_ signal: AgentSignal, leaf: UUID, agent: SessionAgent?) -> Transition? {
        let old = status(leaf)
        let new = fold(old, signal, agent: agent)
        if new != old { leaves[leaf] = new }
        return old.state == new.state ? nil : Transition(leaf: leaf, from: old.state, to: new.state)
    }

    public mutating func retain(_ live: Set<UUID>) {
        leaves = leaves.filter { live.contains($0.key) }
    }

    public var workingCount: Int { leaves.values.filter { $0.state == .working }.count }
}
